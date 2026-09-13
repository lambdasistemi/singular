#!/etc/profiles/per-user/paolino/bin/bash
printf "variant=%s naming=%s mpfs=%s identity=%s genesis=%s tmp=%s retireControl=%s recoveryControl=%s\n" "${RIVAL_VARIANT-UNSET}" "${NAMING_BLUEPRINT-UNSET}" "${MPFS_BLUEPRINT-UNSET}" "${NAMING_SCRIPT_IDENTITY-UNSET}" "${E2E_GENESIS_DIR-UNSET}" "${TMPDIR-UNSET}" "${RETIREMENT_CONTROL-UNSET}" "${RECOVERY_CONTROL-UNSET}"
if [[ "${RIVAL_VARIANT-}" == "${STUB_FAILURE_VARIANT-never}" ]]; then exit 7; fi
