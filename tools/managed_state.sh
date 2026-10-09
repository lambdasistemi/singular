#!/usr/bin/env bash
# shellcheck disable=SC2329 # sourced library: every function is an entry point for its sourcers
# Managed-state path helpers for the CLI journey and recovery controls.
#
# Mirror of Singular.CLI.ManagedState.managedDir: ROOT/net-MAGIC/POLICY-NAME/wallets/KEYHASH.
# The Hspec identityPartition rows pin that layout; if the resolver changes,
# this file changes with it. Callers pass the token and wallet identity the
# receipts already name (requester/folder/walletKeyHash); no key material or
# provider URL enters a path.
#
# Usage: source this file, then managed_journal ROOT TOKEN KEYHASH [MAGIC].
set -u

# managed_default_root [HOME [XDG]]: the CLI-managed default root for an actor:
# XDG_STATE_HOME, or HOME/.local/state, with the singular namespace. Callers
# pass the actor's HOME and an explicitly cleared XDG so an inherited
# XDG_STATE_HOME cannot override the intended HOME unexpectedly.
managed_default_root() {
  local home="${1:-$HOME}" xdg="${2-${XDG_STATE_HOME:-}}"
  if [ -n "$xdg" ]; then
    printf '%s/singular' "$xdg"
  else
    printf '%s/.local/state/singular' "$home"
  fi
}

# managed_partition ROOT TOKEN KEYHASH [MAGIC]: the directory of one identity.
managed_partition() {
  local root="$1" token="$2" kh="$3" magic="${4:-42}"
  printf '%s/net-%s/%s/wallets/%s' "$root" "$magic" "${token/./-}" "$kh"
}

# managed_journal ROOT TOKEN KEYHASH [MAGIC]: that identity's journal file.
managed_journal() {
  printf '%s/journal.jsonl' "$(managed_partition "$@")"
}

# managed_pending ROOT TOKEN KEYHASH [MAGIC]: that identity's pending file.
managed_pending() {
  printf '%s/registry.pending.json' "$(managed_partition "$@")"
}

# managed_lock ROOT TOKEN KEYHASH [MAGIC]: that identity's lock file.
managed_lock() {
  printf '%s/.lock' "$(managed_partition "$@")"
}

# managed_find ROOT NAME: every file called NAME under ROOT, sorted.
managed_find() {
  find "$1" -name "$2" -type f | sort
}

# managed_body ROOT TXID: the saved signed body file, exactly one under ROOT.
# Bodies are content-addressed by transaction id, so discovery is exact.
managed_body() {
  local matches
  mapfile -t matches < <(managed_find "$1" "$2.cbor.hex")
  [ "${#matches[@]}" -eq 1 ] || return 1
  printf '%s\n' "${matches[0]}"
}
# journal_lines_root ROOT: total journal lines over every partition under ROOT.
journal_lines_root() {
  local total=0 f n
  while IFS= read -r f; do
    n=$(wc -l <"$f")
    total=$((total + n))
  done < <(managed_find "$1" journal.jsonl)
  printf '%s\n' "$total"
}

# no_managed_file ROOT NAME: fail unless no file called NAME exists under ROOT.
no_managed_file() {
  local found
  found="$(managed_find "$1" "$2")"
  [ -z "$found" ]
}
