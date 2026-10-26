{- |
Module      : Singular.State.Publication
Description : Publish the scripts of an application once and reuse the live copies
License     : Apache-2.0

A transaction that runs the state validator or the application's validator
carries its code from a reference output. The first registry of an application
publishes both scripts; a later registry finds the live copies and publishes
nothing. A copy is live when an output of the chain carries a reference script
whose hash, computed from the script itself, is the expected one; an output
that carries another script is never reused, whatever the provider claims.
-}
module Singular.State.Publication
    ( References (..)
    , Publication (..)
    , planReferences
    , planNextReference
    ) where

import Control.Exception (throwIO)
import Control.Monad.Except (ExceptT (..), runExceptT)
import Control.Monad.IO.Class (liftIO)
import Data.List (minimumBy, nubBy)
import Data.Maybe (catMaybes)
import Data.Ord (comparing)
import Lens.Micro ((&), (.~), (^.))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Api.Tx (bodyTxL, txIdTx)
import Cardano.Ledger.Api.Tx.Body (outputsTxBodyL)
import Cardano.Ledger.Api.Tx.Out
    ( coinTxOutL
    , getMinCoinTxOut
    , mkBasicTxOut
    , referenceScriptTxOutL
    )
import Cardano.Ledger.BaseTypes
    ( Inject (..)
    , StrictMaybe (..)
    , TxIx (..)
    )
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Core (PParams, Script, hashScript)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.TxIn (TxIn (..))
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)
import Data.Foldable (toList)

import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , Session
    )
import Singular.Registry.SessionIO (parameters)
import Singular.State.Assemble
    ( Payer (..)
    , assembleTransaction
    , readOutputs
    , resolvePayer
    )
import Singular.State.Refusal (Refusal (..))

-- | The transaction that publishes the scripts no live output carries.
data Publication = Publication
    { publicationTx :: ConwayTx
    , publicationOutputs :: [(ScriptHash, TxIn)]
    {- ^ Where each published script will sit once the transaction is on the
    chain
    -}
    }

-- | Where the scripts of an application can be read from.
data References = References
    { referencesLive :: [(ScriptHash, (TxIn, TxOut ConwayEra))]
    -- ^ The live copies that are reused
    , referencesPublication :: Maybe Publication
    -- ^ The publication of the others; nothing when every script is live
    }

{- | Find the live copy of each script and plan the publication of the others,
at the payer's address: one transaction that holds every missing script in an
output of its own.
-}
planReferences
    :: Session NoWitness IO
    -> Addr
    -- ^ The payer: fee, collateral, change and the owner of the new outputs
    -> [Script ConwayEra]
    -> IO (Either Refusal References)
planReferences session payerAddress requested = runExceptT $ do
    found <-
        liftIO
            (mapM (\script -> (,) script <$> liveCopy session script) scripts)
    let live = [(hashScript script, copy) | (script, Just copy) <- found]
        missing = [script | (script, Nothing) <- found]
    publication <-
        if null missing
            then pure Nothing
            else Just <$> ExceptT (publish session payerAddress missing)
    pure (References live publication)
  where
    scripts = nubBy (\a b -> hashScript a == hashScript b) requested

{- | Find every live copy and plan the next publication, in the order requested.
Call again after that transaction is live, using the new chain view.
-}
planNextReference
    :: Session NoWitness IO
    -> Addr
    -> [Script ConwayEra]
    -> IO (Either Refusal References)
planNextReference = planReferences

{- | The live output with the lowest reference that carries this script as a
reference script. The provider's answer to the query is a list of candidates:
each one is checked against the hash of the script.
-}
liveCopy
    :: Session NoWitness IO
    -> Script ConwayEra
    -> IO (Maybe (TxIn, TxOut ConwayEra))
liveCopy session script = do
    candidates <-
        readOutputs session (CarryingReferenceScript hash)
            >>= either throwIO pure
    pure $ case filter (carries . snd) candidates of
        [] -> Nothing
        genuine -> Just (minimumBy (comparing fst) genuine)
  where
    hash = hashScript script
    carries output = case output ^. referenceScriptTxOutL of
        SJust carried -> hashScript carried == hash
        SNothing -> False

-- | Publish these scripts, each in an output of the payer's address.
publish
    :: Session NoWitness IO
    -> Addr
    -> [Script ConwayEra]
    -> IO (Either Refusal Publication)
publish session payerAddress missing = runExceptT $ do
    payer <- ExceptT (resolvePayer session payerAddress)
    protocol <- liftIO (parameters session)
    let holders = map (holder protocol payerAddress) missing
    tx <-
        ExceptT $
            assembleTransaction
                session
                [payerFunding payer]
                []
                payerAddress
                (mapM_ Tx.output holders >> Tx.checkTxSize protocol)
    pure (Publication tx (located tx))
  where
    located tx =
        catMaybes
            [ case out ^. referenceScriptTxOutL of
                SJust carried ->
                    Just (hashScript carried, TxIn (txIdTx tx) (TxIx ix))
                SNothing -> Nothing
            | (ix, out) <- zip [0 ..] (toList (tx ^. bodyTxL . outputsTxBodyL))
            ]

{- | An output at the address that carries the script as a reference script,
holding the minimum ADA the ledger requires of it.
-}
holder
    :: PParams ConwayEra
    -> Addr
    -> Script ConwayEra
    -> TxOut ConwayEra
holder protocol address script =
    probe & coinTxOutL .~ getMinCoinTxOut protocol probe
  where
    probe =
        mkBasicTxOut address (inject (Coin 1_000_000_000))
            & referenceScriptTxOutL .~ SJust script
