{- |
Module      : Conformance.Run.Replay
Description : Capture a live refusal and replay its failing script with traces
License     : Apache-2.0

At each validator rejection, before the run's next submission, the runner
captures what the node judged — the rejected transaction, every output it
spends or references as the node resolves them, the protocol parameters,
system start and era history — and replays each failing script on the
arguments the ledger builds from that capture: the deployed bytes under the
transaction's declared units, then the traced bytes of the same source, with
the deployed parameters, under the protocol maximum. "Conformance.Replay"
decides what the two runs admit.
-}
module Conformance.Run.Replay
    ( -- * Capture
      checkResolved

      -- * Parameters
    , DeployedApplication (..)
    , AppliedTraced (..)
    , applyDeployedParameters
    ) where

import Data.ByteString.Short (ShortByteString)
import Data.Map.Strict (Map)
import Data.Text (Text)

import Cardano.Ledger.Api.Tx.Out (TxOut)
import Cardano.Ledger.Conway (ConwayEra)
import Cardano.Ledger.Hashes (ScriptHash)
import Cardano.Ledger.TxIn (TxIn)
import Cardano.Tx.Ledger (ConwayTx)

import Conformance.Replay (UnobservedCause (..))

{- | The outputs the node resolved, when they cover every input, reference
input and collateral input the transaction names; 'CaptureIncomplete'
otherwise.
-}
checkResolved
    :: ConwayTx
    -> Map TxIn (TxOut ConwayEra)
    -> Either UnobservedCause (Map TxIn (TxOut ConwayEra))
checkResolved _ _ = error "checkResolved: not implemented"

{- | One application of a validator the run deployed: its blueprint title,
the parameter values as the run applied them, and that application.
-}
data DeployedApplication = DeployedApplication
    { daTitle :: Text
    , daParameters :: Text
    , daApply :: ShortByteString -> ShortByteString
    }

-- | The traced code under a deployed application's parameters.
data AppliedTraced = AppliedTraced
    { atTitle :: Text
    , atParameters :: Text
    , atBytes :: ShortByteString
    , atHash :: ScriptHash
    }
    deriving stock (Show, Eq)

{- | The traced code with the parameters of the deployed application whose
untraced code hashes to the failing hash; 'ParametersMismatch' when no
application does.
-}
applyDeployedParameters
    :: Map Text (ShortByteString, ShortByteString)
    -- ^ per validator title: the deployed (untraced) code, the traced code
    -> [DeployedApplication]
    -> ScriptHash
    -> Either UnobservedCause AppliedTraced
applyDeployedParameters _ _ _ =
    error "applyDeployedParameters: not implemented"
