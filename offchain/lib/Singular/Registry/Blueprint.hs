{- |
Module      : Singular.Registry.Blueprint
Description : CIP-57 blueprint schema validation (public facade)
License     : Apache-2.0

Minimal CIP-57 Plutus blueprint parser and validator.
Loads a @plutus.json@ blueprint file produced by the
Aiken compiler, extracts type schemas and script
hashes, and validates 'PlutusCore.Data.Data' values
against the declared schemas.

The blueprint also carries optional @compiledCode@
fields (hex-encoded double-CBOR PlutusV3 scripts).
'extractCompiledCode' decodes these into
'ShortByteString' suitable for 'PlutusBinary'.
The state script is parameterized by
@previousPolicies@ (a predecessor-policy allowlist)
via 'applyPreviousPolicies'; the request script is
parameterized by @(statePolicyId, cageToken)@ via
'applyRequestParams'.

This module is the public compatibility facade: it holds no
implementations of its own and re-exports the focused owners
@Singular.Registry.Blueprint.Schema@ (schema and validation),
@Singular.Registry.Blueprint.Params@ (parameter application) and
@Singular.Registry.Blueprint.Load@ (loading and code selection).
-}
module Singular.Registry.Blueprint (
    -- * Schema types
    Blueprint (..),
    Validator (..),
    Schema (..),
    Constructor (..),

    -- * Loading
    loadBlueprint,

    -- * The compiled codes the four registry pins derive from
    NamingCodes (..),

    -- * The registry partition's own compiled code (#173 A173-BOOT)
    loadRegistryCodesFromEnv,

    -- * Validation
    validateData,

    -- * Script hash extraction
    extractScriptHash,

    -- * Compiled code extraction
    extractCompiledCode,

    -- * Parameter application
    applyDataParam,
    applyIntParam,
    applyBytesParam,
    applyOutputRef,
    applyPreviousPolicies,
    applyRequestParams,
) where

import Singular.Registry.Blueprint.Load (
    NamingCodes (..),
    extractCompiledCode,
    extractScriptHash,
    loadBlueprint,
    loadRegistryCodesFromEnv,
 )
import Singular.Registry.Blueprint.Params (
    applyBytesParam,
    applyDataParam,
    applyIntParam,
    applyOutputRef,
    applyPreviousPolicies,
    applyRequestParams,
 )
import Singular.Registry.Blueprint.Schema (
    Blueprint (..),
    Constructor (..),
    Schema (..),
    Validator (..),
    validateData,
 )
