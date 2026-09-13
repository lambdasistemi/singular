RESULT_DIR=/review/result
NAMING_BLUEPRINT_PATH=/review/naming
MPFS_BLUEPRINT_PATH=/review/mpfs
SCRIPT_IDENTITY=/review/identity
GENESIS_DIR=/review/genesis
RETIREMENT_ROWS_WRAPPER=/tmp/singular-root-rival-shell-env-NqiImO/stub.sh
TMPDIR="${RESULT_DIR}/tmp" \
RIVAL_VARIANT='own-policy' \
NAMING_BLUEPRINT="${NAMING_BLUEPRINT_PATH}" \
MPFS_BLUEPRINT="${MPFS_BLUEPRINT_PATH}" \
NAMING_SCRIPT_IDENTITY="${SCRIPT_IDENTITY}" \
E2E_GENESIS_DIR="${GENESIS_DIR}" \
set +e
env -u RETIREMENT_CONTROL -u RECOVERY_CONTROL \
  "${RETIREMENT_ROWS_WRAPPER}"
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
  "${RETIREMENT_ROWS_WRAPPER}"
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
  "${RETIREMENT_ROWS_WRAPPER}"
