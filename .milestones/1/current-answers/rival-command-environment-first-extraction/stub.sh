#!/etc/profiles/per-user/paolino/bin/bash
printf "variant=%s naming=%s mpfs=%s genesis=%s tmp=%s\n" "${RIVAL_VARIANT-UNSET}" "${NAMING_BLUEPRINT-UNSET}" "${MPFS_BLUEPRINT-UNSET}" "${E2E_GENESIS_DIR-UNSET}" "${TMPDIR-UNSET}"
