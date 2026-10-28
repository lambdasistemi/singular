{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.Inspect
Description : Read a registry key without a signer and present the reader's answer
License     : Apache-2.0

The caller supplies settings and owns one provider acquisition. Both command
hosts use this boundary; the application refines only the returned answer.
Rendering is pure. Cancellation propagates; a synchronous provider failure
remains unavailable and carries its explanation.
-}
module Singular.CLI.Inspect
    ( ReaderArgs (..)
    , Inspection (..)
    , readerArgs
    , runReader
    , neutralInspection
    , holdingFields
    , hex
    ) where

import Cardano.Crypto.Hash (hashToBytes)
import Cardano.Ledger.Api.Scripts.Data
    ( Datum (..)
    , binaryDataToData
    , getPlutusData
    )
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, coinTxOutL, datumTxOutL)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Hashes (ScriptHash (..))
import Cardano.Ledger.Mary.Value (PolicyID (..))
import Control.Exception
    ( SomeAsyncException
    , SomeException
    , catch
    , displayException
    , fromException
    , throwIO
    )
import Control.Monad (forM_, unless)
import Data.Aeson (Value (..), encode, object, (.=))
import Data.Aeson.Types (Pair)
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Lazy.Char8 qualified as BL
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Lens.Micro ((^.))
import Singular.CLI.Failure (Env (..))
import Singular.CLI.FlagGroup (readProviderSettings)
import Singular.CLI.Key (KeyRefusal, keyFlags, readKey)
import Singular.CLI.RegistryReading
    ( RegistryRefusal (..)
    , completeRegistry
    )
import Singular.Reader qualified as R
import Singular.Registry.Address (renderRegistryAddress)
import Singular.Registry.Application (datumToJson)
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.ContractTable
    ( ApplicationIdentity (..)
    , applicationOf
    , loadContractTable
    )
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.Ledger (ConwayEra, Root (..), TxIn, TxOut)
import Singular.Registry.LedgerProvider qualified as LP
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.StateToken (parseStateToken)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.Wallet (bech32Address)
import Singular.State.Lineage (registryAsset)
import System.Exit (ExitCode (..))

-- | Read-only explicit inputs, with no blueprint, local state or signer.
data ReaderArgs = ReaderArgs
    { readerRequest :: R.ReaderRequest
    , readerProvider :: ProviderSettings
    , readerJson :: Bool
    }
    deriving stock (Eq, Show)

-- | A pure rendering of a reader answer, with its process exit status.
data Inspection = Inspection
    { inspectionAnswer :: Text
    , inspectionFields :: [Pair]
    , inspectionLines :: [Text]
    , inspectionExit :: ExitCode
    }

-- | Read the established registry settings and one key, refusing every write option.
readerArgs
    :: (String -> e)
    -> (String -> String -> e)
    -> (KeyRefusal -> e)
    -> [(String, String)]
    -> [(String, Maybe String)]
    -> Either e ReaderArgs
readerArgs missing bad keyBad environment given = do
    forM_ given $ \(name, _) ->
        unless (name `elem` allowed) $
            Left
                ( bad
                    name
                    "is not accepted by inspect: it reads without a signer, blueprint or local state"
                )
    flags <- first registryBad (completeRegistry environment given)
    provider <- readProviderSettings missing bad flags
    spelling <- required "--state-token" flags
    (PolicyID (ScriptHash policy), name) <-
        first
            (bad "--state-token" . T.unpack)
            (parseStateToken (T.pack spelling))
    key <- case [ (flag, encoding, value)
                | (flag, encoding) <- keyFlags
                , Just (Just value) <- [lookup flag flags]
                ] of
        [] -> Left (missing "--key or --key-hex")
        [(_, encoding, value)] -> first keyBad (readKey encoding (T.pack value))
        _ -> Left (bad "--key" "cannot be combined with --key-hex")
    pure
        ReaderArgs
            { readerRequest =
                R.ReaderRequest
                    (LP.Network (providerMagic provider))
                    (RegistryIdentity (StatePolicyId (hashToBytes policy)) name)
                    key
            , readerProvider = provider
            , readerJson = any ((== "--json") . fst) flags
            }
  where
    allowed =
        [ "--registry"
        , "--state-token"
        , "--network-magic"
        , "--koios-url"
        , "--koios-token-file"
        , "--network-time"
        , "--key"
        , "--key-hex"
        , "--json"
        , "--trace"
        , "--trace-to"
        , "--trace-format"
        ]
    required name flags = case lookup name flags of
        Just (Just value) -> Right value
        _ -> Left (missing name)
    registryBad (RegistryMissing name) = missing name
    registryBad (RegistryBad name why) = bad name why

-- | Run the neutral reader once and let its host render or refine the answer.
runReader
    :: Env
    -> ReaderArgs
    -> ( R.ReaderRequest
         -> Maybe ApplicationIdentity
         -> R.NeutralReaderAnswer
         -> Inspection
       )
    -> IO ExitCode
runReader env args present = do
    result <- readAnswer `catch` unavailable
    let LP.Network magic = R.requestedNetwork request
        address =
            registryAsset (R.readerRegistry request)
                >>= renderRegistryAddress magic
        document =
            object
                ( [ "answer" .= inspectionAnswer result
                  , "registry" .= address
                  , "keyHex" .= hex (R.readerKey request)
                  , "provider" .= providerUrl (readerProvider args)
                  ]
                    <> inspectionFields result
                )
    if readerJson args
        then BL.putStrLn (encode document)
        else
            mapM_
                (putStrLn . T.unpack)
                ( [ inspectionAnswer result
                  , "Provider: " <> T.pack (providerUrl (readerProvider args))
                  ]
                    <> inspectionLines result
                )
    pure (inspectionExit result)
  where
    request = readerRequest args
    RegistryIdentity (StatePolicyId policy) _ = R.readerRegistry request
    readAnswer =
        loadContractTable >>= \case
            Left why ->
                pure
                    ( present
                        request
                        Nothing
                        (R.Unavailable R.NetworkRead (R.Failed ("release table: " <> why)))
                    )
            Right table -> envReads env (readerProvider args) $ \caps -> do
                acquired <- LP.acquire
                    (snd (capReads caps))
                    (LP.Latest (R.requestedNetwork request))
                    $ \session ->
                        R.readNeutralKeyFromSession session table request
                let answer = case acquired of
                        Right value -> value
                        Left (LP.WrongNetwork served requested) -> R.Refused (R.WrongNetwork requested served)
                        Left failure -> R.Unavailable R.NetworkRead (R.Failed (T.pack (show failure)))
                pure (present request (applicationOf table policy) answer)
    unavailable (failure :: SomeException)
        | Just (_ :: SomeAsyncException) <- fromException failure =
            throwIO failure
        | otherwise =
            pure
                ( present
                    request
                    Nothing
                    ( R.Unavailable
                        R.NetworkRead
                        (R.Failed (T.pack (displayException failure)))
                    )
                )

-- | Present every neutral answer, retaining its exact refusal or unavailable reason.
neutralInspection
    :: R.ReaderRequest
    -> Maybe ApplicationIdentity
    -> R.NeutralReaderAnswer
    -> Inspection
neutralInspection _ published answer =
    let identityFields = ["application" .= published]
        identityLines = case published of
            Nothing -> []
            Just identity ->
                [ "Application policy: " <> hex (applicationPolicy identity)
                , "Application script: " <> hex (applicationScript identity)
                , "Singular releases: " <> releases (singularReleases identity)
                , "Application releases: " <> releases (applicationReleases identity)
                ]
        base label fields said code =
            Inspection
                label
                (identityFields <> fields)
                (identityLines <> said)
                code
    in  case answer of
            R.Active pair@(_, output) ->
                base
                    "active"
                    (holdingFields pair)
                    [ "Holding: " <> renderOutRef (fst pair)
                    , "Datum: " <> TE.decodeUtf8 (BL.toStrict (encode (datumValue output)))
                    ]
                    ExitSuccess
            R.Terminal state -> stateAnswer base "terminal" state
            R.NeverRegistered state -> stateAnswer base "never-registered" state
            R.Unavailable readName reason ->
                let why = unavailableReason reason
                    name = readNameText readName
                in  base
                        "unavailable"
                        ["read" .= name, "reason" .= why]
                        ["Unavailable " <> name <> ": " <> why]
                        (ExitFailure 1)
            R.Refused reason ->
                let (name, why) = refusalReason reason
                in  base
                        "refused"
                        ["refusal" .= name, "reason" .= why]
                        ["Refused: " <> why]
                        (ExitFailure 2)
  where
    releases [] = "not released yet"
    releases tags = T.intercalate ", " tags
    stateAnswer base label state =
        let Root root = R.readerStateRoot state
            reference = fst (R.readerStateOutput state)
        in  base
                label
                ["stateOutput" .= renderOutRef reference, "root" .= hex root]
                ["State output: " <> renderOutRef reference, "Root: " <> hex root]
                ExitSuccess

-- | The holding's ledger data without interpreting an application envelope.
holdingFields :: (TxIn, TxOut ConwayEra) -> [Pair]
holdingFields (reference, output) =
    [ "outputRef" .= renderOutRef reference
    , "address" .= bech32Address (output ^. addrTxOutL)
    , "lovelace" .= let Coin amount = output ^. coinTxOutL in amount
    , "datum" .= datumValue output
    ]
        <> case output ^. datumTxOutL of
            NoDatum -> ["datumKind" .= ("none" :: Text)]
            DatumHash hash -> ["datumKind" .= ("hash" :: Text), "datumHash" .= show hash]
            Datum _ -> ["datumKind" .= ("inline" :: Text)]

datumValue :: TxOut ConwayEra -> Value
datumValue output = case output ^. datumTxOutL of
    Datum binary -> datumToJson (getPlutusData (binaryDataToData binary))
    _ -> Null

-- | Hexadecimal bytes, for exact identities and keys in either output format.
hex :: ByteString -> Text
hex = TE.decodeUtf8 . B16.encode

readNameText :: R.ReaderReadName -> Text
readNameText = \case
    R.NetworkRead -> "network"
    R.ActiveOutputsRead -> "active outputs"
    R.StateRead -> "state"
    R.TrieRead -> "trie"

unavailableReason :: R.ReaderUnavailable -> Text
unavailableReason = \case
    R.Missing -> "no answer was supplied"
    R.Failed why -> why
    R.Incomplete why -> "incomplete answer: " <> why
    R.StateNotFound -> "the registry's state output was not found"
    R.StateNotRecognized -> "the output was not recognised as the registry's state"
    R.TrieRootMismatch -> "the trie read does not match the recognised state's root"

refusalReason :: R.ReaderRefusal -> (Text, Text)
refusalReason = \case
    R.WrongNetwork (LP.Network requested) (LP.Network served) ->
        ( "wrong-network"
        , "registry network "
            <> T.pack (show requested)
            <> ", provider serves network "
            <> T.pack (show served)
        )
    R.UnknownStatePolicy policy -> ("unknown-state-policy", "unknown state policy " <> hex policy)
    R.ForeignStatePolicy requested published ->
        ( "foreign-state-policy"
        , "requested state policy "
            <> hex requested
            <> ", published state policy "
            <> hex published
        )
    R.TokenOutsideApplicationCustody reference address ->
        ( "token-outside-application-custody"
        , "token outside application custody at "
            <> renderOutRef reference
            <> " ("
            <> T.pack (bech32Address address)
            <> ")"
        )
    R.ConflictingEvidence -> ("conflicting-evidence", "conflicting evidence for the key")
