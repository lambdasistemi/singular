{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.State.Script
Description : The Singular state validator of an application, as the builders carry it
License     : Apache-2.0

The state validator takes the application policy as its one parameter, so its
hash is the state policy of a registry, the payment credential of its address
and the policy of the tokens of its keys. A transaction carries the code
either attached to the witness set or from a reference output; a reference
output is used only when the script it carries has the expected hash.
-}
module Singular.State.Script
    ( -- * Where the code comes from
      ScriptSource (..)
    , ReferenceFault (..)
    , findReferenceOutputs
    , referenceOutputs
    , useScript

      -- * The state validator
    , StateScript (..)
    , stateScriptTitle
    , stateScriptFromBlueprint
    , stateScriptHash
    , statePolicy
    , stateAddress
    ) where

import Control.Exception (throwIO)
import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as T
import Lens.Micro ((^.))

import Cardano.Ledger.Address (Addr (..))
import Cardano.Ledger.Api.Tx.Out (referenceScriptTxOutL)
import Cardano.Ledger.BaseTypes (Network, StrictMaybe (..))
import Cardano.Ledger.Core (Script, hashScript)
import Cardano.Ledger.Credential
    ( Credential (..)
    , StakeReference (..)
    )
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (PolicyID (..))
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build (TxBuild)
import Cardano.Tx.Build qualified as Tx

import Singular.Registry.Blueprint
    ( Blueprint
    , applyBytesParam
    , extractCompiledCode
    )
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session
    )
import Singular.Registry.TxBuilder.Internal
    ( scriptFromBytes
    , scriptHashBytes
    )
import Singular.State.Assemble (readOutputs)
import Singular.State.Refusal (Refusal (..))

-- | Where a transaction takes a script's code from.
data ScriptSource
    = -- | The code travels in the transaction's witness set.
      Attached
    | -- | The code is a reference script of this output.
      Referenced TxIn
    deriving stock (Eq, Show)

-- | Why the reference output named for a script cannot be used.
data ReferenceFault
    = -- | The output is not on the chain.
      OutputMissing TxIn
    | {- | The output carries no script, or another one: the hash it carries,
      when it carries a script, and the expected hash.
      -}
      OutputCarries TxIn (Maybe ScriptHash) ScriptHash
    deriving stock (Eq, Show)

{- | The reference outputs a transaction using a script resolves: none when the
code is attached, the output otherwise, after checking that the script it
carries has the expected hash.
-}
findReferenceOutputs
    :: Session NoWitness IO
    -> Script ConwayEra
    -> ScriptSource
    -> IO (Either ReferenceFault [(TxIn, TxOut ConwayEra)])
findReferenceOutputs session script = \case
    Attached -> pure (Right [])
    Referenced reference ->
        readOutputs session (AtTxIn reference) >>= \case
            Left (MissingOutput _) -> pure (Left (OutputMissing reference))
            Left failure -> throwIO failure
            Right [(ref, output)] -> pure (carries ref output)
            Right _ -> pure (Left (OutputMissing reference))
  where
    expected = hashScript script
    carries ref output = case output ^. referenceScriptTxOutL of
        SJust carried
            | hashScript carried == expected -> Right [(ref, output)]
            | otherwise ->
                Left (OutputCarries ref (Just (hashScript carried)) expected)
        SNothing -> Left (OutputCarries ref Nothing expected)

-- | The reference outputs of a script, with the refusal of the state builders.
referenceOutputs
    :: Session NoWitness IO
    -> Script ConwayEra
    -> ScriptSource
    -> IO (Either Refusal [(TxIn, TxOut ConwayEra)])
referenceOutputs session script source =
    first refusal <$> findReferenceOutputs session script source
  where
    refusal = \case
        OutputMissing ref -> ReferenceScriptMissing ref
        OutputCarries ref carried expected ->
            ReferenceScriptMismatch ref carried expected

-- | Make a script available to the transaction under construction.
useScript :: Script ConwayEra -> ScriptSource -> TxBuild q e ()
useScript script = \case
    Attached -> Tx.attachScript script
    Referenced reference -> Tx.reference reference

-- | The state validator of an application and where a transaction takes it from.
data StateScript = StateScript
    { ssScript :: Script ConwayEra
    , ssSource :: ScriptSource
    }

-- | The blueprint title the state validator is read from.
stateScriptTitle :: Text
stateScriptTitle = "singular_state.singular_state.spend"

{- | The state validator a blueprint carries, with the application policy
applied as its parameter.
-}
stateScriptFromBlueprint
    :: Blueprint -> PolicyID -> Either String (Script ConwayEra)
stateScriptFromBlueprint blueprint (PolicyID application) =
    maybe
        (Left ("the blueprint carries no " <> T.unpack stateScriptTitle))
        (Right . scriptFromBytes "singular-state" . applyBytesParam bytes)
        (extractCompiledCode stateScriptTitle blueprint)
  where
    bytes = scriptHashBytes application

-- | The hash of the script: the state policy and the credential of its address.
stateScriptHash :: StateScript -> ScriptHash
stateScriptHash = hashScript . ssScript

-- | The policy of the state tokens and of the tokens of the keys.
statePolicy :: StateScript -> PolicyID
statePolicy = PolicyID . stateScriptHash

-- | The enterprise address of the script on a network.
stateAddress :: Network -> StateScript -> Addr
stateAddress net script =
    Addr net (ScriptHashObj (stateScriptHash script)) StakeRefNull
