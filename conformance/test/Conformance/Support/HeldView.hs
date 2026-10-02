{- | A hand-built transaction takes its chain inputs from one view.

Appendix material: a row reads the outputs a hand-built fold spends, then
assembles the fold in one acquired view. The assembly finds every such
input again in that view, so a fold cannot mix outputs from two chain
points: an input spent in between, or holding something else, stops the
assembly by name.
-}
module Conformance.Support.HeldView (spec) where

import Control.Exception (ErrorCall (..))
import Data.List (isInfixOf)
import Lens.Micro ((^.))
import Test.Hspec (Spec, describe, it, shouldReturn, shouldThrow)

import Cardano.Ledger.Api.PParams (emptyPParams)
import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Inject (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.Provider
    ( ChainPoint (..)
    , SlotNo (..)
    , View (..)
    )

import Conformance.Run.Fold (heldInput)

-- | A transaction whose id names the output.
anyTx :: ConwayTx
anyTx = mkBasicTx mkBasicTxBody

-- | One output at the funding address, spendable by its reference.
input :: Integer -> (TxIn, TxOut ConwayEra)
input coin =
    ( TxIn (txIdTx anyTx) (TxIx 0)
    , mkBasicTxOut genesisAddr (inject (Coin coin))
    )

-- | A view of a chain point holding exactly these outputs.
viewOf :: [(TxIn, TxOut ConwayEra)] -> View IO
viewOf utxos =
    View
        { viewPoint = ChainPoint 42 "Conway" (SlotNo 1) "held"
        , viewProtocolParams = emptyPParams
        , viewUTxOsAt = \a -> pure [u | u@(_, o) <- utxos, o ^. addrTxOutL == a]
        , viewScriptRegistered = \_ -> pure False
        , viewEvaluateTx = \_ -> pure mempty
        , viewPosixMsToSlot = \_ -> pure (SlotNo 0)
        , viewPosixMsCeilSlot = \_ -> pure (SlotNo 0)
        }

refusedWith :: String -> ErrorCall -> Bool
refusedWith fragment (ErrorCall message) = fragment `isInfixOf` message

spec :: Spec
spec =
    describe
        "Appendix: a hand-built transaction takes its chain inputs from one view" $ do
        it "accepts an input the assembly's view holds as the row read it" $
            heldInput (viewOf [input 5_000_000]) "state" (input 5_000_000)
                `shouldReturn` ()
        it "refuses, by name, an input spent before the assembly's view" $
            heldInput (viewOf []) "state" (input 5_000_000)
                `shouldThrow` refusedWith
                    "the state input TxIn"
        it
            "names the spent input as not unspent at the assembly's chain point" $
            heldInput (viewOf []) "request" (input 5_000_000)
                `shouldThrow` refusedWith
                    "is not unspent at the assembly's chain point"
        it
            "refuses, by name, an input that holds something else in the assembly's view" $
            heldInput (viewOf [input 4_000_000]) "funder" (input 5_000_000)
                `shouldThrow` refusedWith
                    "changed between the row's read and the assembly's view"
