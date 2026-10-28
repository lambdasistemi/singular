{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.Submit
Description : @submit@: send a signed bundle without sending anything twice
License     : Apache-2.0

The command Bob runs with the witnesses the signers handed back. Its
order is part of its promise:

1. read the bundle and check it as the signing step does, read every
   witness file — a directory stands for its @.witness@ files — and
   pair each witness with the body it verifies against, refusing one
   that verifies against none. A registry name, when present, must be a
   state token. None of this reads the chain.
2. open the node's capabilities, which takes no wallet, and in one view
   read where each transaction sits, the tip once, and the inputs of
   the transactions not yet on chain: an input an earlier body of the
   bundle produces comes from that body, every other from the chain.
3. plan ("Singular.Registry.Submit"): every refusal — a witness nobody
   needs, a missing one, an unresolved input, an expired body — comes
   before the first send.
4. send, in the bundle's order, each body the chain does not hold,
   assembled with exactly its verified witnesses, through the existing
   bounded submission, and wait for each to be confirmed before the
   next. An uncertain answer stops the run as partial; nothing is
   retried within the run.
5. read the chain again for the receipt: per transaction, whether this
   run sent it or found it, its chain point, its confirmations and its
   outputs as the chain holds them now, with the bundle's effect lines
   as claims, never as confirmed facts.

The command keeps no state: running it again after a crash finds what
landed and sends only the rest.
-}
module Singular.CLI.Submit
    ( submitBundle
    , submitInMemory
    , earlierBodyInputs
    ) where

import Control.Exception (IOException, fromException, throwIO, try)
import Control.Monad (forM, forM_, unless)
import Data.Aeson (Value (..), object, toJSON, (.=))
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.Foldable (toList)
import Data.List (isSuffixOf, sort)
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import Lens.Micro ((^.))
import System.Directory (doesDirectoryExist, listDirectory)
import System.Exit (ExitCode)
import System.FilePath ((</>))
import System.Timeout (timeout)

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SigDSIGN
    , SignedDSIGN (..)
    , VerKeyDSIGN
    , rawDeserialiseSigDSIGN
    , rawDeserialiseVerKeyDSIGN
    )
import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( collateralInputsTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, addrTxOutL)
import Cardano.Ledger.BaseTypes (SlotNo (..), TxIx (..))
import Cardano.Ledger.Keys
    ( KeyRole (Witness)
    , VKey (..)
    , WitVKey (..)
    )
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (ConwayEra)

import Singular.CLI.Failure (CommandFailure, Env (..), failWithFields)
import Singular.CLI.Finish (finish)
import Singular.CLI.Live
    ( assetsOf
    , coinOf
    , receipt
    , txInText
    )
import Singular.CLI.Receipt (OutcomeClass (..))
import Singular.Registry.Bundle
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Evidence (Evidenced (..), NoWitness)
import Singular.Registry.LedgerProvider
    ( ChainPoint (..)
    , InclusionStatus (..)
    , OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
    , SubmitResult (..)
    , TipObservation (..)
    )
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing (assembleSigned, signedTx)
import Singular.Registry.StateToken (parseStateToken)
import Singular.Registry.Submit
    ( PlanStep (..)
    , SubmitRefusal (..)
    , matchWitnesses
    , planSubmission
    , renderSubmitRefusal
    )
import Singular.Registry.Wait qualified as Wait
import Singular.Registry.Wallet (bech32Address)

{- | @singular submit@: check the bundle and the witnesses offline, read
the chain, plan, send in order what the chain does not hold, and print
the receipt the chain shows — also to the receipt file when one is
named. The exit status is the receipt's outcome class.
-}
submitBundle
    :: Env
    -> ProviderSettings
    -> FilePath
    -- ^ the bundle file
    -> [FilePath]
    -- ^ the witness files and directories, in order
    -> Maybe FilePath
    -- ^ where the receipt is also written
    -> IO ExitCode
submitBundle env settings bundlePath witnessPaths receiptPath =
    finish (envTracer env) "submit" receiptPath $ do
        bytes <-
            try @IOException (BS.readFile bundlePath)
                >>= either
                    ( const
                        ( refused
                            "bundle-unreadable"
                            ("cannot read the bundle file: " <> bundlePath)
                        )
                    )
                    pure
        bundle <-
            either (refusedBy . SubmitBundleRefused) pure (decodeBundle bytes)
        either (refusedBy . SubmitBundleRefused) pure (checkBundle bundle)
        -- an undecodable body is refused before any witness file is read
        mapM_ decoded (toList (bundleTransactions bundle))
        forM_ (bundleStateToken bundle) $ \spelled ->
            either
                ( refused "bundle-state-token-unreadable"
                    . (("the bundle's registry name is not a state token: " <>) . T.unpack)
                )
                (const (pure ()))
                (parseStateToken spelled)
        witnesses <- concat <$> mapM readWitnesses witnessPaths
        -- a witness for no body of the bundle is refused before the chain is read
        either refusedBy (const (pure ())) (matchWitnesses bundle witnesses)
        receipt "submit" Success
            <$> submitInMemory env settings bundle bytes witnesses

{- | The core of @singular submit@ over a bundle and its witnesses held in
memory: the receipt fields of submitting them, or a named command
failure. 'submitBundle' reads the files and calls it; the vault mode
calls it with the bundle it built and the witnesses it signed. A witness
for no body of the bundle is refused before the chain is read.
-}
submitInMemory
    :: Env
    -> ProviderSettings
    -> Bundle
    -> ByteString
    -- ^ the bundle's bytes, which its hash is taken over
    -> [DetachedWitness]
    -> IO [(Text, Value)]
submitInMemory env settings bundle bytes witnesses = do
    bodies <- mapM decoded (toList (bundleTransactions bundle))
    -- a witness for no body of the bundle is refused before the chain is read
    either refusedBy (const (pure ())) (matchWitnesses bundle witnesses)
    -- opening the provider is a read too: a failure there, like any
    -- read before the first send, is the node being unavailable
    reached <- Wait.tryOutcome $ envReads env settings $ \caps -> do
        (statuses, tip, resolved) <- chainFacts settings caps bundle bodies
        plan <-
            either
                refusedBy
                pure
                (planSubmission bundle witnesses resolved statuses tip)
        done <- sendInOrder bytes caps (toList plan)
        entries <-
            Wait.tryOutcome (readBack caps (zip done bodies)) >>= \case
                Right entries -> pure entries
                Left failure ->
                    failWithFields
                        Partial
                        ( "every transaction is on the chain, but reading them back failed: "
                            <> show failure
                        )
                        [ ("cause", toJSON ("readback-failed" :: Text))
                        , ("bundleHash", toJSON (bundleHash bytes))
                        , ("submissions", toJSON [stopped t (doneName d) | (t, d) <- done])
                        ]
        pure
            [ ("bundleHash", toJSON (bundleHash bytes))
            , ("submissions", toJSON entries)
            ]
    case reached of
        Right fields -> pure fields
        Left failure -> case fromException failure of
            Just (_ :: CommandFailure) -> throwIO failure
            Nothing -> unavailable settings (show failure)

-- ---------------------------------------------------------
-- Offline: the witness files
-- ---------------------------------------------------------

{- | The witnesses one path names: the file's own, or every @.witness@
file of a directory, in name order. An unreadable file is refused by
name.
-}
readWitnesses :: FilePath -> IO [DetachedWitness]
readWitnesses path = do
    directory <- doesDirectoryExist path
    files <-
        if directory
            then
                map (path </>) . sort . filter (".witness" `isSuffixOf`)
                    <$> listDirectory path
            else pure [path]
    forM files $ \file ->
        try @IOException (BS.readFile file) >>= \case
            Left _ ->
                refused
                    "witness-unreadable"
                    ("cannot read the witness file: " <> file)
            Right bytes -> case decodeWitnessEnvelope bytes of
                Left why ->
                    refused
                        "witness-unreadable"
                        ( "the witness file "
                            <> file
                            <> " is not a witness: "
                            <> renderBundleRefusal why
                        )
                Right witness -> pure witness

-- ---------------------------------------------------------
-- The chain, read once before any send
-- ---------------------------------------------------------

{- | In one view: where each transaction sits, the tip, and the inputs
of the transactions not yet on chain — from an earlier body of the
bundle, or from the chain. An input the chain does not hold is left
out, for the planner to refuse by name; any other failed read stops
the command before anything is sent.
-}
chainFacts
    :: ProviderSettings
    -> Capabilities NoWitness IO
    -> Bundle
    -> [ConwayTx]
    -> IO
        (Map ByteString InclusionStatus, Word64, Map TxIn (TxOut ConwayEra))
chainFacts settings caps bundle bodies = do
    answered <- Wait.tryOutcome $ SessionIO.withLatest (capReads caps) $ \session -> do
        statuses <- inclusionOf session identified
        SlotNo tip <- observedSlot <$> SessionIO.tip session
        let (fromBundle, fromChain) =
                earlierBodyInputs
                    [ (body, not (onChain statuses identity))
                    | (identity, body) <- zip identities bodies
                    ]
        held <- forM (Set.toList fromChain) $ \reference ->
            outputs session (AtTxIn reference) >>= \case
                Right found -> pure (value found)
                Left (MissingOutput _) -> pure []
                Left failure -> fail (show failure)
        pure
            (statuses, tip, Map.union fromBundle (Map.fromList (concat held)))
    either (unavailable settings . show) pure answered
  where
    identities = map bundleTxIdentity (toList (bundleTransactions bundle))
    identified = zip identities (map txIdTx bodies)

-- | Where each transaction sits on the chain, keyed by its identity.
inclusionOf
    :: Session NoWitness IO
    -> [(ByteString, TxId)]
    -> IO (Map ByteString InclusionStatus)
inclusionOf session identified = do
    statuses <-
        either (fail . show) (pure . value)
            =<< inclusion session (map snd identified)
    unless (length statuses == length identified) $
        fail
            "the provider answered for a different number of transactions than asked"
    pure (Map.fromList (zip (map fst identified) statuses))

{- | Where each input of the transactions to send comes from, given the
bodies in the bundle's order and whether each is to be sent: an output
an earlier body produces, taken from that body, or a reference the
chain must answer. A transaction already on chain needs nothing
resolved. Pure.
-}
earlierBodyInputs
    :: [(ConwayTx, Bool)] -> (Map TxIn (TxOut ConwayEra), Set TxIn)
earlierBodyInputs = go Map.empty
  where
    go _ [] = (Map.empty, Set.empty)
    go produced ((body, sending) : rest) =
        let spent =
                Set.toList
                    ( body ^. bodyTxL . inputsTxBodyL
                        <> body ^. bodyTxL . collateralInputsTxBodyL
                    )
            fromBundle =
                Map.fromList
                    [(i, out) | sending, i <- spent, Just out <- [Map.lookup i produced]]
            fromChain =
                Set.fromList [i | sending, i <- spent, not (Map.member i produced)]
            (laterBundle, laterChain) = go (Map.union produced (outputsOf body)) rest
        in  (Map.union fromBundle laterBundle, Set.union fromChain laterChain)

-- ---------------------------------------------------------
-- The sends
-- ---------------------------------------------------------

-- | What this run did with one transaction.
data Done
    = -- | sent by this run and confirmed
      Sent
    | -- | already on the chain: not sent again
      Found
    deriving stock (Eq, Show)

{- | Send each body the plan says to send, in order, waiting for each
confirmation before the next; a body the chain holds is skipped. The
first answer that is not an acceptance stops the run, its receipt
naming what this run did with each transaction up to that one.
-}
sendInOrder
    :: ByteString
    -> Capabilities NoWitness IO
    -> [PlanStep]
    -> IO [(BundleTransaction, Done)]
sendInOrder bytes caps = go []
  where
    go done [] = pure (reverse done)
    go done (PlanFound t _ _ : rest) = go ((t, Found) : done) rest
    go done (PlanSend t body witnesses : rest) = do
        let sealed = assembleSigned body (map keyWitness witnesses)
            identity = hexOf (bundleTxIdentity t)
            stop outcome cause why =
                failWithFields
                    outcome
                    why
                    [ ("cause", toJSON (cause :: Text))
                    , ("bundleHash", toJSON (bundleHash bytes))
                    ,
                        ( "submissions"
                        , toJSON
                            ( [stopped t' (doneName d) | (t', d) <- reverse done]
                                <> [stopped t cause]
                            )
                        )
                    ]
            uncertain why =
                stop Partial "submission-uncertain" $
                    "no answer from the node for "
                        <> identity
                        <> "; it may or may not have been accepted, and nothing is retried: "
                        <> why
        answer <- Wait.tryOutcome (capSubmit caps sealed)
        case answer of
            Left failure -> uncertain (show failure)
            Right (SubmitFailed reason) -> uncertain (T.unpack reason)
            Right (SubmitRefused reason) ->
                stop LedgerRefusal "submission-refused" $
                    identity <> " refused by the node: " <> T.unpack reason
            Right (SubmitWrongNetwork wanted actual) ->
                stop ClientRefusal "wrong-network" $
                    "the node runs network " <> show actual <> ", not " <> show wanted
            Right (SubmitAccepted _) ->
                -- confirmation belongs to this thread; capConfirm is interruptible
                Wait.tryOutcome
                    (timeout confirmMicros (capConfirm caps (signedTx sealed)))
                    >>= \case
                        Left failure ->
                            stop Partial "confirmation-failed" $
                                identity
                                    <> " was accepted, but waiting for its confirmation \
                                       \failed; it is never resubmitted: "
                                    <> show failure
                        Right Nothing ->
                            stop Timeout "confirmation-deadline" $
                                identity
                                    <> " was accepted but not seen on chain in time; \
                                       \it is never resubmitted"
                        Right (Just ()) -> go ((t, Sent) : done) rest

-- | What this run did with one transaction, when it stopped before the read back.
stopped :: BundleTransaction -> Text -> Value
stopped t how =
    object
        [ "identity" .= hexOf (bundleTxIdentity t)
        , "how" .= how
        , "claims" .= bundleTxEffects t
        ]

-- | How long each send may take to be confirmed: ten minutes, as the writes wait.
confirmMicros :: Int
confirmMicros = 600 * 1_000_000

{- | A verified detached witness as the key witness the assembly takes;
its bytes deserialised when the planner paired it.
-}
keyWitness :: DetachedWitness -> WitVKey Witness
keyWitness witness =
    case ( rawDeserialiseVerKeyDSIGN (detachedKeyBytes witness)
            :: Maybe (VerKeyDSIGN Ed25519DSIGN)
         , rawDeserialiseSigDSIGN (detachedSignatureBytes witness)
            :: Maybe (SigDSIGN Ed25519DSIGN)
         ) of
        (Just key, Just signature) -> WitVKey (VKey key) (SignedDSIGN signature)
        _ -> error "keyWitness: a paired witness no longer deserialises"

-- ---------------------------------------------------------
-- The receipt, read from the chain after the run
-- ---------------------------------------------------------

{- | Per transaction, in the bundle's order: its identity, whether this
run sent it or found it, and — read now, from the chain — its chain
point, its confirmations and each of its outputs, unspent with what it
holds or spent since; the writer's effect lines beside it as claims.
-}
readBack
    :: Capabilities NoWitness IO
    -> [((BundleTransaction, Done), ConwayTx)]
    -> IO [Value]
readBack caps done =
    SessionIO.withLatest (capReads caps) $ \session -> do
        statuses <-
            inclusionOf
                session
                [(bundleTxIdentity t, txIdTx body) | ((t, _), body) <- done]
        forM done $ \((t, how), body) -> do
            held <- forM (Map.keys (outputsOf body)) $ \reference ->
                outputs session (AtTxIn reference) >>= \case
                    Right found -> pure (reference, lookup reference (value found))
                    Left (MissingOutput _) -> pure (reference, Nothing)
                    Left failure -> fail (show failure)
            pure $
                object $
                    [ "identity" .= hexOf (bundleTxIdentity t)
                    , "how" .= doneName how
                    ]
                        <> case Map.lookup (bundleTxIdentity t) statuses of
                            Just (IncludedAt point confirmations) ->
                                [ "chainPoint" .= pointJson point
                                , "confirmations" .= confirmations
                                ]
                            _ -> ["chainPoint" .= Null]
                        <> [ "outputs" .= map outputJson held
                           , "claims" .= bundleTxEffects t
                           ]
  where
    pointJson = \case
        At (SlotNo slot) hash -> object ["slot" .= slot, "blockHash" .= hexOf hash]
        Genesis -> Null
    outputJson (reference, held) =
        object $
            ("output" .= txInText reference) : case held of
                Just out ->
                    [ "unspent" .= True
                    , "address" .= bech32Address (out ^. addrTxOutL)
                    , "lovelace" .= coinOf out
                    , "assets" .= assetsOf out
                    ]
                Nothing -> ["unspent" .= False]

-- ---------------------------------------------------------
-- Refusals and small helpers
-- ---------------------------------------------------------

-- | A refusal before any send: client refusal, its cause named, no submission.
refused :: Text -> String -> IO a
refused cause why =
    failWithFields
        ClientRefusal
        why
        [("cause", toJSON cause), ("submissions", toJSON ([] :: [Value]))]

-- | A refusal of the planner's, by its name.
refusedBy :: SubmitRefusal -> IO a
refusedBy refusal = refused (causeOf refusal) (renderSubmitRefusal refusal)
  where
    causeOf = \case
        SubmitBundleRefused _ -> "bundle-refused"
        SubmitWitnessForeignBody _ -> "witness-for-a-different-body"
        SubmitWitnessUnneededKey _ -> "witness-for-an-unneeded-key"
        SubmitWitnessMissing _ _ -> "witness-missing"
        SubmitBodyExpired{} -> "body-expired"
        SubmitInputUnresolved _ -> "input-unresolved"

-- | The provider could not be read before any send.
unavailable :: ProviderSettings -> String -> IO a
unavailable settings why =
    failWithFields
        NodeUnavailable
        ( "the provider at "
            <> providerUrl settings
            <> " could not be read: "
            <> why
        )
        [ ("cause", toJSON ("provider-unavailable" :: Text))
        , ("submissions", toJSON ([] :: [Value]))
        ]

doneName :: Done -> Text
doneName = \case
    Sent -> "sent"
    Found -> "found"

onChain :: Map ByteString InclusionStatus -> ByteString -> Bool
onChain statuses identity = case Map.lookup identity statuses of
    Just IncludedAt{} -> True
    _ -> False

-- | A checked bundle's body; 'checkBundle' has decoded every one already.
decoded :: BundleTransaction -> IO ConwayTx
decoded t = case decodeTransactionEnvelope (bundleTxEnvelope t) of
    Right body -> pure body
    Left _ ->
        refusedBy
            ( SubmitBundleRefused
                (BundleEnvelopeUndecodable (hexOf (bundleTxIdentity t)))
            )

outputsOf :: ConwayTx -> Map TxIn (TxOut ConwayEra)
outputsOf body =
    Map.fromList
        [ (TxIn (txIdTx body) (TxIx ix), out)
        | (ix, out) <- zip [0 ..] (toList (body ^. bodyTxL . outputsTxBodyL))
        ]

-- | The bundle file's Blake2b-256 hash, in hex.
bundleHash :: ByteString -> Text
bundleHash bytes = T.pack (hexOf (hashToBytes (hashWith @Blake2b_256 id bytes)))

hexOf :: ByteString -> String
hexOf = T.unpack . TE.decodeUtf8 . B16.encode
