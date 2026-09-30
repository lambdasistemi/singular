#!/usr/bin/env bash
# Record the fold budget control pair (#280).
#
#   record.sh --candidate CANDIDATE --out OUT
#
# Runs the conformance job's own command, `nix run --quiet .#conformance-tests`,
# twice with one validator blueprint: on a detached local commit that applies
# fixed-fallback.patch to CANDIDATE (the mutant, expected to fail), then on
# CANDIDATE itself (expected to pass). Every recorded field is read from git,
# the filesystem, nix or the captured output; none is typed. Every git and nix
# command is journalled with its argument vector, directory, times, exit and
# the size and digest of its captured output. OUT must not exist; it is
# created. Exits 0 only when the pair is admissible and cleanup succeeded.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
dir_rel=conformance/review/fold-budget-control
patch_rel=$dir_rel/fixed-fallback.patch
record_rel=$dir_rel/record.sh

# Witness patterns, fixed before the pair is run. W1..W4 are the mutant's, in
# log order; the restored run shares W1 and W2 and adds W5 and W6.
w1='^Harness appendix: honest fold budget regression$'
w2='^A1 fixed fallback refused: purposes='
w3='^step: .* refusalKind=budget .* overDeclaredPurposes=\[[^]]+\]'
w4='^fold-budget regression: '
w4_not='^fold-budget regression: fixed fallback refused; evaluated interpreter accepted$'
w5='^fold-budget regression: fixed fallback refused; evaluated interpreter accepted$'
w6='^Every live chapter and the unnamed sequence passed\.$'
book_stage='^(Every live chapter and the unnamed sequence passed\.|Live run receipts: )'

usage() {
  echo 'usage: record.sh --candidate CANDIDATE --out OUT' >&2
  exit 2
}

die() {
  echo "record.sh: $*" >&2
  exit 2
}

candidate_arg=
out=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --candidate)
      [ "$#" -ge 2 ] || usage
      candidate_arg=$2
      shift 2
      ;;
    --out)
      [ "$#" -ge 2 ] || usage
      out=$2
      shift 2
      ;;
    *) usage ;;
  esac
done
[ -n "$candidate_arg" ] && [ -n "$out" ] || usage

for tool in git nix jq sha256sum awk find sort date mktemp cmp realpath; do
  command -v "$tool" >/dev/null || die "required tool not found: $tool"
done
for variable in E2E_GENESIS_DIR NAMING_BLUEPRINT; do
  [ -z "${!variable:-}" ] || die "$variable is set in the environment; unset it so both runs use the wrapper default"
done
out=$(realpath -m "$out")
[ ! -e "$out" ] || die "OUT already exists: $out"

# OUT exists before the first command, so every capture survives an early
# refusal; the journal and captured outputs are written there in place.
mkdir -p "$(dirname "$out")"
mkdir "$out"
work=$(mktemp -d -t fold-budget-control.XXXXXX)
candidate_tree=$work/candidate
mutant_tree=$work/mutant
journal=$out/invocations.jsonl
captured=$out/invocations
mkdir "$captured"
: >"$journal"
issue=
created=()
cleanup_failed=0

# remove_worktrees: remove only the worktrees this run created, by path.
remove_worktrees() {
  local tree
  for tree in "${created[@]}"; do
    if ! inv cleanup "$issue" git worktree remove --force "$tree"; then
      echo "record.sh: could not remove worktree $tree" >&2
      cleanup_failed=1
    fi
  done
  created=()
}

# finish: on any exit, remove what this run still owns. The journal and the
# captured outputs are already in OUT.
finish() {
  local status=$?
  trap - EXIT
  remove_worktrees
  rm -rf "$work"
  if [ "$cleanup_failed" -ne 0 ] && [ "$status" -eq 0 ]; then
    status=1
  fi
  exit "$status"
}
trap finish EXIT

now() {
  date -u +%Y-%m-%dT%H:%M:%S.%3NZ
}

# digest FILE NAME: `{file, bytes, sha256}` of a captured output, as JSON.
digest() {
  jq -cn --arg file "$2" --argjson bytes "$(wc -c <"$1")" \
    --arg sha256 "$(sha256sum "$1" | cut -d' ' -f1)" \
    '{file: $file, bytes: $bytes, sha256: $sha256}'
}

# journal_entry SCOPE DIR BEGIN END EXIT STDOUT STDERR ARGV...: one journal line.
journal_entry() {
  local scope=$1 where=$2 began=$3 ended=$4 rc=$5 stdout=$6 stderr=$7
  shift 7
  jq -cn --arg scope "$scope" --arg cwd "$where" --arg start "$began" --arg end "$ended" \
    --argjson exit "$rc" --argjson stdout "$stdout" --argjson stderr "$stderr" \
    --argjson argv "$(printf '%s\0' "$@" | jq -Rs 'split("\u0000")[:-1]')" \
    '{scope: $scope, cwd: $cwd, argv: $argv, start: $start, end: $end, exit: $exit, stdout: $stdout, stderr: $stderr}' \
    >>"$journal"
}

sequence=0
# inv SCOPE DIR ARGV...: run a git or nix command and journal it. Its standard
# output is in $inv_out (and, byte for byte, in the file $inv_file.out).
inv() {
  local scope=$1 where=$2 rc=0 began ended name
  shift 2
  sequence=$((sequence + 1))
  name=$(printf '%03d' "$sequence")
  inv_file=$captured/$name
  began=$(now)
  (cd "$where" && "$@") >"$inv_file.out" 2>"$inv_file.err" || rc=$?
  ended=$(now)
  inv_out=$(<"$inv_file.out")
  journal_entry "$scope" "$where" "$began" "$ended" "$rc" \
    "$(digest "$inv_file.out" "invocations/$name.out")" \
    "$(digest "$inv_file.err" "invocations/$name.err")" "$@"
  if [ "$rc" -ne 0 ]; then
    cat "$inv_file.err" >&2
  fi
  return "$rc"
}

inv shared "$here" git rev-parse --show-toplevel
issue=$inv_out
inv shared "$issue" git status --porcelain
[ -z "$inv_out" ] || die "the working tree is dirty"
inv shared "$issue" git rev-parse --verify --quiet "$candidate_arg^{commit}" \
  || die "unknown candidate: $candidate_arg"
candidate=$inv_out
inv shared "$issue" git cat-file -e "$candidate:$patch_rel" \
  || die "the candidate does not contain $patch_rel"
inv shared "$issue" git show "$candidate:$record_rel" \
  || die "the candidate does not contain $record_rel"
cmp -s "$inv_file.out" "$here/record.sh" \
  || die "this recorder differs from the one committed in the candidate"

inv shared "$issue" git worktree add --quiet --detach "$candidate_tree" "$candidate"
created+=("$candidate_tree")
inv shared "$issue" git worktree add --quiet --detach "$mutant_tree" "$candidate"
created+=("$mutant_tree")
inv mutant "$mutant_tree" git apply --index "$candidate_tree/$patch_rel"
inv mutant "$mutant_tree" git -c user.name=fold-budget-control -c user.email=noreply@invalid \
  -c commit.gpgsign=false commit --quiet --no-verify \
  -m "control: fixed fallback declaration for the fold budget regression (#280)"
inv mutant "$mutant_tree" git rev-parse HEAD
mutant=$inv_out
inv mutant "$mutant_tree" git rev-parse "$mutant^"
[ "$inv_out" = "$candidate" ] || die "the mutant commit is not a child of the candidate"

# The mutant differs from the candidate by exactly the committed patch.
inv mutant "$issue" git diff --full-index --no-color "$candidate" "$mutant"
cmp -s "$inv_file.out" "$candidate_tree/$patch_rel" \
  || die "git diff candidate mutant is not the committed patch"
patch_sha=$(sha256sum "$candidate_tree/$patch_rel" | cut -d' ' -f1)

# One validator blueprint, built from the candidate, for both runs.
inv shared "$candidate_tree/conformance" nix build --quiet --no-link --print-out-paths ../onchain#plutus-blueprint
blueprint=$inv_out
[ -r "$blueprint" ] || die "the blueprint is not a readable file: $blueprint"
blueprint_sha=$(sha256sum "$blueprint" | cut -d' ' -f1)

inv shared "$issue" nix eval --raw --impure --expr builtins.currentSystem
system=$inv_out

command_json=$(jq -cn '["nix", "run", "--quiet", ".#conformance-tests"]')
env_json=$(jq -cn --arg blueprint "$blueprint" '{REGISTRY_BLUEPRINT: $blueprint}')

# match_witness LOG AFTER INCLUDE [EXCLUDE]: the first line after line AFTER
# that matches INCLUDE and not EXCLUDE, as `line<TAB>text`; nothing when absent.
match_witness() {
  INCLUDE=$3 EXCLUDE=${4:-} awk -v after="$2" '
    BEGIN { include = ENVIRON["INCLUDE"]; exclude = ENVIRON["EXCLUDE"] }
    NR > after && $0 ~ include && (exclude == "" || $0 !~ exclude) {
      print NR "\t" $0
      exit
    }' "$1"
}

# witnesses ROLE LOG: the witness list as JSON, ending with a `complete` flag.
# A witness is looked up after the previous one, so order is part of the match.
witnesses() {
  local role=$1 log=$2 after=0 found ids patterns excludes complete=true
  local -a rows=()
  if [ "$role" = mutant ]; then
    ids=(W1 W2 W3 W4)
    patterns=("$w1" "$w2" "$w3" "$w4")
    excludes=("" "" "" "$w4_not")
  else
    ids=(W1 W2 W5 W6)
    patterns=("$w1" "$w2" "$w5" "$w6")
    excludes=("" "" "" "")
  fi
  local index
  for index in "${!ids[@]}"; do
    found=$(match_witness "$log" "$after" "${patterns[$index]}" "${excludes[$index]}")
    if [ -z "$found" ]; then
      complete=false
      rows+=("$(jq -cn --arg id "${ids[$index]}" '{id: $id, line: null, text: null}')")
      continue
    fi
    after=${found%%$'\t'*}
    rows+=("$(jq -cn --arg id "${ids[$index]}" --argjson line "$after" --arg text "${found#*$'\t'}" \
      '{id: $id, line: $line, text: $text}')")
  done
  printf '%s\n' "${rows[@]}" | jq -cs --argjson complete "$complete" '{list: ., complete: $complete}'
}

# purposes TEXT KEY: the redeemer purposes named after `KEY=[...]`, one per
# line, quotes stripped and sorted, so the fixture's and the runner's spellings
# agree.
purposes() {
  printf '%s\n' "$1" | sed -n "s/.*$2=\[\([^]]*\)\].*/\1/p" | head -n 1 \
    | sed 's/"//g' | sed 's/, *\(Conway\)/\n\1/g' | sort
}

# facts ROLE TREE: the wrapper facts read after the run, into f_* variables.
facts() {
  local program
  inv "$1" "$2/conformance" nix eval --raw ".#apps.$system.conformance-tests.program"
  program=$inv_out
  f_program=$program
  f_regression=$(grep -o '/nix/store/[^ ]*-fold-budget-regression/bin/fold-budget-regression' "$program" | head -n 1)
  f_runner=$(grep -o '/nix/store/[^ ]*-conformance/bin/conformance' "$program" | head -n 1 || true)
  [ -n "$f_regression" ] || die "no fold-budget-regression wrapper in $program"
  f_genesis=$(grep -o '/nix/store/[^ '"'"'"}]*/conformance/genesis' "$f_regression" | head -n 1)
  [ -n "$f_genesis" ] && [ -d "$f_genesis" ] || die "no genesis directory in $f_regression"
}

# run_tree ROLE TREE: the CI command in TREE/conformance, its record.
run_tree() {
  local role=$1 tree=$2 start end status=0
  local log=$out/$role.log
  local tree_id lean_tree lean_corpus dirty commit genesis_sha node witness_json
  inv "$role" "$tree" git rev-parse HEAD
  commit=$inv_out
  inv "$role" "$tree" git rev-parse "HEAD^{tree}"
  tree_id=$inv_out
  inv "$role" "$tree" git rev-parse HEAD:lean
  lean_tree=$inv_out
  lean_corpus=$(sha256sum "$tree/lean/driver-corpus.json" | cut -d' ' -f1)
  inv "$role" "$tree" git status --porcelain
  dirty=$(printf '%s' "$inv_out" | grep -c . || true)
  start=$(now)
  (cd "$tree/conformance" && REGISTRY_BLUEPRINT=$blueprint nix run --quiet .#conformance-tests) \
    </dev/null >"$log" 2>&1 || status=$?
  end=$(now)
  # Standard output and error of the run are the one retained log.
  journal_entry "$role" "$tree/conformance" "$start" "$end" "$status" \
    "$(digest "$log" "$role.log")" '{"file": null, "bytes": 0, "sha256": null}' \
    nix run --quiet .#conformance-tests

  facts "$role" "$tree"
  genesis_sha=$(cd "$f_genesis" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
  node=$(grep -m 1 '^node: ' "$log" || true)
  witness_json=$(witnesses "$role" "$log")

  local patch_json=null
  if [ "$role" = mutant ]; then
    patch_json=$(jq -cn --arg path "$patch_rel" --arg sha256 "$patch_sha" '{path: $path, sha256: $sha256}')
  fi
  jq -n \
    --arg role "$role" --arg commit "$commit" --arg tree "$tree_id" \
    --arg candidate "$candidate" --arg root "$tree" \
    --argjson dirty "$dirty" --argjson patch "$patch_json" \
    --arg leanTree "$lean_tree" --arg leanCorpus "$lean_corpus" \
    --arg blueprint "$blueprint" --arg blueprintSha "$blueprint_sha" \
    --arg genesis "$f_genesis" --arg genesisSha "$genesis_sha" --arg node "$node" \
    --argjson command "$command_json" --argjson env "$env_json" \
    --arg program "$f_program" --arg regression "$f_regression" --arg runner "$f_runner" \
    --arg start "$start" --arg end "$end" --argjson exit "$status" \
    --arg retained "$role.log" --argjson bytes "$(wc -c <"$log")" --argjson lines "$(wc -l <"$log")" \
    --arg logSha "$(sha256sum "$log" | cut -d' ' -f1)" \
    --argjson witnesses "$witness_json" \
    '{
      role: $role, commit: $commit, tree: $tree, candidate: $candidate, root: $root,
      dirty: $dirty, patch: $patch,
      lean: {tree: $leanTree, driverCorpusSha256: $leanCorpus},
      blueprint: {path: $blueprint, sha256: $blueprintSha},
      genesis: {directory: $genesis, sha256: $genesisSha},
      node: $node,
      command: $command, cwd: "conformance", env: $env,
      builds: {program: $program, regression: $regression, runner: $runner},
      start: $start, end: $end, exit: $exit,
      log: {retained: $retained, bytes: $bytes, lines: $lines, sha256: $logSha},
      witnesses: $witnesses.list, witnessesComplete: $witnesses.complete
    }' >"$work/$role.partial.json"
}

run_tree mutant "$mutant_tree"
run_tree restored "$candidate_tree"

# The worktrees go before the records are written, so each record carries the
# removals: its invocations are the shared preflight and cleanup entries plus
# its own role's, complete and ordered.
remove_worktrees
for role in mutant restored; do
  jq --slurpfile invocations "$journal" \
    '. as $record | $record + {invocations: [$invocations[] | select(.scope == "shared" or .scope == "cleanup" or .scope == $record.role)]}' \
    "$work/$role.partial.json" >"$out/$role.json"
done

# Pair admissibility: every rule of the data model, each reported by name.
problems=()
check() {
  if ! jq -es "all(.[]; $2)" "$out/mutant.json" "$out/restored.json" >/dev/null; then
    problems+=("$1")
  fi
}
check "a record has a dirty tree" '.dirty == 0'
check "the mutant did not exit nonzero with all its witnesses" '.role != "mutant" or (.exit != 0 and .witnessesComplete)'
check "the restored run did not exit 0 with all its witnesses" '.role != "restored" or (.exit == 0 and .witnessesComplete)'
check "a record carries no node version line" '.node != ""'
check "a journalled invocation has no output digest" 'all(.invocations[]; (.stdout.bytes | type) == "number" and (.stdout.sha256 | type) == "string")'
check "a record lacks the removal of the two worktrees" '[.invocations[] | select(.scope == "cleanup" and .argv[0:3] == ["git", "worktree", "remove"] and .exit == 0)] | length == 2'
for field in lean blueprint genesis.sha256 node command env cwd; do
  if [ "$(jq -c ".$field" "$out/mutant.json")" != "$(jq -c ".$field" "$out/restored.json")" ]; then
    problems+=("the records disagree on $field")
  fi
done
[ "$(jq -r .commit "$out/restored.json")" = "$candidate" ] || problems+=("the restored run is not the candidate")
[ "$(jq -r .commit "$out/mutant.json")" = "$mutant" ] || problems+=("the mutant record is not the mutant commit")
[ "$(jq -r .builds.regression "$out/mutant.json")" != "$(jq -r .builds.regression "$out/restored.json")" ] \
  || problems+=("the two runs used the same regression target build")
for role in mutant restored; do
  [ "$(sha256sum "$out/$role.log" | cut -d' ' -f1)" = "$(jq -r .log.sha256 "$out/$role.json")" ] \
    || problems+=("the $role retained log does not match its digest")
  [ "$(wc -c <"$out/$role.log")" -le 5242880 ] || problems+=("the $role raw log exceeds 5 MiB")
done

# The refusal the runner reports must concern the purposes the fixture refused.
fixture_purposes=$(purposes "$(jq -r '.witnesses[] | select(.id == "W2") | .text // empty' "$out/mutant.json")" purposes)
runner_purposes=$(purposes "$(jq -r '.witnesses[] | select(.id == "W3") | .text // empty' "$out/mutant.json")" overDeclaredPurposes)
if [ -z "$runner_purposes" ] || [ "$fixture_purposes" != "$runner_purposes" ]; then
  problems+=("the runner's over-declared purposes differ from the fixture's refused purposes")
fi

# The book stage is not reached in the mutant run.
if grep -Eq "$book_stage" "$out/mutant.log"; then
  problems+=("the mutant log carries a book stage line")
fi

echo "mutant  commit=$mutant exit=$(jq -r .exit "$out/mutant.json") witnesses=$(jq -c '[.witnesses[].line]' "$out/mutant.json")"
echo "restored commit=$candidate exit=$(jq -r .exit "$out/restored.json") witnesses=$(jq -c '[.witnesses[].line]' "$out/restored.json")"
if [ "$cleanup_failed" -ne 0 ]; then
  problems+=("cleanup failed: a worktree this run created was not removed")
fi
if [ "${#problems[@]}" -ne 0 ]; then
  printf 'pair NOT admissible: %s\n' "${problems[@]}" >&2
  exit 1
fi
echo "pair admissible: records, logs and the invocation journal in $out"
