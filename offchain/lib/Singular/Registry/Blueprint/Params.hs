{- |
Module      : Singular.Registry.Blueprint.Params
Description : UPLC parameter application for blueprint compiled code
License     : Apache-2.0

Applies the registry's parameters to the flat-encoded UPLC programs a
blueprint carries: raw 'Data' values, integers, bytes, output
references, the state validator's @previousPolicies@ allowlist, and
the request validator's @(statePolicyId, cageToken)@ pair in source
order.

This is the parameter-application owner extracted from
@Singular.Registry.Blueprint@; the public module re-exports it and is
its only intended consumer surface.
-}
module Singular.Registry.Blueprint.Params (
    applyDataParam,
    applyIntParam,
    applyBytesParam,
    applyOutputRef,
    applyPreviousPolicies,
    applyRequestParams,
) where

import Data.ByteString qualified as BS
import Data.ByteString.Short qualified as SBS
import PlutusCore qualified as PLC
import PlutusCore.Data (Data (..))
import PlutusLedgerApi.V3 (
    serialiseUPLC,
    uncheckedDeserialiseUPLC,
 )
import PlutusTx.Builtins.Internal (
    BuiltinByteString (..),
    BuiltinData (..),
 )
import PlutusTx.IsData.Class (ToData (..))
import Singular.Registry.Types (
    OnChainTokenId (..),
    OnChainTxOutRef,
 )
import UntypedPlutusCore (
    Program (..),
    applyProgram,
 )
import UntypedPlutusCore qualified as UPLC
import UntypedPlutusCore.DeBruijn ()

{- | Apply a 'Data' parameter to a UPLC script.
The blueprint's @compiledCode@ is a flat-encoded
UPLC program that expects one parameter. This
function applies the supplied 'Data' value to that
parameter slot, producing the final script bytes.
-}
applyDataParam ::
    -- | Encoded parameter value
    Data ->
    -- | Flat-encoded UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyDataParam d sbs =
    let
        prog = uncheckedDeserialiseUPLC sbs
        argProg =
            Program
                ()
                (progVer prog)
                ( UPLC.Constant
                    ()
                    ( PLC.Some
                        ( PLC.ValueOf
                            PLC.DefaultUniData
                            d
                        )
                    )
                )
        applied = case applyProgram prog argProg of
            Right p -> p
            Left e ->
                error $
                    "applyDataParam: "
                        <> show e
     in
        serialiseUPLC applied
  where
    progVer (Program _ v _) = v

{- | Apply an integer parameter to a UPLC script.

`witness(kind, registry)` (#157 C5) takes its kind as a plain integer, and
the deployment applies it three times. Wrapping the `Data` encoding here
keeps the 'PlutusCore.Data' vocabulary inside this module, where the rest
of the blueprint's encoding already lives.
-}
applyIntParam ::
    -- | Encoded integer parameter
    Integer ->
    -- | Flat-encoded UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyIntParam = applyDataParam . I

-- | Apply a raw bytes parameter to a UPLC script.
applyBytesParam ::
    -- | Encoded bytes parameter
    BS.ByteString ->
    -- | Flat-encoded UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyBytesParam bs =
    applyDataParam (B bs)

{- | Apply an 'OnChainTxOutRef' parameter to a UPLC
script. Wraps 'applyDataParam' with the canonical
@Constr 0 [bytes, integer]@ encoding produced by the
'ToData OnChainTxOutRef' instance — matching what the
on-chain validator's parameter slot expects when the
Aiken validator is parameterized by an
@OutputReference@.
-}
applyOutputRef ::
    -- | Output reference to apply as the seed parameter
    OnChainTxOutRef ->
    -- | Flat-encoded UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyOutputRef ref sbs =
    let BuiltinData d = toBuiltinData ref
     in applyDataParam d sbs

{- | Apply the state validator's @previousPolicies@
allowlist parameter. The on-chain parameter type is
@List\<PolicyId\>@, encoded as
@List [B pid0, B pid1, …]@ (an empty @List []@ for a
genesis cage, which makes migration into it
impossible).
-}
applyPreviousPolicies ::
    -- | Predecessor policy-id bytes (28 bytes each); @[]@ for genesis
    [BS.ByteString] ->
    -- | Flat-encoded raw state UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyPreviousPolicies pids =
    applyDataParam (List (map B pids))

{- | Apply request-validator parameters in source
order: @statePolicyId@ first, then @cageTokenName@.
-}
applyRequestParams ::
    -- | State policy id bytes
    BS.ByteString ->
    -- | Cage token asset name
    OnChainTokenId ->
    -- | Flat-encoded request UPLC program
    SBS.ShortByteString ->
    SBS.ShortByteString
applyRequestParams statePolicyId (OnChainTokenId (BuiltinByteString token)) sbs =
    applyBytesParam token $
        applyBytesParam statePolicyId sbs
