{- |
Module      : Singular.Application.KeriStub.Script
Description : The stub's always-succeeding Plutus V3 script, as a constant
License     : Apache-2.0

One always-succeeding Plutus V3 script, built by the stub itself: the
serialised two-argument program returning unit, no Aiken project, no
blueprint. It is both the approval minting policy and the spending
script of the holdings the stub creates; its hash is the pin.
-}
module Singular.Application.KeriStub.Script
    ( -- * The script
      keriStubScriptBytes
    , keriStubScript
    , keriStubPolicy
    ) where

import Data.ByteString (ByteString)
import Data.ByteString.Short qualified as SBS

import PlutusCore.MkPlc (mkConstant)
import PlutusCore.Version (plcVersion110)
import PlutusLedgerApi.V3 (serialiseUPLC)
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.DeBruijn ()

import Cardano.Ledger.Core (Script)

import Singular.Registry.Ledger (ConwayEra)
import Singular.Registry.TxBuilder.Internal
    ( computeScriptHash
    , scriptFromBytes
    , scriptHashBytes
    )

-- | The always-succeeding program: two arguments, unit.
keriStubScriptBytes :: SBS.ShortByteString
keriStubScriptBytes =
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
                    (mkConstant () ())
                )
            )
        )

-- | The script, from its bytes.
keriStubScript :: Script ConwayEra
keriStubScript =
    scriptFromBytes "keri-stub" keriStubScriptBytes

-- | Its hash: the approval policy and the holdings' script hash.
keriStubPolicy :: ByteString
keriStubPolicy =
    scriptHashBytes (computeScriptHash keriStubScriptBytes)
