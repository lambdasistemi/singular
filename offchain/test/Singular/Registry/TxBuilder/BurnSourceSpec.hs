{-# LANGUAGE OverloadedStrings #-}

{- |
Module      : Singular.Registry.TxBuilder.BurnSourceSpec
Description : #177 I177-BUILDER — the retirement burns a token it holds
License     : Apache-2.0

`updateTerminal` (edge ordinal 3) is the only registry edge whose token
column is a burn with no carrier output: @deltaOf 3 = [(active, -1)]@,
and the Lean transaction row
`Singular.Statements.update_terminal_transaction_row` puts the asset it
destroys on a WITNESS INPUT —
@{ role := .witness, assets := [((.active, r.key), 1)] }@ — and on no
output at all.

A mint of @-1@ with no such input is not a retirement. It is a claim the
ledger cannot settle and the cage refuses (`token-missing`), so a builder
that emits it has produced a transaction whose only possible outcome is a
refusal. The failure belongs HERE, in the builder, where it is cheap and
named — the same rule `registryDuties` already applies to the custody an
`updateActive` spends.

These rows are pure. `registryDuties` is the ONE place the off-chain side
decides what an edge owes; it is the decision site this ticket changes,
and these rows assert what it decides, not what a node later does with it.
-}
module Singular.Registry.TxBuilder.BurnSourceSpec (spec) where

import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import Data.Either (isLeft, isRight)
import Data.Word (Word8)
import Test.Hspec

import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx.Out (TxOut, datumTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Network (Testnet))
import Cardano.Ledger.Mary.Value (MaryValue (..))
import Cardano.Ledger.TxIn (TxIn)
import Lens.Micro ((&), (.~))
import PlutusTx.Builtins (toBuiltin)

import Singular.Registry.Config (CageConfig (..))
import Singular.Registry.Deployment (parseOutRef)
import Singular.Registry.Ledger (Coin (..), ConwayEra)
import Singular.Registry.TxBuilder.Internal (
    cageAddrFromCfg,
    computeScriptHash,
    scriptFromBytes,
    leafAbsent,
    leafActive,
    leafTerminal,
    mkInlineDatum,
    toPlcData,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Update (
    RegistryContext (..),
    emptyRegistryContext,
    registryDuties,
 )
import Singular.Registry.Types (
    CageDatum (..),
    OnChainOperation (..),
    OnChainRequest (..),
    OnChainRoot (..),
    OnChainTokenId (..),
    OnChainTokenState (..),
    OnChainTxOutRef,
 )

import Data.Map.Strict qualified as Map
import Data.Text qualified as T

-- ---------------------------------------------------------
-- Fixtures: one registry, two keys
-- ---------------------------------------------------------

keyA :: ByteString
keyA = "t177-key-a"

{- | A 28-byte policy pin, one distinct byte per kind, so a row that
swept the wrong policy could not accidentally agree with the right one.
-}
pin :: Word8 -> SBS.ShortByteString
pin b = SBS.toShort (BS.replicate 28 b)

cfg :: CageConfig
cfg =
    CageConfig
        { cageScriptBytes = SBS.toShort (BS.pack [0x01])
        , requestScriptBytes = SBS.toShort (BS.pack [0x02])
        , cfgScriptHash = computeScriptHash (SBS.toShort (BS.pack [0x01]))
        , cageSeed = seedRef
        , defaultProcessTime = 30000
        , defaultRetractTime = 30000
        , defaultTip = Coin 1000000
        , cfgApplicationPolicy = pin 0xa1
        , cfgActivePolicy = pin 0xa2
        , cfgAbsentPolicy = pin 0xa3
        , cfgTerminalPolicy = pin 0xa4
        , cfgConsumerScript = SBS.empty
        , network = Testnet
        }

seedRef :: OnChainTxOutRef
seedRef = case parseOutRef (T.pack (replicate 64 '1' <> "#0")) of
    Right r -> txInToRef r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

tokenState :: OnChainTokenState
tokenState =
    OnChainTokenState
        { stateRoot = OnChainRoot BS.empty
        , stateMaxFee = 1000000
        , stateProcessTime = 30000
        , stateRetractTime = 30000
        , stateAppPolicy = toBuiltin (SBS.fromShort (cfgApplicationPolicy cfg))
        , stateActivePolicy = toBuiltin (SBS.fromShort (cfgActivePolicy cfg))
        , stateAbsentPolicy = toBuiltin (SBS.fromShort (cfgAbsentPolicy cfg))
        , stateTerminalPolicy = toBuiltin (SBS.fromShort (cfgTerminalPolicy cfg))
        }

requestIn :: TxIn
requestIn = case parseOutRef (T.pack (replicate 64 '2' <> "#0")) of
    Right r -> r
    Left e -> error ("BurnSourceSpec fixture: " <> e)

{- | A request UTxO carrying `op` at `keyA`, and NO approval asset: the
approval-return leg is not what these rows are about, and a request
carrying none leaves it untouched.
-}
requestFor :: OnChainOperation -> (TxIn, TxOut ConwayEra)
requestFor op =
    ( requestIn
    , mkBasicTxOut (cageAddrFromCfg cfg Testnet) (MaryValue (Coin 3000000) mempty)
        & datumTxOutL .~ mkInlineDatum (toPlcData (RequestDatum req))
    )
  where
    req =
        OnChainRequest
            { requestToken = OnChainTokenId (toBuiltin ("t177-registry" :: ByteString))
            , requestOwner = toBuiltin (BS.replicate 28 0x5a)
            , requestKey = keyA
            , requestValue = op
            , requestFee = 1000000
            , requestSubmittedAt = 0
            , requestDestination = ("", "")
            }

{- | The three witness policies the fold mints under. Their BYTES do
not matter to these rows — only that the builder has one per kind, so a
`Left` below is about the burn source and never about a missing script.
-}
witnessScripts :: RegistryContext
witnessScripts =
    emptyRegistryContext
        { rcWitnessScripts =
            Map.fromList
                [ (k, scriptFromBytes "t177 witness" (SBS.toShort (BS.pack [0x59, fromIntegral k])))
                | k <- [0, 1, 2]
                ]
        }

-- | What the builder decides this single request owes.
decide :: OnChainOperation -> Either String ()
decide op =
    ()
        <$ registryDuties
            cfg
            emptyPParams
            tokenState
            witnessScripts
            [requestFor op]
            [True]

-- ---------------------------------------------------------
-- The rows
-- ---------------------------------------------------------

spec :: Spec
spec = describe "#177 I177-BUILDER: updateTerminal sources its burn from a holder" $ do
    -- The row under test. With nothing in hand that carries the key's
    -- active witness, the only transaction this edge could produce mints
    -- `-1` against no input — the shape the cage refuses `token-missing`.
    -- The builder must say so instead of handing back a fold.
    it "refuses to build the retirement when nothing holds the key's active witness" $
        decide (OpUpdate leafActive leafTerminal) `shouldSatisfy` isLeft

    -- The control for the row above, and the reason it is not vacuous:
    -- `updateActive` at the same key, through the same call, with the
    -- same empty context, ALREADY fails — for its own missing custody.
    -- So `registryDuties` is demonstrably able to return `Left` here,
    -- and a green row above is about the retirement, not about the
    -- harness.
    it "already refuses updateActive with no custody in hand (the harness can fail)" $
        decide (OpUpdate leafAbsent leafActive) `shouldSatisfy` isLeft

    -- The other direction: an edge that owes nothing beyond its mint
    -- must still build from the same empty context, so `Left` above is
    -- attributable to the missing witness rather than to the fixture.
    it "still builds an edge that owes no external input (insertAbsent)" $
        decide (OpInsert leafAbsent) `shouldSatisfy` isRight
