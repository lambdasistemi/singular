{- |
Module      : Singular.State.Genesis
Description : Create a registry: spend a seed, mint the state token, write the empty root
License     : Apache-2.0

The genesis transaction spends a seed, mints the one state token named from
it and creates the one state output that holds the token, at the address of the
state script, with the empty root. It ends an hour from the tip, so that a
creation the chain never took can be proved excluded. The application adds its
own steps to the same transaction (for open datum, the registry's
configuration record), and the registry the transaction creates is returned
with it.
-}
module Singular.State.Genesis
    ( buildGenesis
    ) where

import Control.Monad.Except (ExceptT (..), runExceptT, throwError)
import Control.Monad.IO.Class (liftIO)
import Data.Map.Strict qualified as Map
import PlutusTx.Builtins.Internal (BuiltinData (..))

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.Coin (Coin (..))
import Cardano.Ledger.Mary.Value (MaryValue (..), MultiAsset (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build qualified as Tx
import Cardano.Tx.Ledger (ConwayTx)

import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider (Session)
import Singular.Registry.SessionIO (outputsAt)
import Singular.Registry.TrieState
    ( RegistryIdentity (..)
    , StatePolicyId (..)
    )
import Singular.Registry.TxBuilder.Internal
    ( emptyRoot
    , scriptHashBytes
    )
import Singular.State.Assemble
    ( Payer (..)
    , Program
    , assembleTransaction
    , noUsableWindow
    , resolvePayer
    , usualSpan
    , windowFromTip
    )
import Singular.State.Preimage (stateTokenName)
import Singular.State.Records (genesisRedeemer, stateDatum)
import Singular.State.Refusal (Refusal (..))
import Singular.State.Script
    ( StateScript (..)
    , referenceOutputs
    , stateAddress
    , statePolicy
    , stateScriptHash
    , useScript
    )

{- | Build the genesis transaction of the registry the seed creates. The payer
funds it and holds the seed. The application's steps receive the registry
being created and add their outputs and mints to the same transaction. The
outputs that carry the application's code, when it is referenced and not
attached, are priced with the state script's, so that the fee covers every
reference script the transaction names.
-}
buildGenesis
    :: Session NoWitness IO
    -> StateScript
    -> TxIn
    -- ^ The seed: an unspent output of the payer, spent by the genesis
    -> Addr
    -- ^ The payer: fee, collateral and change
    -> [(TxIn, TxOut ConwayEra)]
    {- ^ The outputs that carry the application's code, already checked, when
    it is referenced
    -}
    -> (RegistryIdentity -> Program ())
    -- ^ The application's steps of the creation
    -> IO (Either Refusal (ConwayTx, RegistryIdentity))
buildGenesis session script seed payerAddress applicationReferences application = runExceptT $ do
    payer <- ExceptT (resolvePayer session payerAddress)
    owned <- liftIO (outputsAt session payerAddress)
    seedOutput <-
        maybe (throwError (SeedNotAtPayer seed)) pure (lookup seed owned)
    scriptOutputs <-
        ExceptT (referenceOutputs session (ssScript script) (ssSource script))
    upper <-
        liftIO (windowFromTip session usualSpan)
            >>= maybe (throwError (BuildFailed noUsableWindow)) (pure . snd)
    let name = stateTokenName seed
        policy = statePolicy script
        registry =
            RegistryIdentity
                (StatePolicyId (scriptHashBytes (stateScriptHash script)))
                name
        funding = payerFunding payer
        spent = (seed, seedOutput) : [funding | fst funding /= seed]
        token =
            MaryValue
                (Coin 0)
                (MultiAsset (Map.singleton policy (Map.singleton name 1)))
    tx <-
        ExceptT $
            assembleTransaction
                session
                spent
                (scriptOutputs <> applicationReferences)
                payerAddress
                ( do
                    _ <-
                        Tx.payTo'
                            (stateAddress (payerNetwork payer) script)
                            token
                            (BuiltinData (stateDatum emptyRoot))
                    Tx.mint
                        policy
                        (Map.singleton name 1)
                        (BuiltinData (genesisRedeemer seed))
                    useScript (ssScript script) (ssSource script)
                    application registry
                    Tx.validTo upper
                    Tx.collateral (fst funding)
                )
    pure (tx, registry)
