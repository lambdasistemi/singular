{-# LANGUAGE DataKinds #-}

{- |
Module      : Singular.Registry.TxBuilder.Internal
Description : Shared helpers for cage transaction builders (public facade)
License     : Apache-2.0

Utility functions shared across the per-operation
transaction builders (@Boot@, @Request@, @Update@,
@Retract@, @End@). Covers script construction,
datum\/redeemer encoding, address manipulation,
UTxO lookup, spending-index computation,
execution-unit defaults, and POSIX-to-slot
conversion.

This module is the public compatibility facade: it holds no
implementations of its own and re-exports the focused owners
@Singular.Registry.TxBuilder.Internal.Identity@ (identity and
conversion), @...Internal.Lookup@ (lookup and balance) and
@...Internal.Edges@ (edges and binding).
-}
module Singular.Registry.TxBuilder.Internal (
    -- * Script construction
    mkCageScript,
    mkRequestScript,
    scriptFromBytes,
    scriptHashBytes,
    computeScriptHash,

    -- * Registry-mode edges (#157 C2)
    leafAbsent,
    leafActive,
    leafTerminal,
    walkEdge,
    policyIdFromPin,
    addrFromBytes,
    deltaOf,
    policyOfKind,
    approvalName,

    -- * Derived identity
    cagePolicyIdFromCfg,
    cageAddrFromCfg,
    requestAddrFromCfg,
    onChainTokenId,

    -- * Datum helpers
    mkRequestDatum,
    mkRequestDatumWith,
    toPlcData,
    toLedgerData,
    mkInlineDatum,
    extractCageDatum,

    -- * Reference conversion
    txInToRef,
    addrKeyHashBytes,
    addrFromKeyHashBytes,
    addrWitnessKeyHash,

    -- * UTxO lookup
    findUtxoByTxIn,
    findStateUtxo,
    findRequestUtxos,

    -- * Indexing
    spendingIndex,

    -- * Script integrity
    computeScriptIntegrity,

    -- * Evaluate and balance
    evaluateAndBalance,
    placeholderExUnits,

    -- * Constants
    emptyRoot,

    -- * Time and slot helpers
    currentPosixMs,
    trySlots,

    -- * Request helpers
    extractOwnerBytes,

    -- * Refund computation
    computeRefund,

    -- * Pinned-hook invocation (NOTE-021)
    pinScriptHash,
    hookAccountAddress,
    keyAccountAddress,
    ConsumerBinding (..),
    deriveConsumerBinding,
    mkConsumerScript,

    -- * Failure attribution (NOTE-023)
    failedWitnessHash,
    evalScriptHash,
    isBudgetFailure,
) where

import Singular.Registry.TxBuilder.Internal.Edges (
    ConsumerBinding (..),
    approvalName,
    deltaOf,
    deriveConsumerBinding,
    evalScriptHash,
    failedWitnessHash,
    hookAccountAddress,
    isBudgetFailure,
    keyAccountAddress,
    leafAbsent,
    leafActive,
    leafTerminal,
    mkConsumerScript,
    pinScriptHash,
    policyOfKind,
    walkEdge,
 )
import Singular.Registry.TxBuilder.Internal.Identity (
    addrFromBytes,
    addrFromKeyHashBytes,
    addrKeyHashBytes,
    addrWitnessKeyHash,
    cageAddrFromCfg,
    cagePolicyIdFromCfg,
    computeScriptHash,
    emptyRoot,
    extractCageDatum,
    extractOwnerBytes,
    mkCageScript,
    mkInlineDatum,
    mkRequestDatum,
    mkRequestDatumWith,
    mkRequestScript,
    onChainTokenId,
    policyIdFromPin,
    requestAddrFromCfg,
    scriptFromBytes,
    scriptHashBytes,
    toLedgerData,
    toPlcData,
    txInToRef,
 )
import Singular.Registry.TxBuilder.Internal.Lookup (
    computeRefund,
    computeScriptIntegrity,
    currentPosixMs,
    evaluateAndBalance,
    findRequestUtxos,
    findStateUtxo,
    findUtxoByTxIn,
    placeholderExUnits,
    spendingIndex,
    trySlots,
 )
