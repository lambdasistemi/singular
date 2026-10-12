#!/usr/bin/env bash
# result-cache: skip hosted tests whose exact inputs were already verified green.
#
# Usage:
#   result-cache run --family F --leg LEG [--backend cachix|--file]
#     [--file-store DIR --file-pins FILE] -- CMD [ARGS...]
#   result-cache lookup --family F --leg LEG [--backend ...] -- CMD [ARGS...]
#   result-cache identity --family F
#
# Families: negative-host-pair, negative-host-mutant. The leg (part or mutant
# name) travels in the pin name, never in the derivation: changing the leg
# alone must not move another leg's identity.
#
# The wrapped command's argv is hashed into the pin name beside the leg: a
# marker published by one command can never satisfy a run of another. There
# is no standalone publish entry point; publishing is reachable only from
# `run`, after the wrapped command exits 0.
#
# run: look up the marker for the current identity and command. Hit: print
# the earlier run URL, job and time (also to $GITHUB_STEP_SUMMARY when set),
# skip the command, exit 0. Miss: run the command; on exit 0 publish the
# marker; a publish refusal or failure is a notice, never a failure of a
# green run; propagate the command's exit code. A command that exits non-zero
# publishes nothing. RESULT_CACHE_FORCE=1 skips lookup, runs the command,
# republishes on green. Any lookup failure is a miss (fail-safe direction).
#
# Publish refuses unless GITHUB_ACTIONS=true, GITHUB_RUN_ID and
# CACHIX_AUTH_TOKEN are set: never from a laptop. Both backends enforce the
# same gate so the controls prove it without touching the real cache.
#
# Backends: --backend cachix (production: `cachix push` then `cachix pin`
# kept 30 days; public pin-list lookup, no token) or --backend file (a
# directory store plus a JSON pin file; only the controls use it).
#
# Read environment (nothing else in RESULT_CACHE_* is read):
#   RESULT_CACHE_FORCE=1  skip lookup, always run, republish on green
#   GITHUB_ACTIONS, GITHUB_RUN_ID, GITHUB_SERVER_URL, GITHUB_REPOSITORY,
#   GITHUB_JOB, GITHUB_SHA, GITHUB_STEP_SUMMARY, CACHIX_AUTH_TOKEN
#
# Run from the repository root: the identity is read from this checkout's
# own flake.
set -euo pipefail

PROG="result-cache"
CACHE="paolino"
PIN_KEEP_DAYS="30"
PIN_API="https://app.cachix.org/api/v1/cache/paolino/pin"
MARKER_VERSION="2"

die() {
  echo "$PROG: FAIL: $*" >&2
  exit 2
}
note() {
  echo "$PROG: $*" >&2
}

family_is_valid() {
  [ "$1" = negative-host-pair ] || [ "$1" = negative-host-mutant ]
}

# Identity: the output path hash of the family's derivation, read with
# nix eval, never built. Prints the 32-char hash. This is the one shared
# reader: the controls call `result-cache identity` instead of copying it.
family_identity() {
  local family="$1" system out outbase
  family_is_valid "$family" || die "unknown family: $family"
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null)" || die "cannot read builtins.currentSystem"
  [ -n "$system" ] || die "empty current system"
  case "$family" in
    negative-host-pair) out="$(nix eval --raw ".#packages.$system.result-cache-identity-pair.outPath")" || return 1 ;;
    negative-host-mutant) out="$(nix eval --raw ".#packages.$system.result-cache-identity-mutant.outPath")" || return 1 ;;
  esac
  [ -n "$out" ] || return 1
  outbase="$(basename "$out")"
  printf '%s' "$outbase" | cut -d- -f1
}

# The wrapped command's argv hashed to 16 hex chars. A marker made by a
# different command carries a different leg component and can never hit.
command_hash() {
  printf '%s\0' "$@" | sha256sum | cut -c1-16
}

pin_name() {
  printf 'verified-%s-%s-%s-%s' "$1" "$2" "$3" "$4"
}

# Marker body on stdout. Args: family leg cmdhash identity command-words...
marker_body() {
  local family="$1" leg="$2" cmdhash="$3" identity="$4"
  shift 4
  local server="${GITHUB_SERVER_URL:-https://github.com}"
  local repo="${GITHUB_REPOSITORY:-unknown/unknown}"
  local run="${GITHUB_RUN_ID:-unknown}"
  local job="${GITHUB_JOB:-unknown}"
  local sha="${GITHUB_SHA:-unknown}"
  local now
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'result-cache-marker-v%s\nfamily: %s\nleg: %s\ncommand-hash: %s\ncommand: %s\nidentity: %s\nrun: %s/%s/actions/runs/%s\njob: %s\ntime: %s\ncommit: %s\n' \
    "$MARKER_VERSION" "$family" "$leg" "$cmdhash" "$*" "$identity" "$server" "$repo" "$run" "$job" "$now" "$sha"
}

# Print the run/job/time lines of a marker body on stdout.
marker_summary() {
  grep -E '^(run|job|time): ' "$1" || true
}

# Strict publish gate. Returns 0 when publishing may proceed, 1 on refusal.
publish_gate() {
  if [ "${GITHUB_ACTIONS:-}" != true ]; then
    note "publish refused: GITHUB_ACTIONS is not true (never from a laptop)"
    return 1
  fi
  if [ -z "${GITHUB_RUN_ID:-}" ]; then
    note "publish refused: GITHUB_RUN_ID is unset"
    return 1
  fi
  if [ -z "${CACHIX_AUTH_TOKEN:-}" ]; then
    note "publish refused: no Cachix token (fork pull request publishes nothing)"
    return 1
  fi
  return 0
}

publish_cachix() {
  local family="$1" leg="$2" cmdhash="$3" identity="$4" marker="$5" pin store_path
  pin="$(pin_name "$family" "$leg" "$cmdhash" "$identity")"
  command -v nix >/dev/null 2>&1 || {
    note "publish refused: no nix on PATH"
    return 1
  }
  command -v cachix >/dev/null 2>&1 || {
    note "publish skipped: no cachix on PATH"
    return 1
  }
  store_path="$(nix store add-file --name "result-marker-$family-$leg-$cmdhash-$identity.txt" "$marker")" || {
    note "publish failed: nix store add-file refused the marker"
    return 1
  }
  [ -n "$store_path" ] || {
    note "publish failed: empty store path"
    return 1
  }
  cachix push "$CACHE" "$store_path" >/dev/null || {
    note "publish failed: cachix push refused $store_path"
    return 1
  }
  cachix pin "$CACHE" "$pin" "$store_path" --keep-days "$PIN_KEEP_DAYS" >/dev/null || {
    note "publish failed: cachix pin refused $pin"
    return 1
  }
  note "published marker $pin -> $store_path"
  return 0
}

publish_file() {
  local family="$1" leg="$2" cmdhash="$3" identity="$4" marker="$5"
  local store_dir="$6" pins_file="$7" pin dest
  pin="$(pin_name "$family" "$leg" "$cmdhash" "$identity")"
  [ -n "$store_dir" ] || {
    note "publish refused: --file-store is unset"
    return 1
  }
  [ -n "$pins_file" ] || {
    note "publish refused: --file-pins is unset"
    return 1
  }
  mkdir -p "$store_dir" || {
    note "publish failed: cannot create $store_dir"
    return 1
  }
  dest="$store_dir/$pin.txt"
  cp "$marker" "$dest" || {
    note "publish failed: cannot write $dest"
    return 1
  }
  if [ -f "$pins_file" ]; then
    jq --arg pin "$pin" --arg file "$dest" '. * {($pin): {"file": $file}}' "$pins_file" >"$pins_file.tmp" || {
      note "publish failed: cannot update $pins_file"
      return 1
    }
    mv "$pins_file.tmp" "$pins_file" || {
      note "publish failed: cannot replace $pins_file"
      return 1
    }
  else
    jq -n --arg pin "$pin" --arg file "$dest" '{($pin): {"file": $file}}' >"$pins_file" || {
      note "publish failed: cannot create $pins_file"
      return 1
    }
  fi
  note "published marker $pin -> $dest (file backend)"
  return 0
}

# Lookup: print the marker body on stdout, return 0 on hit, 1 on miss.
# Any failure is a miss, never an error.
lookup_cachix() {
  local family="$1" leg="$2" cmdhash="$3" identity="$4" pin list entry path content
  pin="$(pin_name "$family" "$leg" "$cmdhash" "$identity")"
  list="$(curl -fsS --max-time 30 "$PIN_API" 2>/dev/null)" || {
    note "lookup miss: pin list unreachable"
    return 1
  }
  printf '%s' "$list" | jq -e 'type == "array"' >/dev/null 2>&1 || {
    note "lookup miss: unexpected pin shape (not an array)"
    return 1
  }
  # Shape-agnostic: the entry holding this exact pin name. Field names are
  # unconfirmed (the list is empty today); anything unexpected is a miss.
  # The first hosted publish confirms them and records them in the PR body.
  entry="$(printf '%s' "$list" | jq -c --arg pin "$pin" '[.[] | select(.. | strings == $pin)][0] // empty' 2>/dev/null)" || {
    note "lookup miss: pin list unreadable"
    return 1
  }
  [ -n "$entry" ] && [ "$entry" != null ] || {
    note "lookup miss: no pin $pin"
    return 1
  }
  path="$(printf '%s' "$entry" | jq -r '[.. | strings | select(test("^/nix/store/[a-z0-9]+-.+"))][0] // empty' 2>/dev/null)" || {
    note "lookup miss: pin entry carries no store path"
    return 1
  }
  [ -n "$path" ] || {
    note "lookup miss: pin entry carries no store path"
    return 1
  }
  note "lookup hit candidate: $pin -> $path"
  printf '%s' "$entry" | head -c 2000 >&2 || true
  echo "" >&2
  nix-store --realise "$path" >/dev/null 2>&1 || {
    note "lookup miss: unfetchable marker content at $path"
    return 1
  }
  content="$(cat "$path" 2>/dev/null)" || {
    note "lookup miss: unfetchable marker content at $path"
    return 1
  }
  printf '%s' "$content" | grep -qF "identity: $identity" || {
    note "lookup miss: marker content does not name $identity"
    return 1
  }
  printf '%s\n' "$content"
  return 0
}

lookup_file() {
  local family="$1" leg="$2" cmdhash="$3" identity="$4" store_dir="$5" pins_file="$6" pin dest content
  pin="$(pin_name "$family" "$leg" "$cmdhash" "$identity")"
  [ -n "$store_dir" ] || {
    note "lookup miss: --file-store is unset"
    return 1
  }
  [ -n "$pins_file" ] || {
    note "lookup miss: --file-pins is unset"
    return 1
  }
  [ -f "$pins_file" ] || {
    note "lookup miss: no pin file at $pins_file"
    return 1
  }
  dest="$(jq -r --arg pin "$pin" '.[$pin].file // empty' "$pins_file" 2>/dev/null)" || {
    note "lookup miss: malformed pin file at $pins_file"
    return 1
  }
  [ -n "$dest" ] || {
    note "lookup miss: no pin $pin"
    return 1
  }
  [ -f "$dest" ] || {
    note "lookup miss: unfetchable marker content at $dest"
    return 1
  }
  content="$(cat "$dest")" || {
    note "lookup miss: unfetchable marker content at $dest"
    return 1
  }
  printf '%s' "$content" | grep -qF "identity: $identity" || {
    note "lookup miss: marker content does not name $identity"
    return 1
  }
  printf '%s\n' "$content"
  return 0
}

print_hit() {
  local marker_file="$1"
  echo "$PROG: HIT: earlier verified run of the identical inputs:"
  marker_summary "$marker_file"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      echo "result-cache HIT: earlier verified run of the identical inputs"
      marker_summary "$marker_file"
    } >>"$GITHUB_STEP_SUMMARY" || true
  fi
}

# Publish from run only, after the wrapped command exits 0. Refusal and
# failure return non-zero; run downgrades them to a notice.
do_publish() {
  local family="$1" leg="$2" cmdhash="$3" identity="$4" backend="$5" store_dir="$6" pins_file="$7" marker status=0
  shift 7
  publish_gate || return 1
  marker="$(mktemp)" || return 1
  marker_body "$family" "$leg" "$cmdhash" "$identity" "$@" >"$marker"
  case "$backend" in
    cachix) publish_cachix "$family" "$leg" "$cmdhash" "$identity" "$marker" || status=1 ;;
    file) publish_file "$family" "$leg" "$cmdhash" "$identity" "$marker" "$store_dir" "$pins_file" || status=1 ;;
    *) die "unknown backend: $backend" ;;
  esac
  rm -f "$marker"
  return "$status"
}

cmd_run() {
  local family="" leg="" backend="cachix" store_dir="" pins_file="" identity="" cmdhash="" marker status=0 hit=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --family)
        family="$2"
        shift 2
        ;;
      --leg)
        leg="$2"
        shift 2
        ;;
      --backend)
        backend="$2"
        shift 2
        ;;
      --file-store)
        store_dir="$2"
        shift 2
        ;;
      --file-pins)
        pins_file="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *) die "run: unexpected argument: $1" ;;
    esac
  done
  [ -n "$family" ] || die "run: --family is required"
  family_is_valid "$family" || die "run: unknown family: $family"
  [ -n "$leg" ] || die "run: --leg is required"
  [ "$#" -ge 1 ] || die "run: no command after --"
  cmdhash="$(command_hash "$@")"
  [ -n "$cmdhash" ] || die "run: command hash unreadable"
  if ! identity="$(family_identity "$family")"; then
    note "identity unreadable; running the command without lookup or publish"
    identity=""
  fi
  if [ -n "$identity" ] && [ "${RESULT_CACHE_FORCE:-}" != 1 ]; then
    marker="$(mktemp)" || die "cannot create a marker scratch file"
    hit=0
    case "$backend" in
      cachix)
        lookup_cachix "$family" "$leg" "$cmdhash" "$identity" >"$marker" 2>"$marker.err" && hit=1 || hit=0
        ;;
      file)
        lookup_file "$family" "$leg" "$cmdhash" "$identity" "$store_dir" "$pins_file" >"$marker" 2>"$marker.err" && hit=1 || hit=0
        ;;
      *)
        die "run: unknown backend: $backend"
        ;;
    esac
    if [ "$hit" = 1 ]; then
      cat "$marker.err" >&2 || true
      print_hit "$marker"
      rm -f "$marker" "$marker.err"
      return 0
    fi
    cat "$marker.err" >&2 || true
    rm -f "$marker" "$marker.err"
  elif [ "${RESULT_CACHE_FORCE:-}" = 1 ]; then
    note "RESULT_CACHE_FORCE=1: lookup skipped, running the command"
  fi
  set +e
  "$@"
  status=$?
  set -e
  if [ "$status" -eq 0 ] && [ -n "$identity" ]; then
    do_publish "$family" "$leg" "$cmdhash" "$identity" "$backend" "$store_dir" "$pins_file" "$@" \
      || note "publish skipped with a notice, never a failure"
  elif [ "$status" -ne 0 ]; then
    note "command exited $status: publishing nothing"
  fi
  return "$status"
}

cmd_lookup() {
  local family="" leg="" backend="cachix" store_dir="" pins_file="" identity="" cmdhash=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --family)
        family="$2"
        shift 2
        ;;
      --leg)
        leg="$2"
        shift 2
        ;;
      --backend)
        backend="$2"
        shift 2
        ;;
      --file-store)
        store_dir="$2"
        shift 2
        ;;
      --file-pins)
        pins_file="$2"
        shift 2
        ;;
      --)
        shift
        break
        ;;
      *) die "lookup: unexpected argument: $1" ;;
    esac
  done
  [ -n "$family" ] || die "lookup: --family is required"
  family_is_valid "$family" || die "lookup: unknown family: $family"
  [ -n "$leg" ] || die "lookup: --leg is required"
  [ "$#" -ge 1 ] || die "lookup: no command after --"
  cmdhash="$(command_hash "$@")"
  [ -n "$cmdhash" ] || die "lookup: command hash unreadable"
  identity="$(family_identity "$family")" || die "lookup: identity unreadable"
  case "$backend" in
    cachix) lookup_cachix "$family" "$leg" "$cmdhash" "$identity" ;;
    file) lookup_file "$family" "$leg" "$cmdhash" "$identity" "$store_dir" "$pins_file" ;;
    *) die "lookup: unknown backend: $backend" ;;
  esac
}

cmd_identity() {
  local family=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --family)
        family="$2"
        shift 2
        ;;
      *) die "identity: unexpected argument: $1" ;;
    esac
  done
  [ -n "$family" ] || die "identity: --family is required"
  family_identity "$family" || die "identity: unreadable"
  echo ""
}

sub="${1:-}"
[ -n "$sub" ] || die "usage: $PROG {run|lookup|identity} ..."
shift
case "$sub" in
  run) cmd_run "$@" ;;
  lookup) cmd_lookup "$@" ;;
  identity) cmd_identity "$@" ;;
  *) die "unknown subcommand: $sub" ;;
esac
