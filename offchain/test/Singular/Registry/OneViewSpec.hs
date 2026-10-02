{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.OneViewSpec
Description : #323 — one operation reads the chain at one point
License     : Apache-2.0

The #300 review found the ordinary CLI reading protocol parameters for
its preview (tree-change-requires-approval) and the builder reading them again (P2): a change that
lands between the two reads enters the built body, so the preview and
the body disagree. These rows run the real request builder against the in-memory chain
adapter, change the protocol parameters and the wallet between the
operation's preview and its build, and compare the built body with the
one the same operation builds when nothing changes. An operation is one
acquired view, so the change never enters; the pre-change shape, the
preview and the build each acquiring their own, lets it in.

The reached control runs a fresh operation after the change and
requires it to differ from the unchanged body, so the change is one the
builder can see: without it, an equal body would prove nothing.
-}
module Singular.Registry.OneViewSpec (spec) where

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Foldable (toList)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Word (Word64)
import Lens.Micro ((&), (.~), (^.))
import Test.Hspec

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.PParams
    ( CoinPerByte (..)
    , emptyPParams
    , ppCoinsPerUTxOByteL
    , ppMaxTxSizeL
    , ppMaxValSizeL
    , ppTxFeeFixedL
    , ppTxFeePerByteL
    )
import Cardano.Ledger.Api.Tx (bodyTxL)
import Cardano.Ledger.Api.Tx.Body
    ( feeTxBodyL
    , inputsTxBodyL
    , outputsTxBodyL
    )
import Cardano.Ledger.Api.Tx.Out (TxOut, coinTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Coin (CompactForm (CompactCoin))
import Cardano.Ledger.Mary.Value (AssetName (..), MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.DeBruijn ()

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger
    ( Coin (..)
    , ConwayEra
    , PParams
    , TokenId (..)
    )
import Singular.Registry.Node.Memory
    ( ChainState (..)
    , MemoryChain
    , memoryProvider
    , mutate
    , newMemoryChain
    )
import Singular.Registry.Provider (Provider (..), View (..))
import Singular.Registry.TxBuilder.Internal
    ( addrFromKeyHashBytes
    , computeScriptHash
    , txInToRef
    )
import Singular.Registry.TxBuilder.Request (requestEdgeImpl)

-- | The chain before anything changes: parameters and the payer's wallet.
initial :: ChainState
initial =
    ChainState
        { csNetwork = 42
        , csEra = "Conway"
        , csTip = Nothing
        , csPParams = params 44 4_310
        , csUTxO = Map.fromList [(outRef '3', ada 100_000_000)]
        , csRegistered = Set.empty
        , csSystemStartMs = 0
        , csSlotLengthMs = 1_000
        }

{- | The change made between preview and build: dearer bytes and a new,
larger wallet output the builder would pick as its fee input.
-}
change :: ChainState -> ChainState
change c =
    c
        { csPParams = params 88 8_620
        , csUTxO = Map.insert (outRef '4') (ada 500_000_000) (csUTxO c)
        }

params :: Word64 -> Word64 -> PParams ConwayEra
params perByte perUTxOByte =
    emptyPParams
        & ppTxFeePerByteL .~ CoinPerByte (CompactCoin perByte)
        & ppTxFeeFixedL .~ Coin 155_381
        & ppCoinsPerUTxOByteL .~ CoinPerByte (CompactCoin perUTxOByte)
        & ppMaxTxSizeL .~ 16_384
        & ppMaxValSizeL .~ 5_000

-- | A chain holding this value, past its origin.
chainOf :: ChainState -> IO MemoryChain
chainOf s = do
    chain <- newMemoryChain s
    mutate chain id
    pure chain

-- | Build the request from one view.
request :: View IO -> IO ConwayTx
request v =
    requestEdgeImpl cfg v (Coin 1_000_000) tokenId "t323-key" 1 payer

{- | One operation: acquire one view, preview its parameters, let
@between@ happen, then build the request from the same view. Returns the
preview's parameters and the body.
-}
operation :: MemoryChain -> IO () -> IO (PParams ConwayEra, ConwayTx)
operation chain between =
    withView (memoryProvider chain) $ \v -> do
        let preview = viewProtocolParams v
        between
        tx <- request v
        pure (preview, tx)

{- | The pre-change shape: the preview reads the chain once and the
builder reads it again, each through its own acquisition.
-}
twoReads :: MemoryChain -> IO () -> IO (PParams ConwayEra, ConwayTx)
twoReads chain between = do
    let prov = memoryProvider chain
    preview <- withView prov (pure . viewProtocolParams)
    between
    tx <- withView prov request
    pure (preview, tx)

-- | What a body commits to that the chain's state decides.
data Shape = Shape
    { shapeFee :: Coin
    , shapeInputs :: Set TxIn
    , shapeLocked :: [Coin]
    }
    deriving (Eq, Show)

shape :: ConwayTx -> Shape
shape tx =
    Shape
        { shapeFee = tx ^. bodyTxL . feeTxBodyL
        , shapeInputs = tx ^. bodyTxL . inputsTxBodyL
        , shapeLocked =
            map (^. coinTxOutL) (toList (tx ^. bodyTxL . outputsTxBodyL))
        }

spec :: Spec
spec = describe "one operation reads the chain at one point (#323)" $ do
    it
        "a parameter and wallet change after the preview never enters the body"
        $ do
            (_, control) <- chainOf initial >>= (`operation` pure ())
            raced <- chainOf initial
            (preview, built) <- operation raced (mutate raced change)
            preview `shouldBe` csPParams initial
            shape built `shouldBe` shape control
    it "a fresh operation after the change sees it (reached control)" $ do
        (_, control) <- chainOf initial >>= (`operation` pure ())
        (preview, fresh) <- chainOf (change initial) >>= (`operation` pure ())
        preview `shouldBe` csPParams (change initial)
        shapeFee (shape fresh) `shouldNotBe` shapeFee (shape control)
        shapeInputs (shape fresh) `shouldNotBe` shapeInputs (shape control)
    it
        "the pre-change shape, preview and build read apart, lets the change in"
        $ do
            (_, control) <- chainOf initial >>= (`operation` pure ())
            raced <- chainOf initial
            (preview, built) <- twoReads raced (mutate raced change)
            preview `shouldBe` csPParams initial
            shape built `shouldNotBe` shape control

-- ---------------------------------------------------------
-- Fixture
-- ---------------------------------------------------------

-- | @\\x y -> x@: the registry scripts take two parameters.
program :: SBS.ShortByteString
program =
    serialiseUPLC
        ( UPLC.Program
            ()
            plcVersion110
            ( UPLC.LamAbs
                ()
                (UPLC.DeBruijn 0)
                ( UPLC.LamAbs
                    ()
                    (UPLC.DeBruijn 0)
                    (UPLC.Var () (UPLC.DeBruijn 2))
                )
            )
        )

cfg :: CageConfig
cfg =
    CageConfig
        { cageScriptBytes = program
        , requestScriptBytes = program
        , cfgScriptHash = computeScriptHash program
        , cageSeed = txInToRef (outRef '1')
        , defaultProcessTime = 30_000
        , defaultRetractTime = 30_000
        , defaultTip = Coin 1_000_000
        , cfgApplicationPolicy = SBS.empty
        , cfgActivePolicy = SBS.empty
        , cfgAbsentPolicy = SBS.empty
        , cfgTerminalPolicy = SBS.empty
        , cfgConsumerScript = SBS.empty
        , network = Testnet
        }

outRef :: Char -> TxIn
outRef c =
    either
        (error . ("OneViewSpec fixture: " <>))
        id
        (parseOutRef (T.pack (replicate 64 c <> "#0")))

ada :: Integer -> TxOut ConwayEra
ada n = mkBasicTxOut payer (MaryValue (Coin n) mempty)

payer :: Addr
payer = addrFromKeyHashBytes Testnet (BS.replicate 28 0x5a)

tokenId :: TokenId
tokenId = TokenId (AssetName "t323-registry")
