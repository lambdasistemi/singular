#!/usr/bin/env bash
# SUPPLEMENT S3 to the frozen gate-77-v3 — #77 plus the ownerless repair.
#
# S2 v1 and v2 are retained beside this as REJECTED. Both took a caller-supplied
# receipt as authority for behavioural success: v1 read its fields, v2
# format-checked them. Root passed v2 with invented 64-hex ids, policy aaaa…,
# an asset name contradicting the mint, five refusals sharing one fake txid, and
# a control whose distinctFrom named a row that does not exist. Format checking
# demonstrated format checking and nothing else.
#
# S3 changes the MECHANISM, not the fields:
#
#   * THE GATE EXECUTES. It runs the frozen runner itself, in a controlled fresh
#     devnet session it owns, and the evidence is what that execution produced.
#     There is no caller-supplied receipt argument. A retained JSON is a report.
#   * THE VERIFIER RECOMPUTES. Cryptographic and ledger facts — txid from the
#     serialized body, the applied policy id from the program plus its bound
#     parameters, roots decoded from observed state datums — are established by
#     an in-repo verifier built from the candidate, not by bash and not by jq.
#     This script orchestrates and adjudicates; it does not pretend to decode.
#   * FAIL CLOSED, ALWAYS. Dirty tree, identity mismatch, missing verifier,
#     non-executing runner, unreachable assertion: failure, never a skip.
#
# v1 of THIS file is retained as supplement-77-S3-v1-REJECTED.sh. Root found two
# defects in it. It recorded the verifier's exit and never failed on it, so a
# verifier crashing with exit 17 beside a stale verdicts.json from an earlier run
# produced S3 SUPPLEMENT GREEN. And it did `rm -rf` on a caller-overridable path,
# which is a destructive bug in acceptance tooling. Both are closed below:
# every subprocess exit is required, every artifact must be created BY THIS
# INVOCATION in a directory this invocation allocates, and nothing pre-existing
# is ever deleted.
#
# Usage: supplement-77-S3.sh <worktree> <candidate-sha> <evidence-dir>
set -uo pipefail

W="${1:-}"; WANT="${2:-}"; EV="${3:-}"
if [ -z "$W" ] || [ -z "$WANT" ] || [ -z "$EV" ]; then
  echo "S3 FAIL-CLOSED: usage: supplement-77-S3.sh <worktree> <candidate-sha> <evidence-dir>"; exit 2
fi
# A unique child per invocation. Evidence is never reused, never overwritten and
# never deleted — a file left by an earlier success must not be able to speak for
# this run. mkdir without -p on the child so a collision is an error, not a reuse.
mkdir -p "$EV" || { echo "S3 FAIL-CLOSED: cannot create $EV"; exit 2; }
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$"
EV="$EV/run-$RUN_ID"
mkdir "$EV" || { echo "S3 FAIL-CLOSED: cannot allocate a fresh evidence directory at $EV"; exit 2; }
echo "S3 evidence (this invocation only): $EV"

fails=0
ok()  { printf 'S3 %-28s PASS  %s\n' "$1" "${2:-}"; }
bad() { printf 'S3 %-28s FAIL  %s\n' "$1" "${2:-}"; fails=$((fails+1)); }

# ------------------------------------------------------- 1. freeze identity
[ -e "$W/.git" ] || { bad candidate-bound "no git worktree at $W"; echo; echo "S3 RED (fail-closed)"; exit 1; }
have=$(git -C "$W" rev-parse HEAD 2>/dev/null)
[ "$have" = "$WANT" ] || bad candidate-bound "worktree at '$have', expected '$WANT'"
dirty=$(git -C "$W" status --porcelain 2>/dev/null | wc -l)
[ "$dirty" -eq 0 ] || bad tree-clean "worktree has $dirty uncommitted change(s) — evidence would not bind to $WANT"
[ "$have" = "$WANT" ] && [ "$dirty" -eq 0 ] && ok candidate-bound "$WANT, clean"
if [ "$fails" -ne 0 ]; then echo; echo "S3 RED — refusing to execute against an unbound tree"; exit 1; fi

# ------------------------------------------------------- 2. build, and pin what we built
naming_bp=$(cd "$W" && nix build --quiet --no-link --print-out-paths ./naming-onchain#plutus-blueprint 2>"$EV/blueprint.err")
mpfs_bp=$(cd "$W" && nix build --quiet --no-link --print-out-paths ./onchain#plutus-blueprint 2>>"$EV/blueprint.err")
if [ -z "$naming_bp" ] || [ -z "$mpfs_bp" ]; then
  bad blueprints-build "naming='$naming_bp' mpfs='$mpfs_bp' (see $EV/blueprint.err)"
  echo; echo "S3 RED (fail-closed)"; exit 1
fi
ok blueprints-build "naming=$(basename "$naming_bp") mpfs=$(basename "$mpfs_bp")"

# The verifier is built FROM THE CANDIDATE. Its absence is a failure, not a skip:
# without it nothing below can be established, and bash must not substitute.
verifier=$(cd "$W/offchain" && nix build --quiet --no-link --print-out-paths .#connected-verifier 2>"$EV/verifier.err")
if [ -z "$verifier" ]; then
  bad verifier-available "offchain#connected-verifier did not build — S3 cannot establish ledger facts without it (see $EV/verifier.err)"
  echo; echo "S3 RED (fail-closed): the verifier is the only thing entitled to recompute"; exit 1
fi
ok verifier-available "$(basename "$verifier")"

# ------------------------------------------------------- 3. EXECUTE the runner
# A controlled, fresh, private devnet session this script owns. Shallow path:
# the node socket must stay inside the AF_UNIX limit.
# Freshly allocated and owned by this invocation. S3_TMPDIR may choose the BASE
# to allocate under, never a path to delete: nothing pre-existing is removed.
# Short, because the node socket must stay inside the AF_UNIX limit.
S3_BASE="${S3_TMPDIR:-/tmp}"
[ -d "$S3_BASE" ] || { bad devnet-session "base '$S3_BASE' is not a directory"; echo; echo "S3 RED (fail-closed)"; exit 1; }
RUN_TMP="$(mktemp -d "$S3_BASE/s3XXXXXX")" || { bad devnet-session "could not allocate a private devnet directory"; echo; echo "S3 RED (fail-closed)"; exit 1; }
ok devnet-session "allocated $RUN_TMP for this invocation"
( cd "$W/offchain" && TMPDIR="$RUN_TMP" NAMING_BLUEPRINT="$naming_bp" MPFS_BLUEPRINT="$mpfs_bp" \
    S3_EVIDENCE="$EV/run" nix run --quiet .#register-rows ) > "$EV/run.stdout" 2>"$EV/run.stderr"
run_rc=$?
echo "runner exit=$run_rc  stdout=$EV/run.stdout"
if [ "$run_rc" -ne 0 ]; then
  bad runner-executed "runner exited $run_rc — see $EV/run.stderr"
  echo; echo "S3 RED (fail-closed): nothing downstream can speak for a run that failed"; exit 1
fi
[ -d "$EV/run" ] || { bad runner-evidence "the runner produced no evidence directory at $EV/run"; echo; echo "S3 RED (fail-closed)"; exit 1; }
ok runner-executed "exit 0, evidence under $EV/run"

# ------------------------------------------------------- 4. VERIFY what it did
# The verifier reads the raw artifacts the run produced — serialized submitted
# bodies, observed UTxOs and datums, the built blueprint — and recomputes. It
# emits one verdict line per obligation. This script adjudicates those verdicts
# and never re-derives a fact itself.
#
# Obligations the verifier must report on, by name:
#   connected.state-input        the fold consumed the state UTxO it names
#   connected.request-input      the fold consumed the request UTxO it names
#   connected.continuation       the continuing output of THIS tx carries the new StateDatum
#   connected.root-before        rootBefore decoded from the CONSUMED state UTxO's datum
#   connected.root-after         rootAfter decoded from the continuing output of THIS tx
#   connected.txid               txid recomputed from the serialized submitted body
#   representative.applied       policy id recomputed by APPLYING bound parameters to the program
#   representative.asset         expected asset-name bytes and net quantity under that exact policy
#   representative.approval      the insert approval was consumed
#   representative.key           the connected state's key and incarnation match the asset
#   refusal.<op>                 submitted body reached the intended compiled script for <op>
#                                with the specific failure reason, not a client/setup/input failure
#   control.<name>               accepted on chain, with relevant inputs differing from its subject
"$verifier" --evidence "$EV/run" --blueprint "$naming_bp" --mpfs-blueprint "$mpfs_bp" \
            --candidate "$WANT" --out "$EV/verdicts.json" > "$EV/verifier.stdout" 2>"$EV/verifier.stderr"
vrc=$?
# A crashed verifier cannot be overridden by a file. The evidence directory is
# unique to this invocation, so verdicts.json cannot pre-exist; and a nonzero
# verifier exit fails outright regardless of what it managed to write.
if [ "$vrc" -ne 0 ]; then
  bad verifier-exit "verifier exited $vrc — a nonzero verifier cannot establish anything (see $EV/verifier.stderr)"
  echo; echo "S3 RED (fail-closed)"; exit 1
fi
if [ ! -s "$EV/verdicts.json" ]; then
  bad verifier-produced-verdicts "verifier exited 0 but wrote no verdicts at $EV/verdicts.json"
  echo; echo "S3 RED (fail-closed)"; exit 1
fi
if ! jq -e 'type=="object" and length>0' "$EV/verdicts.json" >/dev/null 2>&1; then
  bad verdicts-wellformed "verdicts.json is not a non-empty object"
  echo; echo "S3 RED (fail-closed)"; exit 1
fi
dupes=$(jq -r 'keys_unsorted | group_by(.) | map(select(length>1)) | length' "$EV/verdicts.json" 2>/dev/null)
[ "${dupes:-0}" -eq 0 ] || bad verdicts-unique "verdicts.json contains duplicate obligation identities"
ok verifier-exit "exit 0, verdicts created by this invocation"

verdict() { jq -r --arg k "$1" '.[$k].status // "MISSING"' "$EV/verdicts.json" 2>/dev/null; }
detail() { jq -r --arg k "$1" '.[$k].detail // ""'        "$EV/verdicts.json" 2>/dev/null; }
require() {
  local key="$1" st; st=$(verdict "$key")
  case "$st" in
    ESTABLISHED) ok "$key" "$(detail "$key")" ;;
    REFUTED)     bad "$key" "REFUTED: $(detail "$key")" ;;
    MISSING)     bad "$key" "no verdict — an unreachable assertion blocks acceptance" ;;
    *)           bad "$key" "$st: $(detail "$key") — COULD-NOT-EVALUATE blocks acceptance" ;;
  esac
}

for k in connected.state-input connected.request-input connected.continuation \
         connected.root-before connected.root-after connected.txid \
         representative.applied representative.asset representative.approval representative.key; do
  require "$k"
done
for op in insert end migration sweep burning; do require "refusal.$op"; done
for c in free-key supported-action;               do require "control.$c"; done

# ------------------------------------------------------- 5. ownerless, behaviourally
# A schema grep and a green identity build cannot establish the absence of
# owner-authorized BEHAVIOUR. The refusal verdicts above are what establish it.
# The schema check stays only as a cheap corroboration, never as the evidence.
if grep -qE '^\s*(owner|stake_script)\s*:' "$W/onchain/validators/types.ak" 2>/dev/null; then
  bad no-authority-field "State still declares an owner/stake authority field"
else
  ok no-authority-field "corroboration only — refusal.{end,migration,sweep,burning} above are the evidence"
fi

# Clean up only the devnet session this invocation allocated. Evidence is never
# removed to satisfy cleanup.
[ -n "${RUN_TMP:-}" ] && [ -d "$RUN_TMP" ] && rm -rf "$RUN_TMP"

printf '\n'
printf 'S3 evidence retained at %s\n' "$EV"
if [ "$fails" -eq 0 ]; then printf 'S3 SUPPLEMENT GREEN (candidate %s, executed)\n' "$WANT"; exit 0; fi
printf 'S3 SUPPLEMENT RED — %d obligation(s) failed\n' "$fails"; exit 1
