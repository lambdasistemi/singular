#!/usr/bin/env bash
# rival-ledger-command.sh — OFFICIAL frozen three-variant ledger command
# (issue #80 t80e; NOTE-041 section 2). Artifact only: this file is never
# executed by the offline gate. It may be run ONLY after an explicit owner
# release of the devnet fence and after the frozen devnet has been
# provisioned at the pinned E2E genesis directories below.
#
# Environment contract for the wrapped retirement-rows binary (complete,
# from offchain/journey/retirement/Main.hs and its E2E Setup library):
#   RIVAL_VARIANT           variant selection: own-policy | copied-policy |
#                           forged-anchor (absent would mean ordinary run;
#                           this command always sets it explicitly)
#   NAMING_BLUEPRINT        REQUIRED absolute blueprint path (pinned below)
#   MPFS_BLUEPRINT          REQUIRED absolute blueprint path (pinned below)
#   NAMING_SCRIPT_IDENTITY  absolute script-identity manifest (pinned below;
#                           the relative default ../naming-onchain/... is
#                           deliberately not relied on)
#   RETIREMENT_CONTROL      unset: official runs execute MainRun, never the
#                           valid/wrong-reason matcher controls
#   RECOVERY_CONTROL        unset: same reason
#   E2E_GENESIS_DIR         the checked-in genesis configuration directory
#                           of the reviewed isolated source (pinned below,
#                           shared by all variants: it is an INPUT, not
#                           runtime state; per-variant runtime isolation
#                           lives in TMPDIR only)
#   TMPDIR                  per-variant absolute temporary directory
# The wrapper script itself prepends the pinned cardano-node 10.7.0 tools to
# PATH; nothing else from the ambient environment is read by Main.hs.
set -euo pipefail

# ------------------------------------------------------------------
# Pinned reviewed identities (verified before any variant could run)
# ------------------------------------------------------------------
readonly NAMING_BLUEPRINT_PATH='/nix/store/phz7qfgh1vrlaxbdyr1qa6r8br8zjd6b-singular-naming-plutus-blueprint-0.1.0'
readonly NAMING_BLUEPRINT_SHA256='87080bed3a39aa145b6415306859ae7fce55284bf1b3bf0cb273f33bab6842c2'
readonly MPFS_BLUEPRINT_PATH='/nix/store/m8rvyvjh2fcz5akmnz4vwilk332n5cn1-mpf-plutus-blueprint-0.0.0'
readonly MPFS_BLUEPRINT_SHA256='f17bf35a72ec0ad906068c978d4f1ef2502c3f10a4742af561bec27b89219765'
readonly RETIREMENT_ROWS_WRAPPER='/nix/store/6dg0qw4ckf4rqypp0svvwr7lxlvj7zdf-retirement-rows/bin/retirement-rows'
readonly RETIREMENT_ROWS_WRAPPER_SHA256='c594918a91a414366deee19cf33e40bb5624cefbcbaa5fc2a6112ff2c5ea2b72'
readonly RETIREMENT_ROWS_CABAL_EXE='/nix/store/ijqlwm0v9sc2z0kwdwvr15hw88dyfkis-cardano-mpfs-cage-exe-retirement-rows-0.1.0.0/bin/retirement-rows'
readonly RETIREMENT_ROWS_CABAL_EXE_SHA256='325f712520d79f3defb17ba535a78204053e877018df072f863234da2544f97a'
readonly PYTHON3_BIN='/nix/store/2p7p4bbn3gmsds24iiy06k98lqdwdzwx-python3-3.11.9-env/bin/python3'
readonly SCRIPT_IDENTITY='/tmp/t80e-rival-witness/naming-onchain/script-identity.json'
readonly SCRIPT_IDENTITY_SHA256='30d969c644f758ffbb477f0534518ec0a2e31871478418c92d783e9b42614b88'
readonly GENESIS_DIR='/tmp/t80e-rival-witness/offchain/e2e-test/genesis'
readonly GENESIS_AGGREGATE_SHA256='4f88e5f1d8b378dc92758c8e3d358f86c87d9945226e921c74335ad9d6e9e631'
readonly RESULT_ROOT='/tmp/t80e-rival-witness/handoffs/rival-ledger-results'

# ------------------------------------------------------------------
# Setup phase: python3 evidence + manifest verification.
# Setup failures exit 2. A setup exit is NEVER a semantic result.
# ------------------------------------------------------------------
readonly SETUP_MANIFEST="${RESULT_ROOT}/setup-manifest.txt"
mkdir -p "${RESULT_ROOT}"
{
  printf '%s  %s\n' "${NAMING_BLUEPRINT_SHA256}" "${NAMING_BLUEPRINT_PATH}"
  printf '%s  %s\n' "${MPFS_BLUEPRINT_SHA256}" "${MPFS_BLUEPRINT_PATH}"
  printf '%s  %s\n' "${RETIREMENT_ROWS_WRAPPER_SHA256}" "${RETIREMENT_ROWS_WRAPPER}"
  printf '%s  %s\n' "${RETIREMENT_ROWS_CABAL_EXE_SHA256}" "${RETIREMENT_ROWS_CABAL_EXE}"
  printf '%s  %s\n' "${SCRIPT_IDENTITY_SHA256}" "${SCRIPT_IDENTITY}"
} > "${SETUP_MANIFEST}"

"${PYTHON3_BIN}" --version
sha256sum --check --strict "${SETUP_MANIFEST}"
test -x "${RETIREMENT_ROWS_WRAPPER}"
test -d "${GENESIS_DIR}"
GENESIS_OBSERVED=$(find "${GENESIS_DIR}" -type f | LC_ALL=C sort | xargs sha256sum | sha256sum)
if [ "${GENESIS_OBSERVED%% *}" != "${GENESIS_AGGREGATE_SHA256}" ]; then
  echo "genesis aggregate hash mismatch: ${GENESIS_OBSERVED%% *}" >&2
  exit 2
fi

# ------------------------------------------------------------------
# Variant 1 of 3: own-policy rival baseline
# ------------------------------------------------------------------
RESULT_DIR="${RESULT_ROOT}/own-policy"
mkdir -p "${RESULT_DIR}/tmp"
TMPDIR="${RESULT_DIR}/tmp" \
RIVAL_VARIANT='own-policy' \
NAMING_BLUEPRINT="${NAMING_BLUEPRINT_PATH}" \
MPFS_BLUEPRINT="${MPFS_BLUEPRINT_PATH}" \
NAMING_SCRIPT_IDENTITY="${SCRIPT_IDENTITY}" \
E2E_GENESIS_DIR="${GENESIS_DIR}" \
set +e
env -u RETIREMENT_CONTROL -u RECOVERY_CONTROL \
  "${RETIREMENT_ROWS_WRAPPER}" \
  > "${RESULT_DIR}/stdout.log" 2> "${RESULT_DIR}/stderr.log"
VARIANT_EXIT=$?
set -e
printf '%s' "${VARIANT_EXIT}" > "${RESULT_DIR}/exit"
env -u RETIREMENT_CONTROL -u RECOVERY_CONTROL \
  TMPDIR="${RESULT_DIR}/tmp" \
  RIVAL_VARIANT='own-policy' \
  NAMING_BLUEPRINT="${NAMING_BLUEPRINT_PATH}" \
  MPFS_BLUEPRINT="${MPFS_BLUEPRINT_PATH}" \
  NAMING_SCRIPT_IDENTITY="${SCRIPT_IDENTITY}" \
  E2E_GENESIS_DIR="${GENESIS_DIR}" \
  env 2>/dev/null | LC_ALL=C sort > "${RESULT_DIR}/environment.txt"

# ------------------------------------------------------------------
# Variant 2 of 3: copied-policy rival (mandatory authentic B transition)
# ------------------------------------------------------------------
RESULT_DIR="${RESULT_ROOT}/copied-policy"
mkdir -p "${RESULT_DIR}/tmp"
TMPDIR="${RESULT_DIR}/tmp" \
RIVAL_VARIANT='copied-policy' \
NAMING_BLUEPRINT="${NAMING_BLUEPRINT_PATH}" \
MPFS_BLUEPRINT="${MPFS_BLUEPRINT_PATH}" \
NAMING_SCRIPT_IDENTITY="${SCRIPT_IDENTITY}" \
E2E_GENESIS_DIR="${GENESIS_DIR}" \
set +e
env -u RETIREMENT_CONTROL -u RECOVERY_CONTROL \
  "${RETIREMENT_ROWS_WRAPPER}" \
  > "${RESULT_DIR}/stdout.log" 2> "${RESULT_DIR}/stderr.log"
VARIANT_EXIT=$?
set -e
printf '%s' "${VARIANT_EXIT}" > "${RESULT_DIR}/exit"
env -u RETIREMENT_CONTROL -u RECOVERY_CONTROL \
  TMPDIR="${RESULT_DIR}/tmp" \
  RIVAL_VARIANT='copied-policy' \
  NAMING_BLUEPRINT="${NAMING_BLUEPRINT_PATH}" \
  MPFS_BLUEPRINT="${MPFS_BLUEPRINT_PATH}" \
  NAMING_SCRIPT_IDENTITY="${SCRIPT_IDENTITY}" \
  E2E_GENESIS_DIR="${GENESIS_DIR}" \
  env 2>/dev/null | LC_ALL=C sort > "${RESULT_DIR}/environment.txt"

# ------------------------------------------------------------------
# Variant 3 of 3: forged-anchor control (labelled separately, never
# collapsed into an authentic transition)
# ------------------------------------------------------------------
RESULT_DIR="${RESULT_ROOT}/forged-anchor"
mkdir -p "${RESULT_DIR}/tmp"
TMPDIR="${RESULT_DIR}/tmp" \
RIVAL_VARIANT='forged-anchor' \
NAMING_BLUEPRINT="${NAMING_BLUEPRINT_PATH}" \
MPFS_BLUEPRINT="${MPFS_BLUEPRINT_PATH}" \
NAMING_SCRIPT_IDENTITY="${SCRIPT_IDENTITY}" \
E2E_GENESIS_DIR="${GENESIS_DIR}" \
set +e
env -u RETIREMENT_CONTROL -u RECOVERY_CONTROL \
  "${RETIREMENT_ROWS_WRAPPER}" \
  > "${RESULT_DIR}/stdout.log" 2> "${RESULT_DIR}/stderr.log"
VARIANT_EXIT=$?
set -e
printf '%s' "${VARIANT_EXIT}" > "${RESULT_DIR}/exit"
env -u RETIREMENT_CONTROL -u RECOVERY_CONTROL \
  TMPDIR="${RESULT_DIR}/tmp" \
  RIVAL_VARIANT='forged-anchor' \
  NAMING_BLUEPRINT="${NAMING_BLUEPRINT_PATH}" \
  MPFS_BLUEPRINT="${MPFS_BLUEPRINT_PATH}" \
  NAMING_SCRIPT_IDENTITY="${SCRIPT_IDENTITY}" \
  E2E_GENESIS_DIR="${GENESIS_DIR}" \
  env 2>/dev/null | LC_ALL=C sort > "${RESULT_DIR}/environment.txt"

# Every variant's true exit lives in its own exit file; the receipts are the
# per-variant directories. The official command aggregates the recorded
# exits and returns nonzero if ANY variant exit is nonzero: the own-policy
# and forged-anchor expected refusals are successful harness outcomes only
# after their typed assertions (exit 0), and copied-policy likewise only
# after its acceptance/successor assertions (exit 0).
OWN_EXIT=$(cat "${RESULT_ROOT}/own-policy/exit")
COPIED_EXIT=$(cat "${RESULT_ROOT}/copied-policy/exit")
FORGED_EXIT=$(cat "${RESULT_ROOT}/forged-anchor/exit")
echo "variant exits: own-policy=${OWN_EXIT} copied-policy=${COPIED_EXIT} forged-anchor=${FORGED_EXIT}"
if [ "${OWN_EXIT}" -ne 0 ] || [ "${COPIED_EXIT}" -ne 0 ] || [ "${FORGED_EXIT}" -ne 0 ]; then
  echo "rival-ledger-command: at least one variant exited nonzero" >&2
  exit 1
fi
exit 0
