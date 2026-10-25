{-# LANGUAGE LambdaCase #-}

{- |
Module      : Singular.Application.OpenDatum.Requests.Script
Description : The open-datum request validator as the builders carry it
License     : Apache-2.0

The request validator takes no parameter, so its hash is the policy of its
approval and configuration tokens and the payment credential of the address of
pending registrations and configuration records. A transaction carries its
code either attached to the witness set or from a reference output; a
reference output is used only when the script it carries has the expected hash.
-}
module Singular.Application.OpenDatum.Requests.Script
    ( -- * The script
      ScriptSource (..)
    , RequestScript (..)
    , requestScriptTitle
    , requestScriptFromBlueprint
    , requestScriptHash
    , requestPolicy
    , requestAddress

      -- * In a transaction
    , referenceOutputs
    , useScript
    ) where

import Control.Exception (throwIO)
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

import Singular.Application.OpenDatum.Requests.Assemble (readOutputs)
import Singular.Application.OpenDatum.Requests.Refusal (Refusal (..))
import Singular.Registry.Blueprint (Blueprint, extractCompiledCode)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider
    ( OutputQuery (..)
    , ReadFailure (..)
    , Session
    )
import Singular.Registry.TxBuilder.Internal (scriptFromBytes)

-- | Where a transaction takes the script's code from.
data ScriptSource
    = -- | The code travels in the transaction's witness set.
      Attached
    | -- | The code is a reference script of this output.
      Referenced TxIn
    deriving stock (Eq, Show)

-- | The compiled request validator and where a transaction takes it from.
data RequestScript = RequestScript
    { rsScript :: Script ConwayEra
    , rsSource :: ScriptSource
    }

-- | The blueprint title the request validator is read from.
requestScriptTitle :: Text
requestScriptTitle = "open_datum_requests.open_datum_requests.spend"

-- | The request validator a blueprint carries.
requestScriptFromBlueprint
    :: Blueprint -> Either String (Script ConwayEra)
requestScriptFromBlueprint blueprint =
    maybe
        (Left ("the blueprint carries no " <> T.unpack requestScriptTitle))
        (Right . scriptFromBytes "open-datum-requests")
        (extractCompiledCode requestScriptTitle blueprint)

-- | The hash of the script: its approval policy and its address credential.
requestScriptHash :: RequestScript -> ScriptHash
requestScriptHash = hashScript . rsScript

-- | The policy of the tokens the script mints.
requestPolicy :: RequestScript -> PolicyID
requestPolicy = PolicyID . requestScriptHash

-- | The enterprise address of the script on a network.
requestAddress :: Network -> RequestScript -> Addr
requestAddress net script =
    Addr net (ScriptHashObj (requestScriptHash script)) StakeRefNull

{- | The reference outputs a transaction using the script resolves: none when
the code is attached, the output otherwise, after checking that the script it
carries has the expected hash.
-}
referenceOutputs
    :: Session NoWitness IO
    -> RequestScript
    -> IO (Either Refusal [(TxIn, TxOut ConwayEra)])
referenceOutputs session script = case rsSource script of
    Attached -> pure (Right [])
    Referenced reference ->
        readOutputs session (AtTxIn reference) >>= \case
            Left (MissingOutput _) -> pure (Left (ReferenceScriptMissing reference))
            Left failure -> throwIO failure
            Right found -> pure $ case found of
                [(ref, output)] -> carries ref output
                _ -> Left (ReferenceScriptMissing reference)
  where
    expected = requestScriptHash script
    carries ref output = case output ^. referenceScriptTxOutL of
        SJust carried
            | hashScript carried == expected -> Right [(ref, output)]
            | otherwise ->
                Left
                    (ReferenceScriptMismatch ref (Just (hashScript carried)) expected)
        SNothing -> Left (ReferenceScriptMismatch ref Nothing expected)

-- | Make the script available to the transaction under construction.
useScript :: RequestScript -> TxBuild q e ()
useScript script = case rsSource script of
    Attached -> Tx.attachScript (rsScript script)
    Referenced reference -> Tx.reference reference
