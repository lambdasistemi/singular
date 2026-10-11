#!/usr/bin/env bash
# negative-host-mutants (row 3b): each mutant validator runs its pairs
# against the archive's own build of the mutated source.
#
# A mutant is a source-only patch in the host's own tree that removes exactly
# one refusing rule, or one named set of rules, from the Aiken source. For one mutant the command builds
# a scratch git copy of the checkout, applies the patch there, regenerates
# the identity manifest with the repo's own recipe (A-001: `just
# script-identity-regen` in onchain, scratch copy only, never typed, never
# edited by hand; the checkout is never touched), commits the scratch copy
# (a flake and the release assembler need tracked files), and runs the
# UNMODIFIED part command (`nix run .#negative-host-part -- PART`) from that
# copy for each pair the rule refuses plus the mutant's declared control
# pair. The part assembles its release archive from the scratch copy, so the
# archive's own build produces the mutated blueprint with no change to the
# part script. Scratch copies exist only for the minutes of a run: they are
# removed at the end of every run, including failed runs.
#
# A flip pair counts as flipped only when its forbidden check failed because
# the node ACCEPTED what the rule refuses, read from `forbidden.json` in the
# part's kept scratch (NEGATIVE_KEEP_SCRATCH=1): the part's exit code alone
# is not enough (exit 1 also means other judge failures, exit 3 means
# setup). The control pair must pass (part exit 0). A setup failure, a
# missing receipt, a failure of another kind, or a flip pair that still
# passes is never a flip and fails the command.
#
# usage: negative_host_mutants.sh REPO-ROOT [--list | --control-noop | MUTANT]
#   --list          print {"mutant": [...]} from the host's own table of
#                   mutants; starts nothing; fails on an empty list
#   --control-noop  self-check: an empty patch over every flip and side-flip pair (the
#                   node still refuses, so nothing flips) plus the
#                   classification controls on altered results, all driving
#                   the same classify_mutant_run the live run calls
#   MUTANT          run one mutant: every flip and side-flip pair must flip, the declared
#                   control pair must pass
#   (no argument)   run every mutant
set -euo pipefail
[ "$#" -ge 1 ] || {
  echo "usage: $0 REPO-ROOT [--list | --control-noop | MUTANT]" >&2
  exit 2
}
root="$1"
shift
root="$(realpath -m "$root")"
mutants_dir="$root/applications/open-datum/negative/mutants"
rules="$mutants_dir/rules.json"

mode=all
mutant=""
case "$#" in
  0) mode=all ;;
  1)
    case "$1" in
      --list) mode=list ;;
      --control-noop) mode=noop ;;
      --)
        echo "usage: $0 REPO-ROOT [--list | --control-noop | MUTANT]" >&2
        exit 2
        ;;
      *)
        mode=one
        mutant="$1"
        ;;
    esac
    ;;
  2)
    if [ "$1" = "--" ]; then
      mode=one
      mutant="$2"
    else
      echo "usage: $0 REPO-ROOT [--list | --control-noop | MUTANT]" >&2
      exit 2
    fi
    ;;
  *)
    echo "usage: $0 REPO-ROOT [--list | --control-noop | MUTANT]" >&2
    exit 2
    ;;
esac

[ -f "$rules" ] || {
  echo "negative-host-mutants: FAIL: no rules table at $rules" >&2
  exit 2
}

fail() {
  echo "negative-host-mutants: FAIL: $*" >&2
  exit 1
}

# The classification of one mutated run (A-002). Inputs: the regeneration
# status (ok | skipped-empty | failed | unchanged), the control pair's part
# exit (0 | nonzero | skipped when no control ran), the flip pair's part
# exit, the path of its forbidden.json (may be absent), and the receipt
# command the flip pair's forbidden invocation prints (e.g. "withdraw").
# Prints exactly one of FLIPPED | NOT-FLIPPED-REFUSED | OTHER-FAILURE |
# MISSING | SETUP | CONTROL-FAILED | BAD-STATUS and returns 0 only for
# FLIPPED: the part's exit is 1 or 3 AND the kept receipt exists, parses, is
# the host's receipt for the expected command, and reports success. Nothing
# else is a flip: exit 0/2/127 (whatever the receipt says), a non-success
# receipt, a missing or malformed receipt, a foreign command.
#
# Collateral collapse (A-002): for a mutant whose accepted forbidden move
# consumes state (here the released holding), the part's own same-registry
# control stage may fail afterwards with the holding gone; the part then
# exits 3 AFTER the node accepted. That failure is expected and is evidence
# of acceptance, not an infrastructure failure, hence exit 3 with a success
# receipt flips while exit 3 without one stays SETUP. Do not touch the part
# script (outside this brief's fence).
# The live run calls it on real results; every control below calls it on
# altered results. Each control input fails exactly one guard, so deleting
# that guard's check makes its control classify as FLIPPED.
classify_mutant_run() {
  local regen="$1" control_exit="$2" part_exit="$3" receipt="$4" expect_command="$5"
  local outcome="" command=""
  [ "$regen" = ok ] || [ "$regen" = skipped-empty ] || {
    echo "SETUP"
    return 1
  } # GUARD-regen
  [ "$control_exit" = 0 ] || [ "$control_exit" = skipped ] || {
    echo "CONTROL-FAILED"
    return 1
  } # GUARD-control
  # GUARD-receipt below: the receipt must exist, parse, name the expected
  # command (do not accept any file), and report success. Presence rides
  # here: no receipt means no success, never a flip.
  outcome="$(jq -er .outcome "$receipt" 2>/dev/null)" || outcome="unreadable"
  command="$(jq -er .command "$receipt" 2>/dev/null)" || command="unreadable"
  [ "$outcome" = success ] && [ "$command" = "$expect_command" ] || { # GUARD-receipt
    [ "$part_exit" = 3 ] && {
      echo "SETUP"
      return 1
    }
    [ -f "$receipt" ] || {
      echo "MISSING"
      return 1
    }
    [ "$outcome" = ledger-refusal ] && {
      echo "NOT-FLIPPED-REFUSED"
      return 1
    }
    echo "OTHER-FAILURE"
    return 1
  }
  [ "$part_exit" = 1 ] || [ "$part_exit" = 3 ] || {
    echo "BAD-STATUS"
    return 1
  } # GUARD-status
  echo "FLIPPED"
  return 0
}

# The regeneration step may change only the identity manifest (F314-1):
# after the source patch is committed, exactly onchain/script-identity.json
# is modified, it did change, and the move stays within the open_datum pins
# (same schema, compiler and upstream, same validator count and titles,
# every changed validator an open_datum one). Anything else is a setup
# failure, never a flip. The live run calls it on the real scratch state;
# the self-check drives it on fabricated states. Each fabricated state fails
# exactly one guard, so deleting that guard's check makes it pass.
regen_manifest_ok() {
  local copy="$1" base="$2"
  local manifest="$copy/onchain/script-identity.json"
  local modified=""
  git -C "$copy" show HEAD:onchain/script-identity.json >"$base" || return 1 # GUARD-rbase
  git -C "$copy" diff --quiet -- onchain/script-identity.json && return 1    # GUARD-rchanged
  modified="$(git -C "$copy" status --porcelain | awk '{print $2}')" || return 1
  [ -z "$modified" ] || [ "$modified" = "onchain/script-identity.json" ] || return 1 # GUARD-rfiles
  jq --slurpfile b "$base" --slurpfile n "$manifest" -n -e ' # GUARD-rscope
    ($b[0]) as $bb | ($n[0]) as $nn
    | ($bb.schema == $nn.schema and $bb.compiler == $nn.compiler and $bb.upstream == $nn.upstream)
    and (($bb.validators | length) == ($nn.validators | length))
    and (([$bb.validators[].title] | sort) == ([$nn.validators[].title] | sort))
    and ([range(0; ($bb.validators | length)) | select($bb.validators[.] != $nn.validators[.]) | $bb.validators[.].title | startswith("open_datum.")] | all)
  ' >/dev/null || return 1
}

# The patch-hygiene step (derivation: every mutant changes only its named
# rule or rule set): before a mutant runs, its patch must touch exactly the one file
# named in rules.json, name each of its rules' trace labels among the removed lines,
# and remove nothing outside those rules' branches (per rule: the label line and the
# condition line above it). Anything else is a setup failure, never a flip.
# The live run calls it before any scratch copy; the self-check drives it
# on good and fabricated patches. Each fabricated patch fails exactly one
# guard, so deleting that guard's check makes it pass. Labels that occur once
# (the four single-rule mutants, update-escape/update-control, release-additive)
# take the unanchored path, byte-identical to before. Labels that occur twice
# (app-owner and app-controller-signature, in bookInsert and bookTerminate) take
# the anchored path: the entry names one anchor string occurring exactly once in
# the source, the function derives the scope from the anchor line to the next
# top-level fn/const line (never typed), builds the allowed branch lines as the
# union over all occurrences so the old line check passes at either site, and one
# occurrence guard binds the hunk to the actual source: header numbers alone are
# not trusted, because a later git apply can relocate a hunk by its context. For
# every hunk the guard computes its PREIMAGE (context and removed lines in order,
# without the added lines) and requires it to equal the source lines exactly at
# the claimed position and NOWHERE else, then applies the whole patch to a scratch
# copy of the source and requires the ACTUAL changed lines to lie inside the
# anchored scope. Text alone cannot tell the two controller-signature sites apart
# (identical condition and label); the bound preimage plus the applied result are
# the discriminator. All of this is ONE guard with ONE decision line, so deleting
# that line disables the whole occurrence check (the deletion matrix proves it).
# The second argument is a comma-separated rule list: single-rule callers pass one
# name (behaviour unchanged); set-valued callers pass "a,b". The fifth argument is
# the optional anchor (empty keeps the old behaviour). Still one function.
patch_hygiene_ok() {
  local patch="$1" rules_csv="$2" expected="$3" source="$4" anchor="${5:-}"
  local touched="" count="" at="" line="" stripped="" b1="" b2="" s1="" s2=""
  local rule="" allowed_list="" occ_all=""
  local scope_start="" scope_end="" hunk="" hstart="" hcount="" total=""
  local hverdict="" htmp="" hheaders="" hline="" hbody_end="" pre_n="" matches=""
  local actual="" ahunk="" astart="" acount="" next_h="" last_line=""
  [ -f "$patch" ] || return 1
  [ -f "$source" ] || return 1
  [ -n "$rules_csv" ] || return 1
  count="$(grep -c '^diff --git ' "$patch" || true)" # GUARD-hfiles
  [ "$count" = 1 ] || return 1
  touched="$(grep '^diff --git ' "$patch" | awk '{print $4}' | sed 's|^b/||')" || return 1
  [ "$touched" = "$expected" ] || return 1
  if [ -n "$anchor" ]; then
    count="$(grep -c -F -- "$anchor" "$source" || true)"
    [ "$count" = 1 ] || return 1
    scope_start="$(grep -n -F -- "$anchor" "$source" | cut -d: -f1)" || return 1
    scope_end="$(awk -v a="$scope_start" 'NR>a && (/^fn / || /^const /) {print NR; exit}' "$source")" || return 1
    if [ -z "$scope_end" ]; then
      total="$(wc -l <"$source")" || return 1
      scope_end=$((total + 1)) || return 1
    fi
  fi
  allowed_list=""
  IFS=',' read -ra HYGIENE_RULES <<<"$rules_csv" || return 1
  [ "${#HYGIENE_RULES[@]}" -ge 1 ] || return 1
  for rule in "${HYGIENE_RULES[@]}"; do
    [ -n "$rule" ] || return 1
    if [ -n "$anchor" ]; then
      occ_all="$(grep -n -F "@\"$rule\"" "$source" | cut -d: -f1 || true)"
      [ -n "$occ_all" ] || return 1
      while IFS= read -r at; do
        [ -n "$at" ] || continue
        [ "$at" -ge 2 ] || return 1
        b1="$(sed -n "$((at - 1))p" "$source")" || return 1
        b2="$(sed -n "${at}p" "$source")" || return 1
        s1="$(printf '%s' "$b1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || return 1
        s2="$(printf '%s' "$b2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || return 1
        allowed_list+="${s1}"$'\n'"${s2}"$'\n'
      done <<<"$occ_all"
      grep '^-[^-]' "$patch" | grep -q -F "$rule" || return 1 # GUARD-hlabel
    else
      count="$(grep -c -F "@\"$rule\"" "$source" || true)"
      [ "$count" = 1 ] || return 1
      at="$(grep -n -F "@\"$rule\"" "$source" | cut -d: -f1)" || return 1
      [ "$at" -ge 2 ] || return 1
      grep '^-[^-]' "$patch" | grep -q -F "$rule" || return 1 # GUARD-hlabel
      b1="$(sed -n "$((at - 1))p" "$source")" || return 1
      b2="$(sed -n "${at}p" "$source")" || return 1
      s1="$(printf '%s' "$b1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || return 1
      s2="$(printf '%s' "$b2" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || return 1
      allowed_list+="${s1}"$'\n'"${s2}"$'\n'
    fi
  done
  while IFS= read -r line; do # GUARD-hlines
    stripped="$(printf '%s' "${line#-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')" || return 1
    printf '%s' "$allowed_list" | grep -qxF -- "$stripped" || return 1
  done < <(grep '^-[^-]' "$patch" || true)
  if [ -n "$anchor" ]; then
    hverdict=0
    htmp="$(mktemp -d)" || hverdict=1
    if [ "$hverdict" = 0 ]; then
      mkdir -p "$htmp/apply/onchain/validators" || hverdict=1
      cp "$source" "$htmp/apply/onchain/validators/open_datum.ak" || hverdict=1
    fi
    hheaders="$(grep -n '^@@ ' "$patch" | cut -d: -f1 || true)"
    [ -n "$hheaders" ] || hverdict=1
    last_line="$(wc -l <"$patch")" || hverdict=1
    for hline in $hheaders; do
      hunk="$(sed -n "${hline}p" "$patch")" || hverdict=1
      hstart="$(printf '%s' "$hunk" | sed -n 's/^@@ -\([0-9][0-9]*\)\(,\([0-9][0-9]*\)\)\?.*/\1/p')" || hverdict=1
      hcount="$(printf '%s' "$hunk" | sed -n 's/^@@ -[0-9][0-9]*,\([0-9][0-9]*\).*/\1/p')" || hverdict=1
      [ -n "$hstart" ] || hverdict=1
      [ -n "$hcount" ] || hcount=1
      [ "$hcount" -ge 1 ] || hverdict=1
      if [ "$hverdict" = 0 ]; then
        { [ "$hstart" -ge "$scope_start" ] && [ $((hstart + hcount)) -le "$scope_end" ]; } || hverdict=1
      fi
      next_h="$(printf '%s' "$hheaders" | awk -v cur="$hline" '$1 > cur {print $1; exit}')" || hverdict=1
      if [ -n "$next_h" ]; then
        hbody_end=$((next_h - 1)) || hverdict=1
      else
        hbody_end="$last_line" || hverdict=1
      fi
      if [ "$hverdict" = 0 ]; then
        sed -n "$((hline + 1)),${hbody_end}p" "$patch" | sed -n 's/^[ -]//p' >"$htmp/pre-$hline" || hverdict=1
        pre_n="$(wc -l <"$htmp/pre-$hline")" || hverdict=1
        [ "$pre_n" -eq "$hcount" ] || hverdict=1
      fi
      if [ "$hverdict" = 0 ]; then
        sed -n "${hstart},$((hstart + hcount - 1))p" "$source" | diff - "$htmp/pre-$hline" >/dev/null 2>&1 || hverdict=1
      fi
      if [ "$hverdict" = 0 ]; then
        matches="$(awk -v pre="$htmp/pre-$hline" 'BEGIN { n=0; while ((getline L < pre) > 0) { n++; P[n]=L } } { nr++; B[nr % n]=$0 } nr >= n { ok=1; for (i=1;i<=n;i++) { if (B[(nr-n+i) % n] != P[i]) { ok=0; break } } ; if (ok) c++ } END { print c+0 }' "$source")" || hverdict=1
        [ "$matches" = 1 ] || hverdict=1
      fi
    done
    if [ "$hverdict" = 0 ]; then
      (cd "$htmp/apply" && git apply "$patch" >/dev/null 2>&1) || hverdict=1
    fi
    if [ "$hverdict" = 0 ]; then
      actual="$(git diff --no-index -U0 "$source" "$htmp/apply/onchain/validators/open_datum.ak" 2>/dev/null | grep '^@@ ' || true)"
      [ -n "$actual" ] || hverdict=1
      while IFS= read -r ahunk; do
        [ -n "$ahunk" ] || continue
        astart="$(printf '%s' "$ahunk" | sed -n 's/^@@ -\([0-9][0-9]*\)\(,\([0-9][0-9]*\)\)\?.*/\1/p')" || hverdict=1
        acount="$(printf '%s' "$ahunk" | sed -n 's/^@@ -[0-9][0-9]*,\([0-9][0-9]*\).*/\1/p')" || hverdict=1
        [ -n "$astart" ] || hverdict=1
        [ -n "$acount" ] || acount=1
        { [ "$astart" -ge "$scope_start" ] && [ $((astart + acount)) -le "$scope_end" ]; } || hverdict=1
      done <<<"$actual"
    fi
    rm -rf "$htmp" || true
    [ "$hverdict" = 0 ] || return 1 # GUARD-hanchor
  fi
}
# the patch and the rules are read from the checkout itself) and commit it,
# so the flakes and the release assembler see tracked files.
make_scratch_copy() {
  local src="$1" parent="$2"
  local copy="$parent/repo"
  mkdir -p "$copy" || return 1
  git -C "$src" archive HEAD | tar -x -C "$copy" || return 1
  git -C "$copy" init -q || return 1
  git -C "$copy" add -A || return 1
  git -C "$copy" -c user.email=negative-host-mutants@local -c user.name=negative-host-mutants commit -qm base || return 1
}

# Apply a (possibly empty) patch in the scratch copy and regenerate the
# identity manifest with the repo's own recipe (F314-1: the patch is applied
# and committed first, so the tree is clean; the regeneration may then
# change only the manifest). Sets REGEN_STATUS to one of ok | skipped-empty
# | failed | unchanged. An empty patch skips the regeneration (nothing to
# regenerate; the baseline manifest already matches its build): the RED and
# no-op paths. Otherwise a regeneration failure, an unchanged manifest, or
# any modified file beyond the manifest is a setup failure, never a flip.
apply_patch_and_regen() {
  local copy="$1" patch="$2" parent="$3"
  if [ ! -s "$patch" ]; then
    REGEN_STATUS=skipped-empty
    return 0
  fi
  git -C "$copy" apply "$patch" || {
    echo "negative-host-mutants: FAIL: patch does not apply" >&2
    REGEN_STATUS=failed
    return 1
  }
  git -C "$copy" add -A || {
    echo "negative-host-mutants: FAIL: cannot stage the mutant source" >&2
    REGEN_STATUS=failed
    return 1
  }
  git -C "$copy" -c user.email=negative-host-mutants@local -c user.name=negative-host-mutants commit -qm "mutant source" || {
    echo "negative-host-mutants: FAIL: cannot commit the mutant source" >&2
    REGEN_STATUS=failed
    return 1
  }
  (cd "$copy/onchain" && just script-identity-regen >"$parent/regen.log" 2>&1) || {
    echo "negative-host-mutants: FAIL: script-identity-regen failed (see regen.log)" >&2
    REGEN_STATUS=failed
    return 1
  }
  regen_manifest_ok "$copy" "$parent/base-manifest.json" || {
    echo "negative-host-mutants: FAIL: regeneration step changed more than the manifest, or the manifest did not change (see regen.log)" >&2
    REGEN_STATUS=failed
    return 1
  }
  REGEN_STATUS=ok
  return 0
}

# Run one part from the scratch copy with the scratch kept, so the verdict
# is read from the receipts. Sets PART_STATUS (the part's exit) and
# PART_KEPT (its kept scratch directory, empty when none was kept).
run_part() {
  local copy="$1" pair="$2" logbase="$3"
  PART_STATUS=0
  PART_KEPT=""
  (cd "$copy" && NEGATIVE_KEEP_SCRATCH=1 nix run --quiet .#negative-host-part -- "$pair" >"$logbase.stdout" 2>"$logbase.stderr") || PART_STATUS=$?
  PART_KEPT="$(grep '^kept scratch: ' "$logbase.stderr" 2>/dev/null | tail -n 1 | awk '{print $3}' || true)"
}

# Every altered-result control for classify_mutant_run, driven on fabricated
# results around one live receipt base. Each control fails exactly one guard
# (deleting that guard's check makes it classify as FLIPPED); the can-flip
# controls prove the function can still flip on each admissible status.
# Prints one line per control; returns nonzero on the first mismatch.
classification_controls() {
  local base="$1" work="$2"
  mkdir -p "$work" || return 1
  local succ="$work/success.json" client="$work/client.json" enc="$work/encoding.json" wrong="$work/wrong-command.json"
  local expect=""
  expect="$(jq -er .command "$base")" || return 1
  jq '.outcome = "success"' "$base" >"$succ" || return 1
  jq '.outcome = "client-refusal"' "$base" >"$client" || return 1
  jq '.outcome = "encoding-failure"' "$base" >"$enc" || return 1
  jq '.outcome = "success" | .command = "no-such-command"' "$base" >"$wrong" || return 1
  check_control "can-flip-exit-1" ok skipped 1 "$succ" "$expect" "FLIPPED" 0 || return 1
  check_control "can-flip-exit-3" ok skipped 3 "$succ" "$expect" "FLIPPED" 0 || return 1
  check_control "still-refused-exit-0" ok skipped 0 "$base" "$expect" "NOT-FLIPPED-REFUSED" 1 || return 1
  check_control "still-refused-exit-1" ok skipped 1 "$base" "$expect" "NOT-FLIPPED-REFUSED" 1 || return 1
  check_control "exit-3-ledger" ok skipped 3 "$base" "$expect" "SETUP" 1 || return 1
  check_control "exit-3-missing" ok skipped 3 "$work/absent.json" "$expect" "SETUP" 1 || return 1
  check_control "exit-1-missing" ok skipped 1 "$work/absent.json" "$expect" "MISSING" 1 || return 1
  check_control "other-client" ok skipped 1 "$client" "$expect" "OTHER-FAILURE" 1 || return 1
  check_control "other-encoding" ok skipped 1 "$enc" "$expect" "OTHER-FAILURE" 1 || return 1
  check_control "wrong-command" ok skipped 1 "$wrong" "$expect" "OTHER-FAILURE" 1 || return 1
  check_control "exit-0-success" ok skipped 0 "$succ" "$expect" "BAD-STATUS" 1 || return 1
  check_control "exit-2-success" ok skipped 2 "$succ" "$expect" "BAD-STATUS" 1 || return 1
  check_control "exit-127-success" ok skipped 127 "$succ" "$expect" "BAD-STATUS" 1 || return 1
  check_control "control-fails" ok 1 1 "$succ" "$expect" "CONTROL-FAILED" 1 || return 1
  check_control "regen-failed" failed skipped 1 "$succ" "$expect" "SETUP" 1 || return 1
  check_control "regen-unchanged" unchanged skipped 1 "$succ" "$expect" "SETUP" 1 || return 1
}

check_control() {
  local name="$1" regen="$2" control_exit="$3" part_exit="$4" receipt="$5" expect_command="$6" want="$7" want_status="$8"
  local got st
  set +e
  got="$(classify_mutant_run "$regen" "$control_exit" "$part_exit" "$receipt" "$expect_command")"
  st=$?
  set -e
  [ "$got" = "$want" ] || {
    echo "negative-host-mutants: control $name: got $got, want $want" >&2
    return 1
  }
  [ "$st" -eq "$want_status" ] || {
    echo "negative-host-mutants: control $name: status $st, want $want_status" >&2
    return 1
  }
  echo "negative-host-mutants: control $name: $got (as expected)"
}

# Every fabricated-state control for regen_manifest_ok (F314-1): a scratch
# state with the patch committed and only the manifest modified passes; a
# state with an extra modified file, an unchanged manifest, or a manifest
# move beyond the open_datum pins is rejected. Each state fails exactly one
# guard of the same function the live run calls. Prints one line per state;
# returns nonzero on the first mismatch. The mini-repo mirrors the scratch
# layout (onchain/script-identity.json) with fixture content.
regen_step_controls() {
  local base_manifest="$1" work="$2"
  local rdir="$work/regen"
  local man="$rdir/onchain/script-identity.json"
  local other="$rdir/onchain/validators/open_datum.ak"
  rm -rf "$rdir" || return 1
  mkdir -p "$rdir/onchain/validators" || return 1
  cp "$base_manifest" "$man" || return 1
  printf '%s\n' "-- placeholder validator (content irrelevant to the guard)" >"$other" || return 1
  git -C "$rdir" init -q || return 1
  git -C "$rdir" add -A || return 1
  git -C "$rdir" -c user.email=negative-host-mutants@local -c user.name=negative-host-mutants commit -qm base || return 1
  local st
  regen_manifest_ok "$rdir" "$work/unchanged-base.json" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: regen control unchanged-manifest passed" >&2
    return 1
  }
  echo "negative-host-mutants: regen control unchanged-manifest: rejected (as expected)"
  jq -e '[.validators[] | select(.title | startswith("open_datum."))][0] | .title' "$man" >/dev/null || return 1
  jq '.validators |= map(if (.title | startswith("open_datum.")) then .hash = "00000000000000000000000000000000000000000000000000000000" else . end)' "$man" >"$work/pass-manifest.json" || return 1
  cp "$work/pass-manifest.json" "$man" || return 1
  regen_manifest_ok "$rdir" "$work/pass-base.json" && st=0 || st=$?
  [ "$st" -eq 0 ] || {
    echo "negative-host-mutants: regen control manifest-only rejected" >&2
    return 1
  }
  echo "negative-host-mutants: regen control manifest-only: passes (as expected)"
  printf '%s\n' "-- extra modification outside the manifest" >>"$other" || return 1
  regen_manifest_ok "$rdir" "$work/extra-base.json" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: regen control extra-file passed" >&2
    return 1
  }
  echo "negative-host-mutants: regen control extra-file: rejected (as expected)"
  git -C "$rdir" checkout -- onchain/validators/open_datum.ak || return 1
  jq '.validators |= map(if (.title | startswith("open_datum.") | not) then .hash = "11111111111111111111111111111111111111111111111111111111" else . end)' "$man" >"$work/wide-manifest.json" || return 1
  cp "$work/wide-manifest.json" "$man" || return 1
  regen_manifest_ok "$rdir" "$work/wide-base.json" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: regen control wide-scope passed" >&2
    return 1
  }
  echo "negative-host-mutants: regen control wide-scope: rejected (as expected)"
}

# Every fabricated-patch control for patch_hygiene_ok: each real patch
# passes; a copy of a real patch with one extra hunk on another rule's
# line is rejected (hlines) while it still applies and still names one
# file and its rule's label (every other guard passes it); a patch
# retargeted to another file is rejected (hfiles); a patch touching only
# the condition line is rejected (hlabel) while hfiles and hlines still
# pass it. Prints one line per control; returns nonzero on the first
# mismatch.
patch_hygiene_controls() {
  local source="$1" work="$2"
  local name="" patch="" rules_csv="" file="" st=""
  local base="" donor=""
  rm -rf "$work" || return 1
  mkdir -p "$work/check/onchain/validators" || return 1
  cp "$source" "$work/check/onchain/validators/open_datum.ak" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    patch="$mutants_dir/$(mutant_field "$name" patch)" || return 1
    rules_csv="$(mutant_rules_csv "$name")" || return 1
    file="$(jq -er --arg n "$name" '.mutants[] | select(.name == $n) | .file' "$rules")" || return 1
    anchor="$(mutant_anchor "$name")" || return 1
    patch_hygiene_ok "$patch" "$rules_csv" "$file" "$source" "$anchor" && st=0 || st=$?
    [ "$st" -eq 0 ] || {
      echo "negative-host-mutants: hygiene control good-$name rejected" >&2
      return 1
    }
    echo "negative-host-mutants: hygiene control good-$name: passes (as expected)"
  done <<<"$names"
  base="$mutants_dir/update-controller-signature.patch"
  donor="$mutants_dir/update-escape.patch"
  [ -f "$base" ] || return 1
  [ -f "$donor" ] || return 1
  cp "$base" "$work/extra-hunk.patch" || return 1
  awk '/^@@/{p = 1} p' "$donor" >>"$work/extra-hunk.patch" || return 1
  (cd "$work/check" && git apply --check "$work/extra-hunk.patch") || {
    echo "negative-host-mutants: hygiene control extra-hunk does not apply" >&2
    return 1
  }
  grep -q -F "update-controller-signature" "$work/extra-hunk.patch" || {
    echo "negative-host-mutants: hygiene control extra-hunk lost its label" >&2
    return 1
  }
  patch_hygiene_ok "$work/extra-hunk.patch" "update-controller-signature" "onchain/validators/open_datum.ak" "$source" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: hygiene control extra-hunk passed" >&2
    return 1
  }
  echo "negative-host-mutants: hygiene control extra-hunk: rejected (as expected)"
  sed 's|onchain/validators/open_datum.ak|onchain/validators/other.ak|g' "$base" >"$work/wrong-file.patch" || return 1
  patch_hygiene_ok "$work/wrong-file.patch" "update-controller-signature" "onchain/validators/open_datum.ak" "$source" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: hygiene control wrong-file passed" >&2
    return 1
  }
  echo "negative-host-mutants: hygiene control wrong-file: rejected (as expected)"
  cat >"$work/condition-only.patch" <<'EOF'
diff --git a/onchain/validators/open_datum.ak b/onchain/validators/open_datum.ak
--- a/onchain/validators/open_datum.ak
+++ b/onchain/validators/open_datum.ak
@@ -366,7 +366,7 @@ fn validUpdate(control: Control, self: Output, tx: Transaction) -> Bool {
   if !holdsItsToken(control, self) {
     traceFalse(@"update-holding-token")
-  } else if !list.has(tx.extra_signatories, control.controller) {
+  } else if False {
     traceFalse(@"update-controller-signature")
   } else {
     when
       list.filter(
EOF
  (cd "$work/check" && git apply --check "$work/condition-only.patch") || {
    echo "negative-host-mutants: hygiene control condition-only does not apply" >&2
    return 1
  }
  patch_hygiene_ok "$work/condition-only.patch" "update-controller-signature" "onchain/validators/open_datum.ak" "$source" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: hygiene control condition-only passed" >&2
    return 1
  }
  echo "negative-host-mutants: hygiene control condition-only: rejected (as expected)"
  joint="$mutants_dir/token-continuation-leaves-the-holding.patch"
  [ -f "$joint" ] || return 1
  cp "$joint" "$work/joint-extra-hunk.patch" || return 1
  cat >>"$work/joint-extra-hunk.patch" <<'EOF'
@@ -386,5 +386,5 @@ fn validUpdate(control: Control, self: Output, tx: Transaction) -> Bool {
         } else if lovelace_of(next.value) < control.deposit {
-          traceFalse(@"update-deposit")
+          True
         } else {
           True
         }
EOF
  (cd "$work/check" && git apply --check "$work/joint-extra-hunk.patch") || {
    echo "negative-host-mutants: hygiene control joint-extra-hunk does not apply" >&2
    return 1
  }
  patch_hygiene_ok "$work/joint-extra-hunk.patch" "update-escape,update-control" "onchain/validators/open_datum.ak" "$source" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: hygiene control joint-extra-hunk passed" >&2
    return 1
  }
  echo "negative-host-mutants: hygiene control joint-extra-hunk: rejected (as expected)"
  cat >"$work/joint-only-one.patch" <<'EOF'
diff --git a/onchain/validators/open_datum.ak b/onchain/validators/open_datum.ak
--- a/onchain/validators/open_datum.ak
+++ b/onchain/validators/open_datum.ak
@@ -379,7 +379,7 @@ fn validUpdate(control: Control, self: Output, tx: Transaction) -> Bool {
       [next] ->
         if next.address != self.address {
-          traceFalse(@"update-escape")
+          True
         } else if liveControl(next.datum) != Some(control) {
           traceFalse(@"update-control")
         } else if without_lovelace(next.value) != without_lovelace(self.value) {
           traceFalse(@"update-assets")
EOF
  (cd "$work/check" && git apply --check "$work/joint-only-one.patch") || {
    echo "negative-host-mutants: hygiene control joint-only-one does not apply" >&2
    return 1
  }
  patch_hygiene_ok "$work/joint-only-one.patch" "update-escape,update-control" "onchain/validators/open_datum.ak" "$source" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: hygiene control joint-only-one passed" >&2
    return 1
  }
  echo "negative-host-mutants: hygiene control joint-only-one: rejected (as expected)"
  cat >"$work/insert-booking.patch" <<'EOF'
diff --git a/onchain/validators/open_datum.ak b/onchain/validators/open_datum.ak
--- a/onchain/validators/open_datum.ak
+++ b/onchain/validators/open_datum.ak
@@ -214,9 +214,9 @@ fn bookInsert(
   } else if control.key != key {
     traceFalse(@"app-key")
   } else if control.controller != owner {
-    traceFalse(@"app-owner")
+    True
   } else if !list.has(tx.extra_signatories, control.controller) {
-    traceFalse(@"app-controller-signature")
+    True
   } else if decodeAddress(address) != Some(
     Address { payment_credential: Script(policy_id), stake_credential: None },
   ) {
EOF
  (cd "$work/check" && git apply --check "$work/insert-booking.patch") || {
    echo "negative-host-mutants: hygiene control insert-booking does not apply" >&2
    return 1
  }
  patch_hygiene_ok "$work/insert-booking.patch" "app-owner,app-controller-signature" "onchain/validators/open_datum.ak" "$source" "fn bookTerminate(" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: hygiene control insert-booking passed" >&2
    return 1
  }
  echo "negative-host-mutants: hygiene control insert-booking: rejected (as expected)"
  sed 's/^@@ -214,9 +214,9 @@ fn bookInsert(/@@ -284,9 +284,9 @@ fn bookTerminate(/' "$work/insert-booking.patch" >"$work/misleading-header.patch" || return 1
  grep -q '^@@ -284,9 +284,9 @@ fn bookTerminate(' "$work/misleading-header.patch" || return 1
  patch_hygiene_ok "$work/misleading-header.patch" "app-owner,app-controller-signature" "onchain/validators/open_datum.ak" "$source" "fn bookTerminate(" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: hygiene control misleading-header passed" >&2
    return 1
  }
  echo "negative-host-mutants: hygiene control misleading-header: rejected (as expected)"
}

mutant_field() {
  local name="$1" field="$2"
  jq -er --arg n "$name" '.mutants[] | select(.name == $n) | .[$f] // empty' --arg f "$field" "$rules" || return 1
}

mutant_rules_csv() {
  local name="$1"
  jq -er --arg n "$name" '.mutants[] | select(.name == $n) | if has("rules") then (.rules | join(",")) else .rule end' "$rules" || return 1
}

mutant_anchor() {
  local name="$1"
  jq -r --arg n "$name" '.mutants[] | select(.name == $n) | .anchor // empty' "$rules" || return 1
}

mutant_side_flips() {
  local name="$1"
  jq -c --arg n "$name" '.mutants[] | select(.name == $n) | (.side_flips // [])[]' "$rules" || return 1
}

# Side acceptance (NOTE-027, one function): the live side loop collects the
# per-pair classifications and calls this; nothing else decides side acceptance.
# Inputs: mutant name, and a results file with lines "<pair> <classification>"
# (classification is the word classify_mutant_run prints: FLIPPED |
# NOT-FLIPPED-REFUSED | OTHER-FAILURE | MISSING | SETUP | CONTROL-FAILED |
# BAD-STATUS). Exactly two orthogonal guards:
# G1 exact membership: the sorted list of pair names in the results equals the
# sorted list of the entry's expected side pairs exactly (missing, unexpected
# and duplicate each break the equality; never reads classifications).
# G2 every result flipped: every classification present equals FLIPPED
# (iterates the results that exist, never the expected list, so a missing pair
# gives it nothing to fail on). Extra fails closed via G1.
side_flips_accepted() {
  local name="$1" results="$2"
  local expected="" expected_sorted="" actual_sorted="" line="" class=""
  [ -f "$results" ] || return 1
  expected="$(jq -r --arg n "$name" '.mutants[] | select(.name == $n) | (.side_flips // [])[].pair' "$rules")" || return 1
  expected_sorted="$(printf '%s' "$expected" | sort)" || return 1
  actual_sorted="$(awk 'NF{print $1}' "$results" | sort)" || return 1
  [ "$actual_sorted" = "$expected_sorted" ] || return 1 # GUARD-G1-membership
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    class="$(printf '%s' "$line" | awk '{print $2}')" || return 1
    [ "$class" = FLIPPED ] || return 1 # GUARD-G2-all-flipped
  done <"$results"
}

# Every side-acceptance control, driven through the live side_flips_accepted
# on fabricated result files built mechanically from the real entry's own side
# list (the same jq the live function reads, never a retyped list).
# (a) every expected pair once, all FLIPPED: accepted; (b) one expected pair
# missing, rest FLIPPED: rejected by G1 only; (c) all expected FLIPPED plus one
# unexpected FLIPPED (controller-withdraws-outside-a-fold, asserted not in the
# expected list): rejected by G1 only; (d) one expected pair duplicated, all
# FLIPPED: rejected by G1 only; (e) every pair once, one NOT-FLIPPED-REFUSED,
# rest FLIPPED: rejected by G2 only. Prints one line per control; returns
# nonzero on the first mismatch.
side_flip_controls() {
  local work="$1"
  local mutant="token-continuation-leaves-the-holding"
  local expected="" pair="" first="" st="" unexpected=""
  expected="$(jq -r --arg n "$mutant" '.mutants[] | select(.name == $n) | (.side_flips // [])[].pair' "$rules")" || return 1
  [ -n "$expected" ] || return 1
  mkdir -p "$work" || return 1
  : >"$work/all-flipped.txt" || return 1
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    printf '%s FLIPPED\n' "$pair" >>"$work/all-flipped.txt" || return 1
  done <<<"$expected"
  side_flips_accepted "$mutant" "$work/all-flipped.txt" && st=0 || st=$?
  [ "$st" -eq 0 ] || {
    echo "negative-host-mutants: side control all-flipped rejected" >&2
    return 1
  }
  echo "negative-host-mutants: side control all-flipped: accepted (as expected)"
  : >"$work/one-missing.txt" || return 1
  first=1
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    if [ "$first" = 1 ]; then
      first=0
      continue
    fi
    printf '%s FLIPPED\n' "$pair" >>"$work/one-missing.txt" || return 1
  done <<<"$expected"
  side_flips_accepted "$mutant" "$work/one-missing.txt" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: side control one-missing passed" >&2
    return 1
  }
  echo "negative-host-mutants: side control one-missing: rejected (as expected)"
  unexpected="controller-withdraws-outside-a-fold"
  printf '%s\n' "$expected" | grep -qxF -- "$unexpected" && {
    echo "negative-host-mutants: side control setup: unexpected pair is expected" >&2
    return 1
  } || true
  : >"$work/one-unexpected.txt" || return 1
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    printf '%s FLIPPED\n' "$pair" >>"$work/one-unexpected.txt" || return 1
  done <<<"$expected"
  printf '%s FLIPPED\n' "$unexpected" >>"$work/one-unexpected.txt" || return 1
  side_flips_accepted "$mutant" "$work/one-unexpected.txt" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: side control one-unexpected passed" >&2
    return 1
  }
  echo "negative-host-mutants: side control one-unexpected: rejected (as expected)"
  : >"$work/one-duplicated.txt" || return 1
  first=1
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    printf '%s FLIPPED\n' "$pair" >>"$work/one-duplicated.txt" || return 1
    if [ "$first" = 1 ]; then
      printf '%s FLIPPED\n' "$pair" >>"$work/one-duplicated.txt" || return 1
      first=0
    fi
  done <<<"$expected"
  side_flips_accepted "$mutant" "$work/one-duplicated.txt" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: side control one-duplicated passed" >&2
    return 1
  }
  echo "negative-host-mutants: side control one-duplicated: rejected (as expected)"
  : >"$work/one-not-flipped.txt" || return 1
  first=1
  while IFS= read -r pair; do
    [ -n "$pair" ] || continue
    if [ "$first" = 1 ]; then
      printf '%s NOT-FLIPPED-REFUSED\n' "$pair" >>"$work/one-not-flipped.txt" || return 1
      first=0
    else
      printf '%s FLIPPED\n' "$pair" >>"$work/one-not-flipped.txt" || return 1
    fi
  done <<<"$expected"
  side_flips_accepted "$mutant" "$work/one-not-flipped.txt" && st=0 || st=$?
  [ "$st" -ne 0 ] || {
    echo "negative-host-mutants: side control one-not-flipped passed" >&2
    return 1
  }
  echo "negative-host-mutants: side control one-not-flipped: rejected (as expected)"
}

if [ "$mode" = list ]; then
  count="$(jq -r '[.mutants[].name] | length' "$rules")" || fail "cannot read $rules"
  [ "$count" -gt 0 ] || {
    echo "negative-host-mutants: FAIL: empty mutant list" >&2
    exit 1
  }
  jq -c '{mutant: [.mutants[].name]}' "$rules"
  exit 0
fi

names=""
if [ "$mode" = one ]; then
  jq -e --arg n "$mutant" '.mutants[] | select(.name == $n)' "$rules" >/dev/null || {
    echo "negative-host-mutants: unknown mutant: $mutant" >&2
    exit 2
  }
  names="$mutant"
else
  names="$(jq -r '.mutants[].name' "$rules")" || fail "cannot read $rules"
  [ -n "$names" ] || fail "empty mutant list"
fi

# One scratch parent per process; every repo copy and every kept part
# scratch is recorded and removed at the end of its run, including failed
# runs (the trap is the backstop for abnormal exits).
scratch_parent="$(mktemp -d "${RUNNER_TEMP:-/tmp}/negative-host-mutants.XXXXXX")"
kept_list="$scratch_parent/kept.list"
touch "$kept_list"
cleanup_all() {
  local code=$?
  trap - EXIT
  if [ -f "$kept_list" ]; then
    while IFS= read -r d; do
      [ -n "${d:-}" ] && [ -d "$d" ] && rm -rf "$d"
    done <"$kept_list" || true
  fi
  rm -rf "$scratch_parent" || true
  exit "$code"
}
trap cleanup_all EXIT
record_kept() {
  [ -n "${1:-}" ] || return 0
  printf '%s\n' "$1" >>"$kept_list"
}
release_kept() {
  local dir="${1:-}" tmp="$scratch_parent/kept.tmp"
  [ -n "$dir" ] || return 0
  rm -rf "$dir" || true
  grep -vxF "$dir" "$kept_list" >"$tmp" || true
  mv "$tmp" "$kept_list"
}

# Run one mutant: every flip pair and every expected side flip must flip on the
# mutated copy, the declared control pair must pass there. Prints one verdict line per pair.
run_one_mutant() {
  local name="$1"
  local patch flips side_flips control rules_csv file copy anchor
  patch="$mutants_dir/$(mutant_field "$name" patch)" || return 1
  flips="$(jq -c --arg n "$name" '.mutants[] | select(.name == $n) | .flip[]' "$rules")" || return 1
  side_flips="$(mutant_side_flips "$name")" || return 1
  control="$(jq -er --arg n "$name" '.mutants[] | select(.name == $n) | .control' "$rules")" || return 1
  rules_csv="$(mutant_rules_csv "$name")" || return 1
  file="$(jq -er --arg n "$name" '.mutants[] | select(.name == $n) | .file' "$rules")" || return 1
  anchor="$(mutant_anchor "$name")" || return 1
  patch_hygiene_ok "$patch" "$rules_csv" "$file" "$root/$file" "$anchor" || {
    echo "negative-host-mutants [$name]: classified SETUP (patch hygiene)" >&2
    return 1
  }
  [ -n "$flips" ] || {
    echo "negative-host-mutants [$name]: FAIL: no flip pairs" >&2
    return 1
  }
  [ -f "$patch" ] || {
    echo "negative-host-mutants [$name]: FAIL: no patch file at $patch" >&2
    return 1
  }
  local run_dir="$scratch_parent/$name"
  mkdir -p "$run_dir" || return 1
  make_scratch_copy "$root" "$run_dir" || {
    echo "negative-host-mutants [$name]: FAIL: scratch copy failed (setup)" >&2
    return 1
  }
  copy="$run_dir/repo"
  REGEN_STATUS=""
  apply_patch_and_regen "$copy" "$patch" "$run_dir" || {
    echo "negative-host-mutants [$name]: classified SETUP (regeneration)" >&2
    return 1
  }
  if [ "$REGEN_STATUS" = ok ]; then
    git -C "$copy" add -A || return 1
    git -C "$copy" -c user.email=negative-host-mutants@local -c user.name=negative-host-mutants commit -qm "mutant pins $name" || return 1
  fi
  local t0 t1
  t0="$SECONDS"
  run_part "$copy" "$control" "$run_dir/control"
  t1="$SECONDS"
  local control_status="$PART_STATUS" control_kept="$PART_KEPT"
  record_kept "$control_kept"
  if [ "$control_status" -ne 0 ]; then
    echo "negative-host-mutants [$name]: control $control: part exit $control_status, want 0 ($((t1 - t0))s)" >&2
    release_kept "$control_kept"
    return 1
  fi
  echo "negative-host-mutants [$name]: control $control: PASS (part exit 0, $((t1 - t0))s)"
  release_kept "$control_kept"
  local entry pair expect class st
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    pair="$(jq -er .pair <<<"$entry")" || return 1
    expect="$(jq -er .command <<<"$entry")" || return 1
    t0="$SECONDS"
    run_part "$copy" "$pair" "$run_dir/flip-$pair"
    t1="$SECONDS"
    local flip_status="$PART_STATUS" flip_kept="$PART_KEPT"
    record_kept "$flip_kept"
    set +e
    class="$(classify_mutant_run "$REGEN_STATUS" "$control_status" "$flip_status" "$flip_kept/run/receipts/forbidden.json" "$expect")"
    st=$?
    set -e
    if [ "$st" -eq 0 ]; then
      echo "negative-host-mutants [$name]: pair $pair: FLIPPED (the node accepted, part exit $flip_status, $((t1 - t0))s)"
    else
      echo "negative-host-mutants [$name]: pair $pair: $class (part exit $flip_status, $((t1 - t0))s)" >&2
      release_kept "$flip_kept"
      return 1
    fi
    release_kept "$flip_kept"
  done <<<"$flips"
  local side_results="$run_dir/side-results.txt"
  : >"$side_results" || return 1
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    pair="$(jq -er .pair <<<"$entry")" || return 1
    expect="$(jq -er .command <<<"$entry")" || return 1
    t0="$SECONDS"
    run_part "$copy" "$pair" "$run_dir/side-$pair"
    t1="$SECONDS"
    local side_status="$PART_STATUS" side_kept="$PART_KEPT"
    record_kept "$side_kept"
    set +e
    class="$(classify_mutant_run "$REGEN_STATUS" "$control_status" "$side_status" "$side_kept/run/receipts/forbidden.json" "$expect")"
    st=$?
    set -e
    printf '%s %s\n' "$pair" "$class" >>"$side_results" || return 1
    if [ "$st" -eq 0 ]; then
      echo "negative-host-mutants [$name]: side $pair: FLIPPED (the node accepted, part exit $side_status, $((t1 - t0))s)"
    else
      echo "negative-host-mutants [$name]: side $pair: $class (part exit $side_status, $((t1 - t0))s)" >&2
    fi
    release_kept "$side_kept"
  done <<<"$side_flips"
  side_flips_accepted "$name" "$side_results" || {
    echo "negative-host-mutants [$name]: side acceptance failed" >&2
    return 1
  }
  echo "negative-host-mutants [$name]: PASS"
}

if [ "$mode" = noop ]; then
  # Self-check: an empty patch over every flip pair (the node still refuses,
  # so nothing flips), then the classification controls on altered results
  # around the first live receipt. Exits 0 only if the live empty run
  # classifies as not-flipped and every control holds.
  noop_ok=1
  first_base=""
  first_copy=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    flips="$(jq -c --arg n "$name" '.mutants[] | select(.name == $n) | (.flip + (.side_flips // []))[]' "$rules")" || fail "cannot read flips"
    run_dir="$scratch_parent/noop-$name"
    mkdir -p "$run_dir" || fail "scratch failed (setup)"
    make_scratch_copy "$root" "$run_dir" || fail "scratch copy failed (setup)"
    copy="$run_dir/repo"
    if [ -z "$first_copy" ]; then first_copy="$copy"; fi
    while IFS= read -r entry; do
      [ -n "$entry" ] || continue
      pair="$(jq -er .pair <<<"$entry")" || fail "cannot read flip pair"
      expect="$(jq -er .command <<<"$entry")" || fail "cannot read flip command"
      t0="$SECONDS"
      run_part "$copy" "$pair" "$run_dir/noop-$pair"
      t1="$SECONDS"
      flip_status="$PART_STATUS"
      flip_kept="$PART_KEPT"
      record_kept "$flip_kept"
      set +e
      class="$(classify_mutant_run "skipped-empty" "skipped" "$flip_status" "$flip_kept/run/receipts/forbidden.json" "$expect")"
      st=$?
      set -e
      if [ "$st" -eq 0 ]; then
        echo "negative-host-mutants: self-check $name/$pair: unexpectedly FLIPPED" >&2
        noop_ok=0
      elif [ "$class" = "NOT-FLIPPED-REFUSED" ]; then
        echo "negative-host-mutants: self-check $name/$pair: $class (the node still refuses, part exit $flip_status, $((t1 - t0))s)"
      else
        echo "negative-host-mutants: self-check $name/$pair: $class (part exit $flip_status), want NOT-FLIPPED-REFUSED" >&2
        noop_ok=0
      fi
      if [ -z "$first_base" ] && [ -f "$flip_kept/run/receipts/forbidden.json" ]; then
        first_base="$run_dir/base-forbidden.json"
        cp "$flip_kept/run/receipts/forbidden.json" "$first_base" || noop_ok=0
      fi
      release_kept "$flip_kept"
    done <<<"$flips"
  done <<<"$names"
  [ "$noop_ok" -eq 1 ] || fail "self-check live empty run failed"
  [ -n "$first_base" ] || fail "self-check produced no receipt base"
  [ -n "$first_copy" ] || fail "self-check produced no scratch copy"
  git -C "$first_copy" show HEAD:onchain/script-identity.json >"$scratch_parent/noop-base-manifest.json" || fail "self-check cannot read the scratch manifest"
  classification_controls "$first_base" "$scratch_parent/controls" || fail "self-check classification controls failed"
  regen_step_controls "$scratch_parent/noop-base-manifest.json" "$scratch_parent/regen-controls" || fail "self-check regeneration-step controls failed"
  patch_hygiene_controls "$root/onchain/validators/open_datum.ak" "$scratch_parent/hygiene-controls" || fail "self-check patch-hygiene controls failed"
  side_flip_controls "$scratch_parent/side-controls" || fail "self-check side-flip controls failed"
  echo "negative-host-mutants: SELF-CHECK PASS"
  exit 0
fi

overall=0
while IFS= read -r name; do
  [ -n "$name" ] || continue
  run_one_mutant "$name" || overall=1
done <<<"$names"
[ "$overall" -eq 0 ] || fail "one or more mutants did not flip"
echo "negative-host-mutants: PASS"
