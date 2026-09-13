#!/usr/bin/env bash
# rival-ledger-command.sh — LATER ledger witness command receipt (issue #80
# t80e). NOT executed by the offline gate: this file only records the three
# distinct official-app invocations for the rival cases, to run ONLY after an
# explicit owner release of the devnet fence (the own-policy run of the
# 2026-09-12 session remains an UNAUTHORIZED-FENCE-CROSSING record).
#
# Each invocation runs the frozen retirement runner (retirement-rows, built
# from /tmp/t80e-rival-witness) against the pinned devnet/blueprints with the
# RIVAL_VARIANT selection below. RIVAL_OFFLINE_ONLY must stay unset/0 for
# these ledger runs (the offline check binary is a different artifact).
set -euo pipefail

src_root=/tmp/t80e-rival-witness
offchain="$src_root/offchain"

cd "$offchain"

# 1. own-policy rival baseline: A retires while B (own-seeded policy) is
#    installed; the copied-policy successor condition is absent, so the
#    validator must refuse in phase 2 naming the exact application script.
RIVAL_VARIANT=own-policy nix develop --command cabal run retirement-rows -- \
  ${RIVAL_RUN_ARGS:-}

# 2. copied-policy rival (mandatory per NOTE-009): B booted under A's applied
#    representative policy; A retires using ONLY B's state; the typed
#    Submitted result must satisfy the shared checkCopiedSuccessor facts.
RIVAL_VARIANT=copied-policy nix develop --command cabal run retirement-rows -- \
  ${RIVAL_RUN_ARGS:-}

# 3. forged-anchor control (labelled separately, never collapsed): a tokenless
#    output at the MPFS state address anchors the target; the typed phase-2
#    rejection must leave both attempted inputs live (checkRefusalLiveness).
RIVAL_VARIANT=forged-anchor nix develop --command cabal run retirement-rows -- \
  ${RIVAL_RUN_ARGS:-}
