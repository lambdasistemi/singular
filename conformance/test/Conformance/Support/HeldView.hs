{-# LANGUAGE LambdaCase #-}

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

import Cardano.Ledger.Api.Tx (mkBasicTx, txIdTx)
import Cardano.Ledger.Api.Tx.Body (mkBasicTxBody)
import Cardano.Ledger.Api.Tx.Out (addrTxOutL, mkBasicTxOut)
import Cardano.Ledger.BaseTypes (Inject (..), TxIx (..))
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Node.Client.E2E.Setup (genesisAddr)
import Cardano.Tx.Ledger (ConwayTx)
import Singular.Registry.Evidence
    ( Evidenced (..)
    , NoWitness
    , SessionBinding (..)
    , SessionId (..)
    )
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( HistoryFailure (..)
    , Network (..)
    , OutputQuery (..)
    , ReadFailure (..)
    , Session (..)
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

{- | Immutable raw outputs in one synthetic acquisition. These controls
assert exact output presence/content and make no live snapshot/time claim.
-}
viewOf :: [(TxIn, TxOut ConwayEra)] -> Session NoWitness IO
viewOf utxos =
    Session
        { sessionNetwork = Network 42
        , sessionId = SessionId "held-input-control"
        , sessionBinding = Unbound
        , sessionTracer = mempty
        , outputs = \case
            AtAddress address ->
                pure
                    ( Right
                        ( Evidenced
                            [u | u@(_, out) <- utxos, out ^. addrTxOutL == address]
                            Nothing
                        )
                    )
            _ ->
                pure
                    ( Left
                        (BackendReadFailure "held-input control only supplies address outputs")
                    )
        , protocolParameters = unavailable
        , tipObservation = unavailable
        , networkTime = unavailable
        , scriptRegistered = const unavailable
        , history = \_ _ ->
            pure
                ( Left
                    ( HistoryReadFailure
                        (BackendReadFailure "held-input control supplies no history")
                    )
                )
        }
  where
    unavailable =
        pure
            (Left (BackendReadFailure "held-input control only supplies outputs"))

refusedWith :: String -> ErrorCall -> Bool
refusedWith fragment (ErrorCall message) = fragment `isInfixOf` message

spec :: Spec
spec =
    describe
        "Appendix: a hand-built transaction takes its chain inputs from one view"
        $ do
            it "accepts an input the assembly's view holds as the row read it" $
                heldInput (viewOf [input 5_000_000]) "state" (input 5_000_000)
                    `shouldReturn` ()
            it "refuses, by name, an input spent before the assembly's view" $
                heldInput (viewOf []) "state" (input 5_000_000)
                    `shouldThrow` refusedWith
                        "the state input TxIn"
            it
                "names the spent input as not unspent at the assembly's chain point"
                $ heldInput (viewOf []) "request" (input 5_000_000)
                    `shouldThrow` refusedWith
                        "is not unspent at the assembly's chain point"
            it
                "refuses, by name, an input that holds something else in the assembly's view"
                $ heldInput (viewOf [input 4_000_000]) "funder" (input 5_000_000)
                    `shouldThrow` refusedWith
                        "changed between the row's read and the assembly's view"
