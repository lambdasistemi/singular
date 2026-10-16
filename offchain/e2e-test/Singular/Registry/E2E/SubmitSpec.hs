{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.E2E.SubmitSpec
Description : @singular submit@ against a private development ledger
License     : Apache-2.0

The submit verb run in process over the shipping HTTP capabilities of a
generated devnet, with the submission capability wrapped so every send
that reaches it is recorded. The bundles are payments from the genesis
wallet; their witnesses are written by the signing command's own
planner. What the chain holds is read from the private source's block
archive — the independent record the facade serves from, never the
command's own reads.
-}
module Singular.Registry.E2E.SubmitSpec (spec) where

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out
    ( addrTxOutL
    , coinTxOutL
    , mkBasicTxOut
    , valueTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( SlotNo (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue)
import Cardano.Ledger.TxIn (TxId, TxIn (..))
import Cardano.Ledger.Val (inject, (<->))
import Cardano.Node.Client.E2E.Setup
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , genesisSignKey
    , mkSignKey
    )
import Cardano.Node.Client.N2C.ChainSync (HeaderPoint)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Exception (finally)
import Control.Monad (forM, forM_)
import Control.Tracer (nullTracer)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.IORef
    ( IORef
    , atomicModifyIORef'
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Lens.Micro ((&), (.~), (^.))
import Ouroboros.Consensus.HardFork.Combinator.AcrossEras
    ( OneEraHash (..)
    )
import Ouroboros.Network.Block qualified as Chain
import System.Directory (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO
    ( IOMode (WriteMode)
    , hClose
    , hFlush
    , stdout
    , withFile
    )
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Singular.CLI (runCommand)
import Singular.CLI.Command (parseCommand, renderCLIError)
import Singular.CLI.Session (Env (..))
import Singular.CLI.Sign (PlannedWitness (..), witnessPlan)
import Singular.Provider.Koios.Wire (txIdHex)
import Singular.Registry.Application (neutralApplication)
import Singular.Registry.Bundle
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (renderOutRef)
import Singular.Registry.E2E.Fixture (withDevnetSource)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.LedgerProvider
    ( LedgerProvider (..)
    , Outputs
    , SubmitResult (..)
    , TipObservation (..)
    )
import Singular.Registry.Private.Archive
    ( ArchivedBlock (..)
    , ArchivedTransaction (..)
    , archiveBlocks
    , archiveOutputs
    )
import Singular.Registry.Private.Facade (Facade (..))
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.SessionIO qualified as Services
import Singular.Registry.Signing (signTx, signedTx)
import Singular.Registry.Wallet
    ( Wallet (..)
    , bech32Address
    , walletFromSignKey
    )

-- | What every row runs over: the devnet, its wallet and capabilities, a directory.
data Context = Context
    { contextFacade :: Facade
    , contextWallet :: Wallet
    , contextCapabilities :: Capabilities NoWitness IO
    , contextDirectory :: FilePath
    }

spec :: Spec
spec =
    aroundAll withSource $
        describe "Submitting a signed bundle over the shipping capabilities" $
            do
                it
                    "refuses a witness for another body, a witness nobody needs and \
                    \a missing witness, sending nothing"
                    $ \devnet -> do
                        held <- heldBy devnet
                        tipBound <- far devnet
                        let both = bundleOf devnet (chained devnet held tipBound)
                            lone = bundleOf devnet (take 1 (chained devnet held tipBound))
                        witnesses <- writeWitnesses devnet "both" genesisSignKey both
                        -- another body's witness
                        loneFile <- writeBundle devnet "lone.json" lone
                        sends <- newSends
                        (foreignCode, foreignReceipt) <-
                            runSubmit devnet sends "foreign" [witnesses !! 1] loneFile
                        expectRefused
                            sends
                            foreignCode
                            foreignReceipt
                            "witness-for-a-different-body"
                        -- a stranger signs the body it does not fund
                        let shared =
                                (bundleOf devnet (take 1 (chained devnet held tipBound)))
                                    { bundleSigners =
                                        signerOf genesisSignKey :| [signerOf strangerKey]
                                    }
                        sharedFile <- writeBundle devnet "shared.json" shared
                        own <- writeWitnesses devnet "own" genesisSignKey shared
                        stranger <- writeWitnesses devnet "stranger" strangerKey shared
                        (unneededCode, unneededReceipt) <-
                            runSubmit devnet sends "unneeded" (own <> stranger) sharedFile
                        expectRefused
                            sends
                            unneededCode
                            unneededReceipt
                            "witness-for-an-unneeded-key"
                        -- the second body has no witness
                        bothFile <- writeBundle devnet "both.json" both
                        (missingCode, missingReceipt) <-
                            runSubmit devnet sends "missing" (take 1 witnesses) bothFile
                        expectRefused sends missingCode missingReceipt "witness-missing"
                        archived <- archivedIdentities devnet
                        forM_ (toList (bundleTransactions both)) $ \tx ->
                            Set.member (hexOf (bundleTxIdentity tx)) archived `shouldBe` False
                it
                    "refuses a later body the tip has reached, sending not even \
                    \the live one before it, saying rebuild; with the later body \
                    \live, both are sent"
                    $ \devnet -> do
                        held <- heldBy devnet
                        tip <- tipSlot devnet
                        bound <- far devnet
                        -- the second body is bounded (exclusively) at an earlier tip
                        let expired = bundleOf devnet (chainOf devnet held [bound, tip])
                        expiredFile <- writeBundle devnet "expired.json" expired
                        expiredWitnesses <-
                            writeWitnesses devnet "expired" genesisSignKey expired
                        sends <- newSends
                        (code, receipt) <-
                            runSubmit devnet sends "expired" expiredWitnesses expiredFile
                        expectRefused sends code receipt "body-expired"
                        reasonOf receipt `shouldSatisfy` Text.isInfixOf "rebuild"
                        let live = bundleOf devnet (chainOf devnet held [bound, bound])
                        liveFile <- writeBundle devnet "live.json" live
                        liveWitnesses <- writeWitnesses devnet "live" genesisSignKey live
                        (liveCode, _) <- runSubmit devnet sends "live" liveWitnesses liveFile
                        liveCode `shouldBe` ExitSuccess
                        readIORef (sendsSeen sends) `shouldReturn` identitiesOf live
                        -- the twin's first body is the expired bundle's first body;
                        -- the expired one, its second, never reached the chain
                        archived <- archivedIdentities devnet
                        map ((`Set.member` archived) . hexOf) (drop 1 (identitiesOf expired))
                            `shouldBe` [False]
                        map ((`Set.member` archived) . hexOf) (identitiesOf live)
                            `shouldBe` [True, True]
                it
                    "stops at an uncertain answer, sending nothing after it; run \
                    \again, it sends only the rest, and its receipt is what the \
                    \chain shows when it reads it back"
                    $ \devnet -> do
                        held <- heldBy devnet
                        bound <- far devnet
                        let bundle = bundleOf devnet (chainOf devnet held (replicate 3 bound))
                            identities = identitiesOf bundle
                        bundleFile <- writeBundle devnet "chained.json" bundle
                        witnesses <- writeWitnesses devnet "chained" genesisSignKey bundle
                        sends <- newSends
                        -- the first send goes to the node; the second gets no
                        -- answer; the third must never reach the capability
                        writeIORef
                            (sendsScript sends)
                            [Nothing, Just (SubmitFailed "no answer")]
                        (code, receipt) <-
                            runSubmit devnet sends "partial" witnesses bundleFile
                        code `shouldBe` ExitFailure 15
                        textAt "outcome" receipt `shouldBe` Just "partial"
                        readIORef (sendsSeen sends) `shouldReturn` take 2 identities
                        archived <- archivedIdentities devnet
                        map ((`Set.member` archived) . hexOf) identities
                            `shouldBe` [True, False, False]
                        -- again, the node answering: the second and the third
                        writeIORef (sendsSeen sends) []
                        writeIORef (sendsHeights sends) []
                        (again, receipt') <-
                            runSubmit devnet sends "again" witnesses bundleFile
                        again `shouldBe` ExitSuccess
                        readIORef (sendsSeen sends) `shouldReturn` drop 1 identities
                        let entries = submissionsOf receipt'
                        map (textAt "how") entries
                            `shouldBe` [Just "found", Just "sent", Just "sent"]
                        (first, readBack) <- expectArchived devnet sends identities entries
                        -- two sends confirmed between the first read and the read
                        -- back: a count kept from the first read lies below the bracket
                        readBack `shouldSatisfy` (> first)
                        -- once more, everything landed and every output but the
                        -- last spent: nothing is sent, all three are found
                        writeIORef (sendsSeen sends) []
                        writeIORef (sendsHeights sends) []
                        (third, receipt'') <-
                            runSubmit devnet sends "landed" witnesses bundleFile
                        third `shouldBe` ExitSuccess
                        readIORef (sendsSeen sends) `shouldReturn` []
                        map (textAt "how") (submissionsOf receipt'')
                            `shouldBe` replicate 3 (Just "found")
                        _ <- expectArchived devnet sends identities (submissionsOf receipt'')
                        pure ()
                it
                    "skips a landed transaction whose output was spent elsewhere, \
                    \and sends the missing one"
                    $ \devnet -> do
                        held <- heldBy devnet
                        bound <- far devnet
                        -- two outputs of the wallet's own, so the two payments are
                        -- independent of each other
                        let split = payment devnet (map fst held) bound (splitInTwo held)
                            left = TxIn (txIdTx split) (TxIx 0)
                            right = TxIn (txIdTx split) (TxIx 1)
                            first = payment devnet [left] bound [halfOf held <-> inject fee]
                            second = payment devnet [right] bound [halfOf held <-> inject fee]
                            bundle = bundleOf devnet [first, second]
                        sendRaw devnet split
                        sendRaw devnet first
                        -- the chain holds the first by identity, yet shows none of
                        -- its outputs
                        sendRaw
                            devnet
                            ( payment
                                devnet
                                [TxIn (txIdTx first) (TxIx 0)]
                                bound
                                [halfOf held <-> inject fee <-> inject fee]
                            )
                        bundleFile <- writeBundle devnet "landed-and-spent.json" bundle
                        witnesses <-
                            writeWitnesses devnet "landed-and-spent" genesisSignKey bundle
                        sends <- newSends
                        (code, receipt) <-
                            runSubmit devnet sends "landed-and-spent" witnesses bundleFile
                        code `shouldBe` ExitSuccess
                        readIORef (sendsSeen sends) `shouldReturn` [bodyIdentity second]
                        map (textAt "how") (submissionsOf receipt)
                            `shouldBe` [Just "found", Just "sent"]
                it
                    "ignores the witnesses of a landed transaction and holds the \
                    \ones it sends to them: one bundle and one set of witness \
                    \files, run before and after its first body lands"
                    $ \devnet -> do
                        held <- heldBy devnet
                        bound <- far devnet
                        -- four independent outputs of the wallet's own: two
                        -- bundles of two independent payments each
                        let Coin feeLovelace = fee
                            slices = lovelaceOf held `div` 8
                            split =
                                payment
                                    devnet
                                    (map fst held)
                                    bound
                                    ( replicate 4 (inject (Coin slices))
                                        <> [inject (Coin (lovelaceOf held - 4 * slices - feeLovelace))]
                                    )
                            output n = TxIn (txIdTx split) (TxIx n)
                            pair n =
                                pairFrom
                                    devnet
                                    ("found-" <> show n)
                                    bound
                                    (output (2 * n))
                                    (output (2 * n + 1))
                                    (inject (Coin slices))
                        sendRaw devnet split
                        incomplete <- pair 0
                        strangerPair <- pair 1
                        -- the first body's witness is left out, the second's given
                        let incompleteWitnesses = [pairOwn incomplete !! 1]
                            -- a stranger's valid witness over the first body, and
                            -- the second's own
                            strangerWitnesses =
                                [pairStrangerFirst strangerPair, pairOwn strangerPair !! 1]
                        incompleteFiles <-
                            inputBytes (pairFile incomplete : incompleteWitnesses)
                        strangerFiles <-
                            inputBytes (pairFile strangerPair : strangerWitnesses)
                        -- before: the first has not landed. The bundle is
                        -- incomplete, and the stranger's key is not needed.
                        sendsBeforeIncomplete <- newSends
                        (codeBeforeIncomplete, receiptBeforeIncomplete) <-
                            runSubmit
                                devnet
                                sendsBeforeIncomplete
                                "found-incomplete-before"
                                incompleteWitnesses
                                (pairFile incomplete)
                        expectRefused
                            sendsBeforeIncomplete
                            codeBeforeIncomplete
                            receiptBeforeIncomplete
                            "witness-missing"
                        reasonOf receiptBeforeIncomplete
                            `shouldSatisfy` Text.isInfixOf (hexOf (bodyIdentity (pairFirst incomplete)))
                        sendsBeforeStranger <- newSends
                        (codeBeforeStranger, receiptBeforeStranger) <-
                            runSubmit
                                devnet
                                sendsBeforeStranger
                                "found-stranger-before"
                                strangerWitnesses
                                (pairFile strangerPair)
                        expectRefused
                            sendsBeforeStranger
                            codeBeforeStranger
                            receiptBeforeStranger
                            "witness-for-an-unneeded-key"
                        archivedBefore <- archivedIdentities devnet
                        [ Set.member (hexOf (bodyIdentity body)) archivedBefore
                          | body <-
                                [ pairFirst incomplete
                                , pairSecond incomplete
                                , pairFirst strangerPair
                                , pairSecond strangerPair
                                ]
                          ]
                            `shouldBe` replicate 4 False
                        -- the one change: exactly each bundle's first body lands
                        sendRaw devnet (pairFirst incomplete)
                        sendRaw devnet (pairFirst strangerPair)
                        -- after: the same bundle files and the same witness
                        -- files. The first is found; its witnesses are not
                        -- asked for, and the stranger's is ignored.
                        inputBytes (pairFile incomplete : incompleteWitnesses)
                            `shouldReturn` incompleteFiles
                        inputBytes (pairFile strangerPair : strangerWitnesses)
                            `shouldReturn` strangerFiles
                        sendsAfterIncomplete <- newSends
                        (codeAfterIncomplete, receiptAfterIncomplete) <-
                            runSubmit
                                devnet
                                sendsAfterIncomplete
                                "found-incomplete-after"
                                incompleteWitnesses
                                (pairFile incomplete)
                        codeAfterIncomplete `shouldBe` ExitSuccess
                        readIORef (sendsSeen sendsAfterIncomplete)
                            `shouldReturn` [bodyIdentity (pairSecond incomplete)]
                        map (textAt "how") (submissionsOf receiptAfterIncomplete)
                            `shouldBe` [Just "found", Just "sent"]
                        sendsAfterStranger <- newSends
                        (codeAfterStranger, receiptAfterStranger) <-
                            runSubmit
                                devnet
                                sendsAfterStranger
                                "found-stranger-after"
                                strangerWitnesses
                                (pairFile strangerPair)
                        codeAfterStranger `shouldBe` ExitSuccess
                        readIORef (sendsSeen sendsAfterStranger)
                            `shouldReturn` [bodyIdentity (pairSecond strangerPair)]
                        map (textAt "how") (submissionsOf receiptAfterStranger)
                            `shouldBe` [Just "found", Just "sent"]
                        archivedAfter <- archivedIdentities devnet
                        [ Set.member (hexOf (bodyIdentity body)) archivedAfter
                          | body <-
                                [ pairFirst incomplete
                                , pairSecond incomplete
                                , pairFirst strangerPair
                                , pairSecond strangerPair
                                ]
                          ]
                            `shouldBe` replicate 4 True

-- | The bytes of the files a run reads, in order.
inputBytes :: [FilePath] -> IO [ByteString]
inputBytes = mapM BS.readFile

{- | Two independent payments from the wallet's own outputs, bundled for
the wallet and for a stranger the bundle also names as a signer, with
the witnesses each of them writes: the one bundle file and the witness
files a row runs before and after the first body lands.
-}
data PairOnChain = PairOnChain
    { pairFirst :: ConwayTx
    , pairSecond :: ConwayTx
    , pairFile :: FilePath
    , pairOwn :: [FilePath]
    , pairStrangerFirst :: FilePath
    -- ^ the stranger's witness over the first body
    }

pairFrom
    :: Context
    -> String
    -> Word64
    -> TxIn
    -> TxIn
    -> MaryValue
    -> IO PairOnChain
pairFrom devnet name bound left right slice = do
    let first = payment devnet [left] bound [slice <-> inject fee]
        second = payment devnet [right] bound [slice <-> inject fee]
        bundle =
            (bundleOf devnet [first, second])
                { bundleSigners = signerOf genesisSignKey :| [signerOf strangerKey]
                }
    file <- writeBundle devnet (name <> ".json") bundle
    own <- writeWitnesses devnet (name <> "-own") genesisSignKey bundle
    [strangerFirst, _] <-
        writeWitnesses devnet (name <> "-stranger") strangerKey bundle
    pure (PairOnChain first second file own strangerFirst)

{- | Each entry against the archive: its chain point is the block that
carries it; its confirmations are what the archive counted while the
command read them back — at least the count at that read's acquisition,
at most the count after the run — and the chain moved between the
command's first read and its read back, so a count kept from the first
read lies below when the chain moved between the two; each output is unspent with what the archive holds, or
spent.
-}
expectArchived
    :: Context
    -> Sends
    -> [ByteString]
    -> [Aeson.Value]
    -> IO (Word64, Word64)
expectArchived devnet sends identities entries = do
    heights <- readIORef (sendsHeights sends)
    afterRun <- archiveHeight devnet
    archive <- facadeArchive (contextFacade devnet)
    let blocks = archiveBlocks archive
        current = archiveOutputs archive
    (first, readBack) <- case heights of
        h : hs@(_ : _) -> pure (h, last hs)
        _ -> fail "the command did not read the chain twice"
    map (textAt "identity") entries
        `shouldBe` map (Just . hexOf) identities
    forM_ (zip identities entries) $ \(identity, entry) -> do
        let carrying =
                [ (block, tx)
                | block <- blocks
                , tx <- archivedTransactions block
                , identityText (archivedId tx) == hexOf identity
                ]
        (block, tx) <- case carrying of
            [found] -> pure found
            other ->
                fail ("the archive carries it " <> show (length other) <> " times")
        let counted at =
                fromIntegral at - fromIntegral (archivedHeight block) + 1 :: Integer
        pointOf entry
            `shouldBe` Just
                ( fromIntegral (unSlotNo (archivedSlot block))
                , hashOf (archivedPoint block)
                )
        integerAt "confirmations" entry
            `shouldSatisfy` maybe False (\n -> n >= counted readBack && n <= counted afterRun)
        outputsOf entry
            `shouldBe` [ ( renderOutRef reference
                         , case Map.lookup reference current of
                            Just held' ->
                                Just
                                    ( Text.pack (bech32Address (held' ^. addrTxOutL))
                                    , let Coin c = held' ^. coinTxOutL in c
                                    )
                            Nothing -> Nothing
                         )
                       | (reference, _) <- archivedBodyOutputs tx
                       ]
    pure (first, readBack)

-- ---------------------------------------------------------
-- The devnet and the recorded sends
-- ---------------------------------------------------------

withSource :: (Context -> IO ()) -> IO ()
withSource action = withDevnetSource $ \_ facade wallet caps ->
    withSystemTempDirectory "e2e-submit" $ \directory ->
        action (Context facade wallet caps directory)

-- | Every send that reached the capability, and the answers scripted for the next.
data Sends = Sends
    { sendsSeen :: IORef [ByteString]
    , sendsHeights :: IORef [Word64]
    {- ^ the archive's height each time the command acquired a view,
    in order
    -}
    , sendsScript :: IORef [Maybe SubmitResult]
    {- ^ nothing forwards the send to the node; an answer is returned
    without sending
    -}
    }

newSends :: IO Sends
newSends = Sends <$> newIORef [] <*> newIORef [] <*> newIORef []

recording
    :: Context
    -> Sends
    -> Capabilities NoWitness IO
    -> Capabilities NoWitness IO
recording devnet sends caps =
    caps
        { capReads =
            let (network, provider) = capReads caps
            in  ( network
                , provider
                    { acquire = \requested action -> do
                        height <- archiveHeight devnet
                        modifyIORef' (sendsHeights sends) (<> [height])
                        acquire provider requested action
                    }
                )
        , capSubmit = \sealed -> do
            modifyIORef' (sendsSeen sends) (<> [bodyIdentity (signedTx sealed)])
            scripted <- atomicModifyIORef' (sendsScript sends) $ \case
                [] -> ([], Nothing)
                next : rest -> (rest, next)
            maybe (capSubmit caps sealed) pure scripted
        }

-- | Run @singular submit@ in process over the recorded capabilities.
runSubmit
    :: Context
    -> Sends
    -> String
    -> [FilePath]
    -> FilePath
    -> IO (ExitCode, Aeson.Value)
runSubmit devnet sends label witnesses bundle = do
    let directory = contextDirectory devnet
        receiptPath = directory </> (label <> ".receipt.json")
        settings = facadeSettings (contextFacade devnet)
        env =
            Env
                { envTracer = nullTracer
                , envSource = "devnet"
                , envLoadRelease = \_ _ -> pure (Left "submit loads no release")
                , envReads = \_ k -> k (recording devnet sends (contextCapabilities devnet))
                , envWrites = \_ _ _ -> fail "submit opened the write side"
                }
    command <-
        either (fail . renderCLIError) pure $
            parseCommand
                ( ["submit"]
                    <> concat [["--witnesses", w] | w <- witnesses]
                    <> [ bundle
                       , "--koios-url"
                       , providerUrl settings
                       , "--network-magic"
                       , show (providerMagic settings)
                       , "--receipt"
                       , receiptPath
                       ]
                )
    code <-
        quietly
            (directory </> (label <> ".stdout"))
            (runCommand neutralApplication env command)
    receipt <-
        either fail pure . Aeson.eitherDecodeStrict
            =<< BS.readFile receiptPath
    pure (code, receipt)

-- | Standard output of an action, kept in a file instead of the test log.
quietly :: FilePath -> IO a -> IO a
quietly path action = do
    hFlush stdout
    saved <- hDuplicate stdout
    withFile path WriteMode (\file -> hDuplicateTo file stdout >> action)
        `finally` (hFlush stdout >> hDuplicateTo saved stdout >> hClose saved)

expectRefused
    :: Sends -> ExitCode -> Aeson.Value -> Text -> Expectation
expectRefused sends code receipt cause = do
    code `shouldBe` ExitFailure 10
    textAt "cause" receipt `shouldBe` Just cause
    submissionsOf receipt `shouldBe` []
    readIORef (sendsSeen sends) `shouldReturn` []

-- ---------------------------------------------------------
-- Bundles over the genesis wallet
-- ---------------------------------------------------------

heldBy :: Context -> IO Outputs
heldBy devnet =
    Services.withLatest (capReads (contextCapabilities devnet)) $ \session ->
        Services.outputsAt session (walletAddr (contextWallet devnet))

tipSlot :: Context -> IO Word64
tipSlot devnet =
    Services.withLatest
        (capReads (contextCapabilities devnet))
        (fmap (unSlotNo . observedSlot) . Services.tip)

-- | A bound well ahead of the tip.
far :: Context -> IO Word64
far devnet = (+ 100_000) <$> tipSlot devnet

{- | Two chained payments back to the wallet, bounded (exclusively) at
the slot given.
-}
chained :: Context -> Outputs -> Word64 -> [ConwayTx]
chained devnet held bound = chainOf devnet held [bound, bound]

{- | Chained payments back to the wallet, one per bound given: the first
spends every output held, each later one the only output before it;
one ada fee each, each bounded (exclusively) at its own slot.
-}
chainOf :: Context -> Outputs -> [Word64] -> [ConwayTx]
chainOf devnet held = go (map fst held) (foldMap ((^. valueTxOutL) . snd) held)
  where
    go _ _ [] = []
    go spent value (bound : bounds) =
        let paid = value <-> inject fee
            body = payment devnet spent bound [paid]
        in  body : go [TxIn (txIdTx body) (TxIx 0)] paid bounds

-- | A payment back to the wallet: these inputs, one output per value.
payment :: Context -> [TxIn] -> Word64 -> [MaryValue] -> ConwayTx
payment devnet spent bound paid =
    mkBasicTx
        ( mkBasicTxBody
            & inputsTxBodyL .~ Set.fromList spent
            & outputsTxBodyL
                .~ StrictSeq.fromList
                    [mkBasicTxOut (walletAddr (contextWallet devnet)) v | v <- paid]
            & feeTxBodyL .~ fee
            & vldtTxBodyL .~ ValidityInterval SNothing (SJust (SlotNo bound))
        )

fee :: Coin
fee = Coin 1_000_000

-- | A quarter of what is held: small enough for every split below.
halfOf :: Outputs -> MaryValue
halfOf held = inject (Coin (lovelaceOf held `div` 4))

-- | Two outputs of a quarter each, the rest to a third, less the fee.
splitInTwo :: Outputs -> [MaryValue]
splitInTwo held =
    [ halfOf held
    , halfOf held
    , inject (Coin (lovelaceOf held - 2 * (lovelaceOf held `div` 4)))
        <-> inject fee
    ]

lovelaceOf :: Outputs -> Integer
lovelaceOf held = sum [let Coin c = out ^. coinTxOutL in c | (_, out) <- held]

-- | Sign with the genesis key and send outside the command, confirmed.
sendRaw :: Context -> ConwayTx -> IO ()
sendRaw devnet body = do
    let caps = contextCapabilities devnet
        sealed = signTx genesisSignKey body
    capSubmit caps sealed >>= \case
        SubmitAccepted _ -> capConfirm caps (signedTx sealed)
        other -> fail ("the raw send was not accepted: " <> show other)

identitiesOf :: Bundle -> [ByteString]
identitiesOf = map bundleTxIdentity . toList . bundleTransactions

-- | The archive's height: its latest block's.
archiveHeight :: Context -> IO Word64
archiveHeight devnet =
    maximum . (0 :) . map archivedHeight . archiveBlocks
        <$> facadeArchive (contextFacade devnet)

bundleOf :: Context -> [ConwayTx] -> Bundle
bundleOf _ bodies =
    Bundle
        { bundleCommand = "registry fold"
        , bundleNetworkMagic = 42
        , bundleStateToken = Nothing
        , bundleSigners = signerOf genesisSignKey :| []
        , bundleTransactions =
            case [ BundleTransaction
                    { bundleTxIdentity = bodyIdentity body
                    , bundleTxEnvelope = transactionEnvelope body
                    , bundleTxDeadline = bodyDeadline body
                    , bundleTxEffects = ["pays the genesis wallet back"]
                    }
                 | body <- bodies
                 ] of
                t : ts -> t :| ts
                [] -> error "a bundle needs a transaction"
        }

writeBundle :: Context -> FilePath -> Bundle -> IO FilePath
writeBundle devnet name bundle = do
    let path = contextDirectory devnet </> name
    BS.writeFile path (encodeBundle bundle)
    pure path

-- | The witnesses the signing command's planner writes for this key.
writeWitnesses
    :: Context
    -> FilePath
    -> SignKeyDSIGN Ed25519DSIGN
    -> Bundle
    -> IO [FilePath]
writeWitnesses devnet name key bundle = do
    let directory = contextDirectory devnet </> name
    createDirectoryIfMissing True directory
    planned <-
        either (fail . show) pure (witnessPlan (encodeBundle bundle) key)
    forM planned $ \witness -> do
        let path = directory </> plannedPath witness
        BS.writeFile path (plannedBytes witness)
        pure path

signerOf :: SignKeyDSIGN Ed25519DSIGN -> Text
signerOf key = Text.pack (bech32Address (keyAddress key))

keyAddress :: SignKeyDSIGN Ed25519DSIGN -> Addr
keyAddress = walletAddr . walletFromSignKey 42

strangerKey :: SignKeyDSIGN Ed25519DSIGN
strangerKey = mkSignKey "e2e-submit-stranger-key-00000001"

-- ---------------------------------------------------------
-- The archive and the receipt
-- ---------------------------------------------------------

archivedIdentities :: Context -> IO (Set.Set Text)
archivedIdentities devnet = do
    archive <- facadeArchive (contextFacade devnet)
    pure $
        Set.fromList
            [ identityText (archivedId tx)
            | block <- archiveBlocks archive
            , tx <- archivedTransactions block
            ]

-- | The archive's spelling of an identity: lowercase hex, as Koios names it.
identityText :: TxId -> Text
identityText = txIdHex

-- | The block hash of an archived point, in hex.
hashOf :: HeaderPoint -> Text
hashOf = \case
    Chain.BlockPoint _ (OneEraHash header) -> hexOf (SBS.fromShort header)
    Chain.GenesisPoint -> ""

hexOf :: ByteString -> Text
hexOf = TE.decodeUtf8 . B16.encode

fieldAt :: Text -> Aeson.Value -> Maybe Aeson.Value
fieldAt name = \case
    Aeson.Object o -> KeyMap.lookup (Key.fromText name) o
    _ -> Nothing

textAt :: Text -> Aeson.Value -> Maybe Text
textAt name v = case fieldAt name v of
    Just (Aeson.String t) -> Just t
    _ -> Nothing

integerAt :: Text -> Aeson.Value -> Maybe Integer
integerAt name v = case fieldAt name v of
    Just (Aeson.Number n) -> Just (round n)
    _ -> Nothing

reasonOf :: Aeson.Value -> Text
reasonOf = fromMaybe "" . textAt "reason"

submissionsOf :: Aeson.Value -> [Aeson.Value]
submissionsOf v = case fieldAt "submissions" v of
    Just (Aeson.Array xs) -> toList xs
    _ -> []

pointOf :: Aeson.Value -> Maybe (Integer, Text)
pointOf entry = do
    point <- fieldAt "chainPoint" entry
    (,) <$> integerAt "slot" point <*> textAt "blockHash" point

outputsOf :: Aeson.Value -> [(Text, Maybe (Text, Integer))]
outputsOf entry = case fieldAt "outputs" entry of
    Just (Aeson.Array xs) ->
        [ ( fromMaybe "" (textAt "output" o)
          , case fieldAt "unspent" o of
                Just (Aeson.Bool True) ->
                    (,) <$> textAt "address" o <*> integerAt "lovelace" o
                _ -> Nothing
          )
        | o <- toList xs
        ]
    _ -> []
