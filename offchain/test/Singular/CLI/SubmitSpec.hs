{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeApplications #-}

{- |
Module      : Singular.CLI.SubmitSpec
Description : @submit@: the command line, the sends and the receipt
License     : Apache-2.0

The proofs of @singular submit@ as Bob runs it: one row per promise the
command makes to the person who hands back the witnesses.

* the command line takes repeated witness files, the bundle, the node
settings and a receipt file, and refuses a wallet key and a vault by
name;
* the transactions are sent in the bundle's order, each assembled with
exactly the witnesses that verify against it, and the receipt states
what the chain shows for each, with the bundle's effect lines as
claims;
* a witness for another body, a witness nobody needs, a missing
witness, an unreadable witness file and an expired body are refused by
name with nothing sent, and the file-level refusals happen before the
chain is read at all;
* an uncertain answer stops the run as partial, and running again sends
only what the chain does not hold.

The chain is the raw chain fixture: its submission applies a body to
its outputs and records the block it lands in. Every witness is written
by the signing command's own planner, every identity is the ledger's
transaction id of the body, and every expected chain point is the tip
the fixture reached when it applied the send — never the read the
command itself makes.
-}
module Singular.CLI.SubmitSpec
    ( spec
    , selfPaymentFiles
    ) where

import Control.Exception (finally)
import Control.Monad (forM, forM_)
import Data.Aeson qualified as Aeson
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
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
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified as TE
import Data.Word (Word64)
import GHC.IO.Handle (hDuplicate, hDuplicateTo)
import Lens.Micro ((&), (.~), (^.))
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

import Cardano.Crypto.DSIGN
    ( Ed25519DSIGN
    , SignKeyDSIGN
    , deriveVerKeyDSIGN
    , rawDeserialiseSignKeyDSIGN
    , rawSerialiseSignKeyDSIGN
    , rawSerialiseVerKeyDSIGN
    )
import Cardano.Crypto.Hash.Blake2b (Blake2b_256)
import Cardano.Crypto.Hash.Class (hashToBytes, hashWith)
import Cardano.Ledger.Api.Tx
    ( addrTxWitsL
    , bodyTxL
    , mkBasicTx
    , txIdTx
    , witsTxL
    )
import Cardano.Ledger.Api.Tx.Body
    ( ValidityInterval (..)
    , feeTxBodyL
    , inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    , vldtTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes
    ( SlotNo (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Keys
    ( VKey (..)
    , WitVKey (..)
    , hashKey
    , unKeyHash
    )
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Ledger.Val (inject)
import Cardano.Tx.Ledger (ConwayTx)
import Control.Tracer (nullTracer)

import Singular.CLI (runCommand)
import Singular.CLI.Command
    ( Command (..)
    , SubmitArgs (..)
    , parseCommand
    , renderCLIError
    )
import Singular.CLI.Session (Env (..))
import Singular.CLI.Sign (PlannedWitness (..), witnessPlan)
import Singular.Registry.Application (neutralApplication)
import Singular.Registry.Bundle
import Singular.Registry.Capabilities (Capabilities (..))
import Singular.Registry.Deployment (parseOutRef, renderOutRef)
import Singular.Registry.Evidence (NoWitness, unverifiedVerifier)
import Singular.Registry.Ledger (Coin (..), ConwayEra, ConwayTxBody)
import Singular.Registry.LedgerProvider qualified as Cage
import Singular.Registry.ProviderSettings (ProviderSettings (..))
import Singular.Registry.RawChainFixture
    ( ChainFacts (..)
    , RawChain
    , advanceChain
    , newRawChain
    , rawChainProvider
    , recordTransaction
    )
import Singular.Registry.SessionEvidence (observeProvider)
import Singular.Registry.SessionIO qualified as SessionIO
import Singular.Registry.Signing (signedTx)
import Singular.Registry.SyntheticTime (syntheticTime)
import Singular.Registry.TxBuilder.BookingFixture (preprodParams)
import Singular.Registry.Wallet
    ( Wallet
    , bech32Address
    , walletAddr
    , walletFromSignKey
    )

spec :: Spec
spec = describe "submitting a signed bundle" $ do
    theCommandLine
    theSends
    theRefusals
    theRerun
    theFoundWitnesses

-- ---------------------------------------------------------
-- The command line
-- ---------------------------------------------------------

theCommandLine :: Spec
theCommandLine = describe "the command line" $ do
    it
        "takes repeated witness files, the bundle, the node settings and a receipt file"
        $ parseCommand
            ( [ "submit"
              , "--witnesses"
              , "a.witness"
              , "--witnesses=dir"
              , "bundle.json"
              , "--receipt"
              , "receipt.json"
              ]
                <> nodeSettings
            )
            `shouldBe` Right
                ( SubmitBundle
                    SubmitArgs
                        { submitBundlePath = "bundle.json"
                        , submitWitnessPaths = ["a.witness", "dir"]
                        , submitProvider =
                            ProviderSettings
                                { providerUrl = fixtureUrl
                                , providerMagic = magic
                                , providerTokenFile = Nothing
                                , providerTimeDirectory = Nothing
                                }
                        , submitReceipt = Just "receipt.json"
                        }
                )
    it "refuses a wallet key, a vault and a passphrase descriptor by name" $
        forM_ ["--wallet-skey", "--vault", "--passphrase-fd"] $ \flag ->
            case parseCommand
                ( ["submit", "--witnesses", "w", flag, "3", "bundle.json"]
                    <> nodeSettings
                ) of
                Right parsed -> expectationFailure (flag <> " was accepted: " <> show parsed)
                Left refusal -> renderCLIError refusal `shouldContain` flag
    it "refuses witness files on any other command" $
        case parseCommand
            ( ["registry", "inspect", "--key", "k", "--witnesses", "w"]
                <> ["--blueprint", "b", "--state-token", stateToken]
                <> nodeSettings
            ) of
            Right parsed -> expectationFailure ("accepted: " <> show parsed)
            Left refusal -> renderCLIError refusal `shouldContain` "--witnesses"

-- ---------------------------------------------------------
-- The sends and the receipt
-- ---------------------------------------------------------

theSends :: Spec
theSends = describe "the sends and the receipt" $ do
    it
        "sends in the bundle's order, each with exactly its own verified \
        \witness, and writes the receipt the chain shows"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            let bodies = chained (tip + 1000)
                bundle = bundleOf bodies
            bundlePath <- writeBundle rig "bundle.json" bundle
            -- the witnesses sit in a directory, written in the signer's order;
            -- the command pairs them by signature, not by name or position
            let witnessDir = rigDir rig </> "witnesses"
            _ <- writeWitnesses witnessDir walletKey bundle
            (code, receipt, printed) <-
                runSubmit rig ["--witnesses", witnessDir, bundlePath]
            sends <- readIORef (rigSends rig)
            map fst sends `shouldBe` map bodyIdentity bodies
            map snd sends `shouldBe` replicate 2 [verKeyBytes walletKey]
            code `shouldBe` ExitSuccess
            textAt "outcome" receipt `shouldBe` Just "success"
            -- the file the receipt went to holds what standard output printed
            written <- BS.readFile (rigDir rig </> "receipt.json")
            written `shouldBe` printed
            bundleBytes <- BS.readFile bundlePath
            textAt "bundleHash" receipt
                `shouldBe` Just (hexText' (hashToBytes (hashWith @Blake2b_256 id bundleBytes)))
            points <- readIORef (rigPoints rig)
            let entries = submissionsOf receipt
            map (textAt "identity") entries
                `shouldBe` map (Just . hexText' . bodyIdentity) bodies
            map (textAt "how") entries `shouldBe` [Just "sent", Just "sent"]
            -- each chain point is the tip the fixture reached applying it;
            -- one block per transaction, so the first has two confirmations
            map pointOf entries
                `shouldBe` [Map.lookup (bodyIdentity b) points | b <- bodies]
            map (integerAt "confirmations") entries `shouldBe` [Just 2, Just 1]
            -- the first body's output is spent by the second; the second's
            -- is held at the wallet with the value its body pays
            let firstBody = case bodies of
                    b : _ -> b
                    [] -> error "the chained bodies are two"
            map outputsOf entries
                `shouldBe` [ [(outputRef firstBody 0, Nothing)]
                           ,
                               [
                                   ( outputRef (bodies !! 1) 0
                                   , Just (walletText, coinOf (bodies !! 1))
                                   )
                               ]
                           ]
            map (fmap (map Aeson.String) . textsAt "claims") entries
                `shouldBe` [Just (map Aeson.String (claimsOf b)) | b <- bodies]
            keysOf receipt `shouldNotContain` ["confirmed"]
            -- nothing printed carries the signing key
            BS.isInfixOf (B16.encode (rawSerialiseSignKeyDSIGN walletKey)) printed
                `shouldBe` False
            acquisitions <- readIORef (rigAcquisitions rig)
            acquisitions `shouldSatisfy` (> 0)

-- ---------------------------------------------------------
-- The refusals
-- ---------------------------------------------------------

theRefusals :: Spec
theRefusals = describe "the refusals, each with nothing sent" $ do
    it "refuses a witness for a different body before reading the chain" $
        withRig $ \rig -> do
            tip <- tipSlot rig
            let bodies = chained (tip + 1000)
                lone = bundleOf (take 1 bodies)
            bundlePath <- writeBundle rig "bundle.json" lone
            -- the wallet's own witness, over the second body: no body of
            -- this bundle verifies it
            [_, other] <-
                writeWitnesses (rigDir rig </> "both") walletKey (bundleOf bodies)
            (code, receipt, _) <- runSubmit rig ["--witnesses", other, bundlePath]
            expectRefused rig code receipt "witness-for-a-different-body"
            reasonOf receipt `shouldContain` hexText (verKeyBytes walletKey)
            readIORef (rigAcquisitions rig) `shouldReturn` 0
    it
        "refuses an unreadable witness file by name before reading the chain"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            bundlePath <-
                writeBundle
                    rig
                    "bundle.json"
                    (bundleOf (take 1 (chained (tip + 1000))))
            let missing = rigDir rig </> "absent.witness"
            (code, receipt, _) <-
                runSubmit rig ["--witnesses", missing, bundlePath]
            expectRefused rig code receipt "witness-unreadable"
            reasonOf receipt `shouldContain` missing
            readIORef (rigAcquisitions rig) `shouldReturn` 0
    it
        "refuses a witness for a key no transaction needs, naming its key hash"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            let bodies = take 1 (chained (tip + 1000))
                -- the stranger is a signer of the bundle, so its witness
                -- verifies against the body; the body spends nothing of its
                bundle =
                    (bundleOf bodies)
                        { bundleSigners = walletSigner :| [signerOf strangerKey]
                        }
            bundlePath <- writeBundle rig "bundle.json" bundle
            own <- writeWitnesses (rigDir rig </> "own") walletKey bundle
            stranger <-
                writeWitnesses (rigDir rig </> "stranger") strangerKey bundle
            (code, receipt, _) <-
                runSubmit
                    rig
                    (concat [["--witnesses", w] | w <- own <> stranger] <> [bundlePath])
            expectRefused rig code receipt "witness-for-an-unneeded-key"
            reasonOf receipt `shouldContain` hexText (keyHashOf strangerKey)
    it
        "refuses a transaction left without its witness, naming the key and the body"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            let bodies = chained (tip + 1000)
                bundle = bundleOf bodies
            bundlePath <- writeBundle rig "bundle.json" bundle
            [first, _] <- writeWitnesses (rigDir rig </> "w") walletKey bundle
            (code, receipt, _) <- runSubmit rig ["--witnesses", first, bundlePath]
            expectRefused rig code receipt "witness-missing"
            reasonOf receipt `shouldContain` hexText (keyHashOf walletKey)
            reasonOf receipt `shouldContain` hexText (bodyIdentity (bodies !! 1))
    it
        "refuses a later body whose upper bound the tip has reached, sending \
        \not even the live one before it, saying rebuild"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            -- the first body is live; the second is bounded (exclusively) at
            -- the tip: the whole bundle is refused before the first send
            let expired = chainOf [tip + 1000, tip]
                expiredBundle = bundleOf expired
            bundlePath <- writeBundle rig "expired.json" expiredBundle
            ws <-
                writeWitnesses (rigDir rig </> "expired") walletKey expiredBundle
            (code, receipt, _) <- runSubmit rig (witnessArgs ws <> [bundlePath])
            expectRefused rig code receipt "body-expired"
            reasonOf receipt `shouldContain` "rebuild"
            reasonOf receipt `shouldContain` hexText (bodyIdentity (expired !! 1))
            -- the accepted twin: the later body one slot later, and both are sent
            let live = chainOf [tip + 1000, tip + 1]
                liveBundle = bundleOf live
            livePath <- writeBundle rig "live.json" liveBundle
            lws <- writeWitnesses (rigDir rig </> "live") walletKey liveBundle
            (liveCode, _, _) <- runSubmit rig (witnessArgs lws <> [livePath])
            liveCode `shouldBe` ExitSuccess
            map fst <$> readIORef (rigSends rig)
                `shouldReturn` map bodyIdentity live

-- ---------------------------------------------------------
-- Partial, then again; what the chain already holds
-- ---------------------------------------------------------

theRerun :: Spec
theRerun = describe "what the chain holds, by identity" $ do
    it
        "stops at an uncertain answer, sending nothing after it; run again, \
        \it sends only what the chain does not hold, its receipt read after \
        \the run"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            let bodies = chainOf (replicate 3 (tip + 1000))
                bundle = bundleOf bodies
                identities = map bodyIdentity bodies
            bundlePath <- writeBundle rig "bundle.json" bundle
            witnesses <- writeWitnesses (rigDir rig </> "w") walletKey bundle
            let args = witnessArgs witnesses <> [bundlePath]
            -- the first send lands; the second gets no answer; the third
            -- must never reach the submission
            writeIORef
                (rigAnswers rig)
                [Nothing, Just (Cage.SubmitFailed "connection reset")]
            (code, receipt, _) <- runSubmit rig args
            code `shouldBe` ExitFailure 15
            textAt "outcome" receipt `shouldBe` Just "partial"
            textAt "cause" receipt `shouldBe` Just "submission-uncertain"
            map fst <$> readIORef (rigSends rig) `shouldReturn` take 2 identities
            readIORef (rigApplied rig) `shouldReturn` take 1 identities
            -- again, the chain answering: the second and the third are sent;
            -- each lands in a block of its own, so the first, found before
            -- any send, has two more confirmations when the receipt is read
            writeIORef (rigSends rig) []
            (again, receipt', _) <- runSubmit rig args
            again `shouldBe` ExitSuccess
            map fst <$> readIORef (rigSends rig) `shouldReturn` drop 1 identities
            let entries = submissionsOf receipt'
            map (textAt "how") entries
                `shouldBe` [Just "found", Just "sent", Just "sent"]
            expectChainFacts rig identities entries
    it
        "sends nothing and reports every transaction found when all landed, \
        \though the first one's output is spent by the second"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            let bodies = chainOf [tip + 1000, tip + 1000]
                bundle = bundleOf bodies
            mapM_ (land rig) bodies
            bundlePath <- writeBundle rig "bundle.json" bundle
            witnesses <- writeWitnesses (rigDir rig </> "w") walletKey bundle
            (code, receipt, _) <-
                runSubmit rig (witnessArgs witnesses <> [bundlePath])
            code `shouldBe` ExitSuccess
            readIORef (rigSends rig) `shouldReturn` []
            let entries = submissionsOf receipt
            map (textAt "how") entries `shouldBe` [Just "found", Just "found"]
            expectChainFacts rig (map bodyIdentity bodies) entries
    it
        "skips a landed transaction whose outputs are all spent elsewhere, \
        \and sends the missing one"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            let first = mkBasicTx (paymentBody [fundingRef 1] (tip + 1000))
                second = mkBasicTx (paymentBody [fundingRef 2] (tip + 1000))
                bundle = bundleOf [first, second]
            land rig first
            -- the chain still holds the first by identity, yet shows none of
            -- its outputs
            spendElsewhere rig (TxIn (txIdTx first) (TxIx 0))
            bundlePath <- writeBundle rig "bundle.json" bundle
            witnesses <- writeWitnesses (rigDir rig </> "w") walletKey bundle
            (code, receipt, _) <-
                runSubmit rig (witnessArgs witnesses <> [bundlePath])
            code `shouldBe` ExitSuccess
            map fst <$> readIORef (rigSends rig)
                `shouldReturn` [bodyIdentity second]
            map (textAt "how") (submissionsOf receipt)
                `shouldBe` [Just "found", Just "sent"]
    it
        "sends a transaction the chain does not hold, though an output of \
        \the same reference is visible"
        $ withRig
        $ \rig -> do
            tip <- tipSlot rig
            let body = mkBasicTx (paymentBody [fundingRef 1] (tip + 1000))
                bundle = bundleOf [body]
            -- an output under the body's reference, with no block carrying it
            plantOutput rig body
            bundlePath <- writeBundle rig "bundle.json" bundle
            witnesses <- writeWitnesses (rigDir rig </> "w") walletKey bundle
            (code, _, _) <- runSubmit rig (witnessArgs witnesses <> [bundlePath])
            code `shouldBe` ExitSuccess
            map fst <$> readIORef (rigSends rig)
                `shouldReturn` [bodyIdentity body]

{- | One bundle of two chained bodies, signed for by the wallet and by a
stranger the bundle also names, and every witness each of them writes:
the same files serve a chain where the first body has landed and one
where it has not.
-}
data Pair = Pair
    { pairBodies :: [ConwayTx]
    , pairBundle :: FilePath
    , pairWallet :: [FilePath]
    -- ^ the wallet's witness over each body, in order
    , pairStranger :: [FilePath]
    -- ^ the stranger's witness over each body, in order
    }

withPair :: Rig -> IO Pair
withPair rig = do
    tip <- tipSlot rig
    let bodies = chainOf [tip + 1000, tip + 1000]
        bundle =
            (bundleOf bodies)
                { bundleSigners = walletSigner :| [signerOf strangerKey]
                }
    path <- writeBundle rig "pair.json" bundle
    own <- writeWitnesses (rigDir rig </> "pair-own") walletKey bundle
    stranger <-
        writeWitnesses (rigDir rig </> "pair-stranger") strangerKey bundle
    pure (Pair bodies path own stranger)

-- | The body at a position of the pair's bundle.
bodyAt :: Pair -> Int -> ConwayTx
bodyAt pair position = pairBodies pair !! position

-- | A witness file by position, or the failure of a pair too short.
fileAt :: [FilePath] -> Int -> FilePath
fileAt files position = files !! position

theFoundWitnesses :: Spec
theFoundWitnesses =
    describe "witnesses of a transaction the chain already holds" $ do
        it
            "sends the second body when the first has landed without its witness"
            $ withRig
            $ \rig -> do
                pair <- withPair rig
                land rig (bodyAt pair 0)
                (code, receipt, _) <-
                    runSubmit
                        rig
                        (witnessArgs [fileAt (pairWallet pair) 1] <> [pairBundle pair])
                code `shouldBe` ExitSuccess
                readIORef (rigSends rig)
                    `shouldReturn` [(bodyIdentity (bodyAt pair 1), [verKeyBytes walletKey])]
                map (textAt "how") (submissionsOf receipt)
                    `shouldBe` [Just "found", Just "sent"]
        it
            "refuses the same bundle as incomplete when the first has not landed"
            $ withRig
            $ \rig -> do
                pair <- withPair rig
                (code, receipt, _) <-
                    runSubmit
                        rig
                        (witnessArgs [fileAt (pairWallet pair) 1] <> [pairBundle pair])
                expectRefused rig code receipt "witness-missing"
                reasonOf receipt `shouldContain` hexText (keyHashOf walletKey)
                reasonOf receipt
                    `shouldContain` hexText (bodyIdentity (bodyAt pair 0))
        it "ignores a stranger's valid witness over a landed body" $
            withRig $ \rig -> do
                pair <- withPair rig
                land rig (bodyAt pair 0)
                (code, receipt, _) <-
                    runSubmit
                        rig
                        ( witnessArgs
                            [fileAt (pairStranger pair) 0, fileAt (pairWallet pair) 1]
                            <> [pairBundle pair]
                        )
                code `shouldBe` ExitSuccess
                -- the stranger's key reaches no send
                readIORef (rigSends rig)
                    `shouldReturn` [(bodyIdentity (bodyAt pair 1), [verKeyBytes walletKey])]
                map (textAt "how") (submissionsOf receipt)
                    `shouldBe` [Just "found", Just "sent"]
        it
            "refuses the same stranger's witness as an unneeded key when the first has not landed"
            $ withRig
            $ \rig -> do
                pair <- withPair rig
                (code, receipt, _) <-
                    runSubmit
                        rig
                        ( witnessArgs
                            [fileAt (pairStranger pair) 0, fileAt (pairWallet pair) 1]
                            <> [pairBundle pair]
                        )
                expectRefused rig code receipt "witness-for-an-unneeded-key"
                reasonOf receipt `shouldContain` hexText (keyHashOf strangerKey)
        it
            "still refuses an unreadable witness and a witness verifying against no body before reading a chain that holds every body"
            $ withRig
            $ \rig -> do
                pair <- withPair rig
                mapM_ (land rig) (pairBodies pair)
                tip <- tipSlot rig
                -- a body outside the bundle, and the wallet's witness over it
                let outside = bundleOf [mkBasicTx (paymentBody [fundingRef 3] (tip + 1000))]
                _ <- writeBundle rig "outside.json" outside
                [outsider] <-
                    writeWitnesses (rigDir rig </> "outside") walletKey outside
                let valid = pairWallet pair
                    absent = rigDir rig </> "absent.witness"
                (foreignCode, foreignReceipt, _) <-
                    runSubmit rig (witnessArgs (valid <> [outsider]) <> [pairBundle pair])
                expectRefused
                    rig
                    foreignCode
                    foreignReceipt
                    "witness-for-a-different-body"
                (absentCode, absentReceipt, _) <-
                    runSubmit rig (witnessArgs (valid <> [absent]) <> [pairBundle pair])
                expectRefused rig absentCode absentReceipt "witness-unreadable"
                readIORef (rigAcquisitions rig) `shouldReturn` 0
                -- the accepted twin: the same chain and only the valid witnesses
                (code, receipt, _) <-
                    runSubmit rig (witnessArgs valid <> [pairBundle pair])
                code `shouldBe` ExitSuccess
                readIORef (rigSends rig) `shouldReturn` []
                map (textAt "how") (submissionsOf receipt)
                    `shouldBe` [Just "found", Just "found"]

{- | Each entry's chain point is the tip the fixture reached when it
applied that body, and its confirmations are counted from the blocks
the fixture applied by the end of the run: one block per body.
-}
expectChainFacts
    :: Rig -> [ByteString] -> [Aeson.Value] -> Expectation
expectChainFacts rig identities entries = do
    points <- readIORef (rigPoints rig)
    applied <- readIORef (rigApplied rig)
    map (textAt "identity") entries
        `shouldBe` map (Just . hexText') identities
    map pointOf entries `shouldBe` [Map.lookup i points | i <- identities]
    map (integerAt "confirmations") entries
        `shouldBe` [ Just (fromIntegral (length applied - position))
                   | i <- identities
                   , position <- take 1 [p | (p, a) <- zip [0 :: Int ..] applied, a == i]
                   ]

witnessArgs :: [FilePath] -> [String]
witnessArgs ws = concat [["--witnesses", w] | w <- ws]

-- ---------------------------------------------------------
-- The rig: a raw chain, a submission that records what reaches it
-- ---------------------------------------------------------

data Rig = Rig
    { rigDir :: FilePath
    , rigChain :: RawChain
    , rigSends :: IORef [(ByteString, [ByteString])]
    -- ^ each send's identity and the keys of the witnesses it carried
    , rigAnswers :: IORef [Maybe Cage.SubmitResult]
    {- ^ the answers to the next sends: nothing applies the body, an
    answer is returned without applying it; empty, every send applies
    -}
    , rigAcquisitions :: IORef Int
    -- ^ how many times the command acquired a view of the chain
    , rigPoints :: IORef (Map ByteString (Integer, Text))
    -- ^ the tip each applied body reached: slot and block hash
    , rigApplied :: IORef [ByteString]
    -- ^ every body the chain applied, in order, one block each
    }

withRig :: (Rig -> IO a) -> IO a
withRig use = withSystemTempDirectory "submit" $ \dir -> do
    chain <-
        newRawChain
            ChainFacts
                { csNetwork = magic
                , csTip = Nothing
                , csPParams = preprodParams
                , csUTxO =
                    Map.fromList
                        [ ( fundingRef n
                          , mkBasicTxOut (walletAddr wallet) (inject (Coin 2_000_000_000))
                          )
                        | n <- [1 .. 3]
                        ]
                , csRegistered = Set.empty
                , csNetworkTime = syntheticTime
                }
    advanceChain chain id
    rig <-
        Rig dir chain
            <$> newIORef []
            <*> newIORef []
            <*> newIORef 0
            <*> newIORef Map.empty
            <*> newIORef []
    use rig

-- | The command's environment: the rig's reads, its recording submission.
envOf :: Rig -> Env
envOf rig =
    Env
        { envTracer = nullTracer
        , envSource = "fixture"
        , envLoadRelease = \_ _ -> pure (Left "submit loads no release")
        , envReads = \_ k -> k (capabilitiesOf rig)
        , envWrites = \_ _ _ -> fail "submit opened the write side"
        }

capabilitiesOf :: Rig -> Capabilities NoWitness IO
capabilitiesOf rig =
    Capabilities
        { capReads =
            let (network, provider) = rawChainProvider (rigChain rig)
                counting =
                    provider
                        { Cage.acquire = \requested action -> do
                            modifyIORef' (rigAcquisitions rig) (+ 1)
                            Cage.acquire provider requested action
                        }
            in  (network, observeProvider unverifiedVerifier (\_ -> pure ()) counting)
        , capSubmit = \sealed -> do
            let tx = signedTx sealed
            modifyIORef' (rigSends rig) (<> [(bodyIdentity tx, witnessKeys tx)])
            scripted <- atomicModifyIORef' (rigAnswers rig) $ \case
                [] -> ([], Nothing)
                next : rest -> (rest, next)
            case scripted of
                Just answer -> pure answer
                Nothing -> land rig tx >> pure (Cage.SubmitAccepted (txIdTx tx))
        , capConfirm = \_ -> pure ()
        , capFacts = pure []
        , capTrace = pure []
        }

{- | The chain applies a body in a block of its own: its inputs spent,
its outputs held, and the tip it reached recorded against its identity.
-}
land :: Rig -> ConwayTx -> IO ()
land rig tx = do
    let spent = Set.toList (tx ^. bodyTxL . inputsTxBodyL)
    recordTransaction (rigChain rig) tx
    advanceChain (rigChain rig) $ \facts ->
        facts
            { csUTxO =
                Map.union (outputsOfBody tx) (foldr Map.delete (csUTxO facts) spent)
            }
    point <- tipOf (rigChain rig)
    modifyIORef' (rigPoints rig) (Map.insert (bodyIdentity tx) point)
    modifyIORef' (rigApplied rig) (<> [bodyIdentity tx])

-- | An output spent by a transaction the bundle does not know.
spendElsewhere :: Rig -> TxIn -> IO ()
spendElsewhere rig reference =
    advanceChain (rigChain rig) $ \facts ->
        facts{csUTxO = Map.delete reference (csUTxO facts)}

-- | A body's outputs made visible with no block carrying the body.
plantOutput :: Rig -> ConwayTx -> IO ()
plantOutput rig tx =
    advanceChain (rigChain rig) $ \facts ->
        facts{csUTxO = Map.union (outputsOfBody tx) (csUTxO facts)}

outputsOfBody :: ConwayTx -> Map TxIn (TxOut ConwayEra)
outputsOfBody tx =
    Map.fromList
        [ (TxIn (txIdTx tx) (TxIx ix), out)
        | (ix, out) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
        ]

-- | The verification keys of a transaction's key witnesses.
witnessKeys :: ConwayTx -> [ByteString]
witnessKeys tx =
    [ rawSerialiseVerKeyDSIGN key
    | WitVKey (VKey key) _ <- Set.toList (tx ^. witsTxL . addrTxWitsL)
    ]

-- | The fixture's tip, read through its own view: slot and block hash.
tipOf :: RawChain -> IO (Integer, Text)
tipOf chain = do
    observed <-
        SessionIO.withLatest (rawChainProvider chain) SessionIO.tip
    let SlotNo slot = Cage.observedSlot observed
    pure (fromIntegral slot, hexText' (Cage.observedHash observed))

tipSlot :: Rig -> IO Word64
tipSlot rig = fromIntegral . fst <$> tipOf (rigChain rig)

-- | Run @singular submit@ in process: its exit, its receipt file and its output.
runSubmit :: Rig -> [String] -> IO (ExitCode, Aeson.Value, ByteString)
runSubmit rig args = do
    let receiptPath = rigDir rig </> "receipt.json"
    command <-
        either (fail . renderCLIError) pure $
            parseCommand
                (["submit"] <> args <> nodeSettings <> ["--receipt", receiptPath])
    (code, printed) <-
        capturingOutput
            (rigDir rig </> "stdout")
            (runCommand neutralApplication (envOf rig) command)
    receipt <-
        either fail pure . Aeson.eitherDecodeStrict
            =<< BS.readFile receiptPath
    pure (code, receipt, printed)

-- | Standard output of an action, held in a file while it runs.
capturingOutput :: FilePath -> IO a -> IO (a, ByteString)
capturingOutput path action = do
    hFlush stdout
    saved <- hDuplicate stdout
    a <-
        withFile path WriteMode (\file -> hDuplicateTo file stdout >> action)
            `finally` (hFlush stdout >> hDuplicateTo saved stdout >> hClose saved)
    (,) a <$> BS.readFile path

-- | A refusal: client refusal, the cause named, no submission, nothing sent.
expectRefused :: Rig -> ExitCode -> Aeson.Value -> Text -> Expectation
expectRefused rig code receipt cause = do
    code `shouldBe` ExitFailure 10
    textAt "outcome" receipt `shouldBe` Just "client-refusal"
    textAt "cause" receipt `shouldBe` Just cause
    submissionsOf receipt `shouldBe` []
    readIORef (rigSends rig) `shouldReturn` []

-- ---------------------------------------------------------
-- The bundle, its bodies and its witnesses
-- ---------------------------------------------------------

{- | Two chained payments to the wallet, the second spending the first's
only output, each bounded (exclusively) at the slot given.
-}
chained :: Word64 -> [ConwayTx]
chained bound = chainOf [bound, bound]

{- | Chained payments to the wallet, one per bound given: the first
spends the wallet's funding, each later one the output before it; each
bounded (exclusively) at its own slot.
-}
chainOf :: [Word64] -> [ConwayTx]
chainOf = go (fundingRef 1)
  where
    go _ [] = []
    go spent (bound : bounds) =
        let body = mkBasicTx (paymentBody [spent] bound)
        in  body : go (TxIn (txIdTx body) (TxIx 0)) bounds

paymentBody :: [TxIn] -> Word64 -> ConwayTxBody
paymentBody spent bound =
    mkBasicTxBody
        & inputsTxBodyL .~ Set.fromList spent
        & outputsTxBodyL
            .~ StrictSeq.singleton
                (mkBasicTxOut (walletAddr wallet) (inject (Coin 1_000_000_000)))
        & feeTxBodyL .~ Coin 1_000_000
        & vldtTxBodyL .~ ValidityInterval SNothing (SJust (SlotNo bound))

bundleOf :: [ConwayTx] -> Bundle
bundleOf bodies =
    Bundle
        { bundleCommand = "registry fold"
        , bundleNetworkMagic = magic
        , bundleStateToken = Nothing
        , bundleSigners = walletSigner :| []
        , bundleTransactions =
            case [ BundleTransaction
                    { bundleTxIdentity = bodyIdentity body
                    , bundleTxEnvelope = transactionEnvelope body
                    , bundleTxDeadline = bodyDeadline body
                    , bundleTxEffects = claimsOf body
                    }
                 | body <- bodies
                 ] of
                t : ts -> t :| ts
                [] -> error "a bundle needs a transaction"
        }

-- | The effect line a body's writer claims.
claimsOf :: ConwayTx -> [Text]
claimsOf body = ["pays the wallet from " <> hexText' (bodyIdentity body)]

writeBundle :: Rig -> FilePath -> Bundle -> IO FilePath
writeBundle rig name bundle = do
    let path = rigDir rig </> name
    BS.writeFile path (encodeBundle bundle)
    pure path

{- | The witnesses the signing command's own planner writes for this key,
in its order, into a directory of their own.
-}
writeWitnesses
    :: FilePath -> SignKeyDSIGN Ed25519DSIGN -> Bundle -> IO [FilePath]
writeWitnesses dir key bundle = do
    createDirectoryIfMissing True dir
    planned <-
        either (fail . show) pure (witnessPlan (encodeBundle bundle) key)
    forM planned $ \witness -> do
        let path = dir </> plannedPath witness
        BS.writeFile path (plannedBytes witness)
        pure path

{- | A one-transaction bundle paying the key's own address from the
output given, and the key's witness for it, written into the
directory: the bundle path and the witness path.
-}
selfPaymentFiles
    :: FilePath
    -> SignKeyDSIGN Ed25519DSIGN
    -> (TxIn, TxOut ConwayEra)
    -> IO (FilePath, FilePath)
selfPaymentFiles dir key (spent, held) = do
    let address = walletAddr (walletFromSignKey magic key)
        body =
            mkBasicTx
                ( mkBasicTxBody
                    & inputsTxBodyL .~ Set.singleton spent
                    & outputsTxBodyL
                        .~ StrictSeq.singleton
                            (mkBasicTxOut address (inject (held ^. coinTxOutL)))
                    & feeTxBodyL .~ Coin 0
                )
        bundle =
            (bundleOf [body])
                { bundleSigners = T.pack (bech32Address address) :| []
                }
        path = dir </> "submit-bundle.json"
    createDirectoryIfMissing True dir
    BS.writeFile path (encodeBundle bundle)
    [witness] <- writeWitnesses (dir </> "submit-witnesses") key bundle
    pure (path, witness)

-- ---------------------------------------------------------
-- Keys, addresses and spellings
-- ---------------------------------------------------------

magic :: (Num a) => a
magic = 42

fixtureUrl :: String
fixtureUrl = "http://fixture.invalid"

nodeSettings :: [String]
nodeSettings = ["--koios-url", fixtureUrl, "--network-magic", show (magic :: Int)]

stateToken :: String
stateToken = replicate 56 'a' <> "." <> replicate 8 'b'

keyFromSeed :: Char -> SignKeyDSIGN Ed25519DSIGN
keyFromSeed c =
    fromMaybe
        (error "a 32-byte seed is a signing key")
        (rawDeserialiseSignKeyDSIGN (BC.replicate 32 c))

walletKey :: SignKeyDSIGN Ed25519DSIGN
walletKey = keyFromSeed 'b'

strangerKey :: SignKeyDSIGN Ed25519DSIGN
strangerKey = keyFromSeed 's'

wallet :: Wallet
wallet = walletFromSignKey magic walletKey

walletText :: Text
walletText = T.pack (bech32Address (walletAddr wallet))

walletSigner :: Text
walletSigner = walletText

signerOf :: SignKeyDSIGN Ed25519DSIGN -> Text
signerOf key = T.pack (bech32Address (walletAddr (walletFromSignKey magic key)))

verKeyBytes :: SignKeyDSIGN Ed25519DSIGN -> ByteString
verKeyBytes = rawSerialiseVerKeyDSIGN . deriveVerKeyDSIGN

-- | The payment key hash of a key, as the ledger hashes it.
keyHashOf :: SignKeyDSIGN Ed25519DSIGN -> ByteString
keyHashOf key = hashToBytes (unKeyHash (hashKey (VKey (deriveVerKeyDSIGN key))))

fundingRef :: Int -> TxIn
fundingRef n =
    either
        (error . ("fundingRef: " <>))
        id
        (parseOutRef (T.pack (replicate 63 'e' <> show n <> "#0")))

outputRef :: ConwayTx -> Integer -> Text
outputRef body ix = renderOutRef (TxIn (txIdTx body) (TxIx (fromIntegral ix)))

coinOf :: ConwayTx -> Integer
coinOf body = case toList (body ^. bodyTxL . outputsTxBodyL) of
    out : _ -> let Coin c = out ^. coinTxOutL in c
    [] -> 0

hexText' :: ByteString -> Text
hexText' = TE.decodeUtf8 . B16.encode

-- ---------------------------------------------------------
-- Reading the receipt
-- ---------------------------------------------------------

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

textsAt :: Text -> Aeson.Value -> Maybe [Text]
textsAt name v = case fieldAt name v of
    Just (Aeson.Array xs) ->
        traverse (\case Aeson.String t -> Just t; _ -> Nothing) (toList xs)
    _ -> Nothing

reasonOf :: Aeson.Value -> String
reasonOf = maybe "" T.unpack . textAt "reason"

submissionsOf :: Aeson.Value -> [Aeson.Value]
submissionsOf v = case fieldAt "submissions" v of
    Just (Aeson.Array xs) -> toList xs
    _ -> []

pointOf :: Aeson.Value -> Maybe (Integer, Text)
pointOf entry = do
    point <- fieldAt "chainPoint" entry
    (,) <$> integerAt "slot" point <*> textAt "blockHash" point

-- | Each output the receipt lists: its reference, and what it holds when unspent.
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

-- | Every key of every object in a JSON value.
keysOf :: Aeson.Value -> [Text]
keysOf = \case
    Aeson.Object o ->
        concat [Key.toText k : keysOf v | (k, v) <- KeyMap.toList o]
    Aeson.Array xs -> concatMap keysOf xs
    _ -> []
