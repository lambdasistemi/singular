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

import Data.Text (Text)

import Cardano.Ledger.Address (Addr)
import Cardano.Ledger.BaseTypes (Network)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.Mary.Value (PolicyID)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Build (TxBuild)

import Cardano.Ledger.Core (Script)
import Singular.Registry.Blueprint (Blueprint)
import Singular.Registry.Evidence (NoWitness)
import Singular.Registry.Ledger (ConwayEra, TxOut)
import Singular.Registry.LedgerProvider (Session)

import Singular.Application.OpenDatum.Requests.Refusal (Refusal)

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
requestScriptFromBlueprint _ = Left "Requests.Script.requestScriptFromBlueprint: not built"

-- | The hash of the script: its approval policy and its address credential.
requestScriptHash :: RequestScript -> ScriptHash
requestScriptHash _ = error "Requests.Script.requestScriptHash: not built"

-- | The policy of the tokens the script mints.
requestPolicy :: RequestScript -> PolicyID
requestPolicy _ = error "Requests.Script.requestPolicy: not built"

-- | The enterprise address of the script on a network.
requestAddress :: Network -> RequestScript -> Addr
requestAddress _ _ = error "Requests.Script.requestAddress: not built"

{- | The reference outputs a transaction using the script resolves: none when
the code is attached, the output otherwise, after checking that the script it
carries has the expected hash.
-}
referenceOutputs
    :: Session NoWitness IO
    -> RequestScript
    -> IO (Either Refusal [(TxIn, TxOut ConwayEra)])
referenceOutputs _ _ = error "Requests.Script.referenceOutputs: not built"

-- | Make the script available to the transaction under construction.
useScript :: RequestScript -> TxBuild q e ()
useScript _ = error "Requests.Script.useScript: not built"
