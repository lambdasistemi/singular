{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

{- |
Module      : Singular.CLI.WriteSpec
Description : A singular write on injected capabilities, over the in-memory chain
License     : Apache-2.0

One write of the ordinary CLI, driven through 'submitBuilt' over the
in-memory adapter with a recording submitter and a recording
confirmation: no node, no process-wide session.

Every compared value is obtained at run time: the chain point is the one
the build's own view reports, the signed body is the one the build
returned signed by the wallet's key, and the moved chain's point is read
back by a fresh acquisition. The chain is moved inside the build, after
the view is acquired and before the body is signed, so a journal that
re-read the chain would name another point; the reached control requires
the fresh point to differ.
-}
module Singular.CLI.WriteSpec (spec) where

import Control.Exception (SomeException, try)
import Data.Aeson ((.:))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Base16 qualified as B16
import Data.ByteString.Char8 qualified as BC
import Data.IORef
    ( IORef
    , modifyIORef'
    , newIORef
    , readIORef
    , writeIORef
    )
import Data.Map.Strict qualified as Map
import Data.Maybe (mapMaybe)
import Data.Sequence.Strict qualified as StrictSeq
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Word (Word32)
import Lens.Micro ((&), (.~), (^.))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Hspec

import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx, witsTxL)
import Cardano.Ledger.Api.Tx.Body
    ( inputsTxBodyL
    , mkBasicTxBody
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (mkBasicTxOut)
import Cardano.Ledger.Api.Tx.Wits (addrTxWitsL)
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Node.Client.Submitter
    ( SubmitResult (..)
    , Submitter (..)
    )
import Cardano.Tx.Ledger (ConwayTx)

import Singular.CLI.Node (Capabilities (..))
import Singular.CLI.Receipt
    ( JournalEntry (..)
    , readJournal
    , unresolved
    )
import Singular.CLI.Session
    ( WriteContext (..)
    , expecting
    , submitBuilt
    , txIdHex
    )
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), TxIn)
import Singular.Registry.Node (Wallet (..), loadWallet)
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , MemoryChain
    , memoryProvider
    , mutate
    , newMemoryChain
    )
import Singular.Registry.Node.Submit
    ( signTx
    , signedSubmitter
    , signedTx
    )
import Singular.Registry.Provider qualified as Cage

spec :: Spec
spec = describe "a singular write on injected capabilities (#323)" $ do
    it
        "journals every field of the point its body was built from, \
        \though the chain moved before signing"
        $ withFixture
        $ \fx -> do
            _ <- try @SomeException (write fx)
            built <- readIORef (fxBuiltAt fx)
            point <- maybe (fail "the build never ran") pure built
            fresh <-
                Cage.withView (memoryProvider (fxChain fx)) (pure . Cage.viewPoint)
            fresh `shouldNotBe` point
            prepared <- preparedLines (fxDir fx)
            map journalledPoint prepared
                `shouldBe` [ Just
                                ( Cage.cpNetwork point
                                , Cage.cpEra point
                                , renderPoint point
                                )
                           ]
    it
        "confirms through the confirmation it was given, with no node \
        \session open"
        $ withFixture
        $ \fx -> do
            (signed, ()) <- write fx
            confirmed <- readIORef (fxConfirmed fx)
            confirmed `shouldBe` [T.unpack (txIdHex signed)]
            events <- map journalEvent <$> readJournal (fxDir fx)
            events `shouldBe` ["prepared", "submitted", "confirmed"]
    it "hands the node only the body the caller's key signed" $
        withFixture $ \fx -> do
            _ <- try @SomeException (write fx)
            unsigned <- readIORef (fxUnsigned fx)
            sent <- readIORef (fxSent fx)
            let expected =
                    signedTx . signTx (walletSignKey (fxWallet fx)) <$> unsigned
            sent `shouldBe` maybe [] pure expected
            map (Set.size . (^. witsTxL . addrTxWitsL)) sent `shouldBe` [1]
    it
        "still reads a journal written before the view point was journalled"
        $ withSystemTempDirectory "singular-write"
        $ \dir -> do
            BS.writeFile (dir </> "journal.jsonl") preS2Journal
            entries <- readJournal dir
            map journalEvent entries `shouldBe` ["prepared", "submitted"]
            fmap journalTxId (unresolved entries) `shouldBe` Just "ab"

-- ---------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------

data Fixture = Fixture
    { fxDir :: FilePath
    , fxChain :: MemoryChain
    , fxWallet :: Wallet
    , fxSent :: IORef [ConwayTx]
    , fxConfirmed :: IORef [String]
    , fxBuiltAt :: IORef (Maybe Cage.ChainPoint)
    , fxUnsigned :: IORef (Maybe ConwayTx)
    }

magic :: Word32
magic = 42

{- | The network and era the chain's views name: neither the magic the
wallet was loaded under nor the era name a journal could write as a
constant, so a journalled point that does not come from the view fails.
-}
viewNetwork :: Word32
viewNetwork = 2_323

viewEra :: Text
viewEra = "era-under-test"

withFixture :: (Fixture -> IO a) -> IO a
withFixture k = withSystemTempDirectory "singular-write" $ \dir -> do
    let keyPath = dir </> "payment.skey"
    BS.writeFile keyPath (B16.encode (BC.replicate 32 'w'))
    w <- loadWallet magic keyPath
    chain <-
        newMemoryChain
            ChainState
                { csNetwork = viewNetwork
                , csEra = viewEra
                , csTip = Nothing
                , csPParams = emptyPParams
                , csUTxO =
                    Map.singleton
                        (outRef 'f')
                        (mkBasicTxOut (walletAddr w) (MaryValue (Coin 50_000_000) mempty))
                , csRegistered = Set.empty
                , csSystemStartMs = 0
                , csSlotLengthMs = 1_000
                }
    mutate chain id
    Fixture (dir </> "registry") chain w
        <$> newIORef []
        <*> newIORef []
        <*> newIORef Nothing
        <*> newIORef Nothing
        >>= k

{- | The write context a command would get from composition, over the
fixture's chain, recording what is submitted and confirmed.
-}
writeContext :: Fixture -> WriteContext
writeContext fx =
    WriteContext
        { wcDir = fxDir fx
        , wcCommand = "insert"
        , wcWallet = fxWallet fx
        , wcCapabilities =
            Capabilities
                { capReads = memoryProvider (fxChain fx)
                , capSubmit = signedSubmitter $ Submitter $ \tx -> do
                    modifyIORef' (fxSent fx) (<> [tx])
                    pure (Submitted (txIdTx tx))
                , capConfirm = \_ txid -> modifyIORef' (fxConfirmed fx) (<> [txid])
                }
        , wcTimeout = Just 5
        }

{- | One write: spend the wallet's output as the view shows it, moving the
chain after the view is acquired.
-}
write :: Fixture -> IO (ConwayTx, ())
write fx =
    submitBuilt (writeContext fx) "fold" (const (expecting "state")) $ \v -> do
        writeIORef (fxBuiltAt fx) (Just (Cage.viewPoint v))
        utxos <- Cage.viewUTxOsAt v (walletAddr (fxWallet fx))
        mutate (fxChain fx) id
        let tx =
                mkBasicTx
                    ( mkBasicTxBody
                        & inputsTxBodyL .~ Set.fromList (map fst utxos)
                        & outputsTxBodyL .~ StrictSeq.fromList (map snd utxos)
                    )
        writeIORef (fxUnsigned fx) (Just tx)
        pure (tx, ())

-- ---------------------------------------------------------
-- The journal as written
-- ---------------------------------------------------------

-- | The journal's @prepared@ lines, as the JSON objects on disk.
preparedLines :: FilePath -> IO [Aeson.Object]
preparedLines dir = do
    raw <- BS.readFile (dir </> "journal.jsonl")
    let objects = mapMaybe (Aeson.decodeStrict @Aeson.Object) (BC.lines raw)
    pure
        [ o | o <- objects, field "journalEvent" o == Just ("prepared" :: Text)
        ]

-- | The network, era and @slot.hash@ a @prepared@ line names, if all three.
journalledPoint :: Aeson.Object -> Maybe (Word32, Text, Text)
journalledPoint o =
    (,,)
        <$> field "journalNetwork" o
        <*> field "journalEra" o
        <*> field "journalChainPoint" o

field :: (Aeson.FromJSON a) => Aeson.Key -> Aeson.Object -> Maybe a
field k = Aeson.parseMaybe (.: k)

renderPoint :: Cage.ChainPoint -> Text
renderPoint p =
    T.pack (show (Cage.unSlotNo (Cage.cpSlot p)))
        <> "."
        <> T.pack (BC.unpack (B16.encode (Cage.cpBlockHash p)))

{- | Two lines as a write before the view point was journalled left them:
a tip slot, a two-part point, no network or era.
-}
preS2Journal :: BS.ByteString
preS2Journal =
    BC.unlines
        [ "{\"journalCommand\":\"insert\",\"journalStep\":\"fold\",\"journalTxId\":\"ab\",\"journalEvent\":\"prepared\",\"journalDetail\":null,\"journalInputs\":[],\"journalTipSlot\":7,\"journalBody\":null,\"journalBodyHash\":null,\"journalChainPoint\":\"7.00\",\"journalKey\":null,\"journalExpect\":\"state\",\"journalEdge\":null,\"journalRootBefore\":null,\"journalRootAfter\":null}"
        , "{\"journalCommand\":\"insert\",\"journalStep\":\"fold\",\"journalTxId\":\"ab\",\"journalEvent\":\"submitted\",\"journalDetail\":null,\"journalInputs\":null,\"journalTipSlot\":null,\"journalBody\":null,\"journalBodyHash\":null,\"journalChainPoint\":null,\"journalKey\":null,\"journalExpect\":null,\"journalEdge\":null,\"journalRootBefore\":null,\"journalRootAfter\":null}"
        ]

outRef :: Char -> TxIn
outRef c =
    either
        (error . ("WriteSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#0")))
