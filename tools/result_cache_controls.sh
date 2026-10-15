#!/usr/bin/env bash
# result-cache-controls: the result cache misses exactly when it must.
#
# Usage: result_cache_controls.sh [ROOT] (default: the working tree).
# Requires $result_cache to name the result-cache binary (wired in the
# flake app); a direct run without it exits 2. File backend only: no
# Cachix write happens here (the script never invokes cachix).
#
# Truths and their controls:
#   identity-moves-with-every-input: for every input table entry, a
#     one-line plant in a scratch worktree moves the family identity;
#     the wrapped scripts and flake.lock are asserted to be input entries.
#   identity-ignores-outside-inputs: plants in setup-only and outside
#     files (docs, specs, another family's files) leave both identities
#     unchanged. (Root README.md is input since #592-R1: the docs build
#     stages it, so a change can fail the setup.)
#   every-tracked-file-is-classified: the clean tree classifies every
#     tracked file; a planted unclassified tracked file fails the check.
#   outside-removal (#592-R1): a scratch git copy holding only the files
#     classified input or setup-only still assembles the release
#     (exit 0); removing one known-read input file fails it.
#   marker-only-from-a-green-hosted-run: `false` publishes nothing; with
#     the hosted trio unset nothing is published while the command still
#     runs and returns its exit code.
#   marker-for-a-different-command-misses (#592-R2): the wrapped
#     command's argv is hashed into the pin name, so a marker published
#     by one command is a miss for another.
#   forced-run-ignores-markers: a present marker is ignored under
#     RESULT_CACHE_FORCE=1; a malformed or missing pin file is a miss.
# Every control is proven able to fail: each runs once more against a
# deliberately broken guard and must go red there. An unreadable identity
# in a demonstration is a harness failure, never the demonstration.
# Exit 0 only when all pass.
set -euo pipefail

root="${1:-$PWD}"
: "${result_cache:?result-cache-controls: \$result_cache is not wired (run through the flake app)}"
[ -x "$result_cache" ] || {
  echo "result-cache-controls: result-cache binary not executable: $result_cache" >&2
  exit 2
}
root="$(realpath -m "$root")"
[ -f "$root/flake.nix" ] || {
  echo "result-cache-controls: no flake.nix under $root" >&2
  exit 2
}
table="$root/nix/result-cache/classification.json"
[ -f "$table" ] || {
  echo "result-cache-controls: no classification table at $table" >&2
  exit 2
}
git -C "$root" ls-files --error-unmatch nix/result-cache/classification.json >/dev/null 2>&1 || {
  echo "result-cache-controls: SETUP: the table is untracked; commit first, then run the controls" >&2
  exit 2
}

pass=0
fail=0
able=0
ok() {
  pass=$((pass + 1))
  echo "result-cache-controls: ok: $*"
}
bad() {
  fail=$((fail + 1))
  echo "result-cache-controls: FAIL: $*" >&2
}
able_ok() {
  able=$((able + 1))
  echo "result-cache-controls: ABLE-TO-FAIL $* demonstrated"
}

# Table arrays, loaded once per tree under test with a single jq pass each.
# First match wins: file equals the entry path or lives under it.
T_N=0
T_PATH=()
T_CLASS=()
T_FAM=()
T_JOB=()
T_REASON=()
load_table() {
  local tab="$1"
  T_N="$(jq '.entries | length' "$tab")"
  mapfile -t T_PATH < <(jq -r '.entries[].path' "$tab")
  mapfile -t T_CLASS < <(jq -r '.entries[].class' "$tab")
  mapfile -t T_FAM < <(jq -r '.entries[] | (.families // [] | join(" "))' "$tab")
  mapfile -t T_JOB < <(jq -r '.entries[] | (.job // "")' "$tab")
  mapfile -t T_REASON < <(jq -r '.entries[] | (.reason // "")' "$tab")
}

match_index() {
  local file="$1" i
  for ((i = 0; i < T_N; i++)); do
    if [ "$file" = "${T_PATH[i]}" ] || [[ "$file" == "${T_PATH[i]}"/* ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

classify_of() {
  local idx
  if idx="$(match_index "$1")"; then
    printf '%s\n' "${T_CLASS[idx]}"
  else
    printf 'unclassified\n'
  fi
}

# The exhaustiveness check: schema, then every tracked file classified,
# then every entry live, in a single pass over the tree. Exit 0:
# exhaustive. Exit 1: a gap is named.
check_exhaustive() {
  local dir="$1" i f idx
  local -a seen=()
  load_table "$dir/nix/result-cache/classification.json"
  for ((i = 0; i < T_N; i++)); do
    case "${T_CLASS[i]}" in
      input)
        [ -n "${T_FAM[i]}" ] || {
          echo "entry $i (${T_PATH[i]}): input names no family" >&2
          return 1
        }
        ;;
      setup-only)
        [ -n "${T_JOB[i]}" ] || {
          echo "entry $i (${T_PATH[i]}): setup-only names no job" >&2
          return 1
        }
        ;;
      outside) ;;
      *)
        echo "entry $i (${T_PATH[i]}): unknown class ${T_CLASS[i]}" >&2
        return 1
        ;;
    esac
    [ -n "${T_REASON[i]}" ] || {
      echo "entry $i (${T_PATH[i]}): no reason" >&2
      return 1
    }
    seen[i]=0
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if idx="$(match_index "$f")"; then
      seen[idx]=1
    else
      echo "unclassified tracked file: $f" >&2
      return 1
    fi
  done < <(git -C "$dir" ls-files)
  for ((i = 0; i < T_N; i++)); do
    [ "${seen[i]}" = 1 ] || {
      echo "dead entry $i (${T_PATH[i]}): matches no tracked file" >&2
      return 1
    }
  done
  return 0
}

# The one shared identity reader: the same `result-cache identity`
# function the wrapper's run uses, evaluated in the given tree. Prints
# the hash; exit non-zero when unreadable (a harness failure, never a
# demonstration and never a hit).
read_identity() {
  local dir="$1" family="$2" err
  err="$(mktemp)" || return 1
  (cd "$dir" && "$result_cache" identity --family "$family" 2>"$err") || {
    cat "$err" >&2
    rm -f "$err"
    return 1
  }
  rm -f "$err"
}

plant_one_line() {
  local file="$1"
  case "$file" in
    *flake.lock)
      if jq -e '.nodes.nixpkgs.locked.lastModified' "$file" >/dev/null 2>&1; then
        jq '.nodes.nixpkgs.locked.lastModified += 1' "$file" >"$file.plant" && mv "$file.plant" "$file"
      else
        jq '.' "$file" >"$file.plant" && mv "$file.plant" "$file"
      fi
      ;;
    *classification.json)
      # The table is read at evaluation: keep it valid JSON and move the
      # fileset by pointing the first entry at the second entry's path,
      # dropping the first entry's unique files from the source.
      jq '.entries[0].path = .entries[1].path' "$file" >"$file.plant" && mv "$file.plant" "$file"
      ;;
    *.nix) printf '# result-cache control plant\n' >>"$file" ;;
    *) printf 'result-cache control plant\n' >>"$file" ;;
  esac
}

representative_of() {
  local dir="$1" path="$2" list first
  if [ -f "$dir/$path" ]; then
    printf '%s' "$path"
    return 0
  fi
  # No head truncation: the producer is unbounded and head closing early
  # SIGPIPEs it under pipefail. Read the first line instead. Skip
  # setup-only files: they are subtracted from the identity, so planting
  # one would not move it.
  list="$(git -C "$dir" ls-files -- "$path" 2>/dev/null)" || return 1
  [ -n "$list" ] || return 1
  while IFS= read -r first; do
    [ "$(classify_of "$first")" = setup-only ] || {
      printf '%s' "$first"
      return 0
    }
  done <<<"$list"
  return 1
}

# Scratch worktree over HEAD, reused and reset between plants.
wt="$(mktemp -d "${TMPDIR:-/tmp}/result-cache-controls.XXXXXX")"
removal_root=""
file_root=""
rmdir "$wt"
git -C "$root" worktree add --detach "$wt" HEAD >/dev/null 2>&1 || {
  echo "result-cache-controls: SETUP: cannot create a scratch worktree at $wt" >&2
  exit 2
}
trap 'git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"' EXIT
wt_reset() {
  git -C "$wt" reset --hard HEAD -q 2>/dev/null || return 1
  git -C "$wt" clean -fdq 2>/dev/null || return 1
}

echo "result-cache-controls: table: $(jq '.entries | length' "$table") entries"
echo "result-cache-controls: tracked files: $(git -C "$root" ls-files | wc -l)"

# Control every-tracked-file-is-classified on the clean tree.
if check_exhaustive "$root" 2>"$wt/exhaustive-clean.log"; then
  ok "every-tracked-file-is-classified holds on the clean tree"
else
  bad "clean tree is not exhaustive: $(cat "$wt/exhaustive-clean.log")"
fi

# Baselines through the shared reader.
base_pair=""
base_mutant=""
if base_pair="$(read_identity "$root" negative-host-pair)" && [ -n "$base_pair" ]; then
  ok "pair baseline identity $base_pair"
else
  bad "pair baseline identity unreadable"
fi
if base_mutant="$(read_identity "$root" negative-host-mutant)" && [ -n "$base_mutant" ]; then
  ok "mutant baseline identity $base_mutant"
else
  bad "mutant baseline identity unreadable"
fi
if [ -n "$base_pair" ] && [ -n "$base_mutant" ] && [ "$base_pair" != "$base_mutant" ]; then
  ok "the two family identities differ"
elif [ -n "$base_pair" ] && [ -n "$base_mutant" ]; then
  bad "the two family identities are equal ($base_pair): the mutant extras are missing"
fi

# The named files are input entries, not samples lost in a crowd.
load_table "$table"
for named in tools/negative_host_part.sh tools/negative_host_mutants.sh flake.lock; do
  if [ "$(classify_of "$named")" = input ]; then
    ok "$named is classified input"
  else
    bad "$named is not classified input (class: $(classify_of "$named"))"
  fi
done

# Control identity-moves-with-every-input: every input entry moves its
# families; mutant-only entries leave the pair identity unchanged (the
# another-family case). The root table stays loaded (plants never touch it).
moved=0
for ((i = 0; i < T_N; i++)); do
  [ "${T_CLASS[i]}" = input ] || continue
  path="${T_PATH[i]}"
  families="${T_FAM[i]}"
  wt_reset || {
    bad "worktree reset failed before entry $i ($path)"
    continue
  }
  rep="$(representative_of "$wt" "$path")"
  if [ -z "$rep" ]; then
    bad "entry $i ($path): no representative file"
    continue
  fi
  plant_one_line "$wt/$rep"
  if [[ "$families" == *negative-host-pair* ]]; then
    if got="$(read_identity "$wt" negative-host-pair)" && [ "$got" != "$base_pair" ]; then
      moved=$((moved + 1))
    else
      bad "entry $i ($path): pair identity did not move (got ${got:-unreadable})"
    fi
  else
    if got="$(read_identity "$wt" negative-host-pair)" && [ "$got" = "$base_pair" ]; then
      ok "entry $i ($path): pair identity unchanged (another family's file)"
    else
      bad "entry $i ($path): pair identity moved on a mutant-only plant (got ${got:-unreadable})"
    fi
  fi
  if [[ "$families" == *negative-host-mutant* ]]; then
    if got="$(read_identity "$wt" negative-host-mutant)" && [ "$got" != "$base_mutant" ]; then
      moved=$((moved + 1))
    else
      bad "entry $i ($path): mutant identity did not move (got ${got:-unreadable})"
    fi
  fi
done
ok "identity-moves-with-every-input: $moved family moves over all input entries"

# Able-to-fail: an outside plant must NOT move the identities, so the
# require-change assertion goes red here. Unreadable is a harness
# failure, never the demonstration.
wt_reset
plant_one_line "$wt/tools/demo1_cli_check.sh"
if got="$(read_identity "$wt" negative-host-pair)"; then
  if [ "$got" != "$base_pair" ]; then
    bad "able-to-fail identity-moves: outside plant moved the pair identity"
  else
    able_ok "identity-moves-with-every-input (outside plant leaves the require-change assertion red)"
  fi
else
  bad "able-to-fail identity-moves: identity unreadable after an outside plant"
fi

# Control identity-ignores-outside-inputs: setup-only and outside plants
# keep the hit. Root README.md is input since #592-R1 and is covered by
# the entry loop above, not here.
unchanged=0
for plant in docs/LEAN-CLARITY.md specs/299-singular-cli/spec.md tools/demo1_cli_check.sh applications/keri-stub/offchain/keri-stub.cabal applications/open-datum/lean/OpenDatumApplication.lean; do
  wt_reset || {
    bad "worktree reset failed before $plant"
    continue
  }
  plant_one_line "$wt/$plant"
  pair_same=0
  mutant_same=0
  if got="$(read_identity "$wt" negative-host-pair)" && [ "$got" = "$base_pair" ]; then pair_same=1; fi
  if got="$(read_identity "$wt" negative-host-mutant)" && [ "$got" = "$base_mutant" ]; then mutant_same=1; fi
  if [ "$pair_same" = 1 ] && [ "$mutant_same" = 1 ]; then
    unchanged=$((unchanged + 1))
  else
    bad "$plant moved an identity (pair_same=$pair_same mutant_same=$mutant_same)"
  fi
done
ok "identity-ignores-outside-inputs: $unchanged outside plants left both identities unchanged"

# Able-to-fail: an input plant must move the identity, so the
# require-unchanged assertion goes red here. Unreadable fails the demo.
wt_reset
plant_one_line "$wt/offchain/singular-registry.cabal"
if got="$(read_identity "$wt" negative-host-pair)"; then
  if [ "$got" = "$base_pair" ]; then
    bad "able-to-fail identity-ignores: input plant left the pair identity unchanged"
  else
    able_ok "identity-ignores-outside-inputs (input plant leaves the require-unchanged assertion red)"
  fi
else
  bad "able-to-fail identity-ignores: identity unreadable after an input plant"
fi

# Able-to-fail for every-tracked-file-is-classified: an unclassified
# tracked file fails the check, so requiring the check to pass goes red
# here. The failure must name the planted file, not just fail.
wt_reset
mkdir -p "$wt/unclassified-plant-dir"
printf 'plant\n' >"$wt/unclassified-plant-dir/plant.txt"
git -C "$wt" add unclassified-plant-dir/plant.txt
if check_exhaustive "$wt" 2>"$wt/exhaustive-plant.log"; then
  bad "able-to-fail every-tracked-file-is-classified: planted file passed the check"
elif grep -q "unclassified tracked file: unclassified-plant-dir/plant.txt" "$wt/exhaustive-plant.log"; then
  able_ok "every-tracked-file-is-classified (planted file fails naming it)"
else
  bad "able-to-fail every-tracked-file-is-classified: check failed without naming the plant: $(cat "$wt/exhaustive-plant.log")"
fi
wt_reset
load_table "$table"

# Control outside-removal (#592-R1): a scratch git copy holding only the
# files classified input or setup-only still assembles the release with
# the same command the pair and mutant jobs start with. Build the copy
# from the table's entry paths (the mutants script already proves
# scratch git copies run hosted commands).
removal_root="$(mktemp -d "${TMPDIR:-/tmp}/result-cache-removal.XXXXXX")"
trap 'git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; rm -rf "$removal_root" "$file_root"' EXIT
mapfile -t spec_paths < <(jq -r '.entries[] | select(.class != "outside") | .path' "$table")
if [ "${#spec_paths[@]}" -eq 0 ]; then
  bad "outside-removal SETUP: no input or setup-only paths in the table"
else
  git -C "$root" archive HEAD -o "$removal_root/tree.tar" -- "${spec_paths[@]}" || bad "outside-removal SETUP: git archive of the input and setup-only paths failed"
fi
if [ "${#spec_paths[@]}" -gt 0 ] && [ -f "$removal_root/tree.tar" ]; then
  mkdir -p "$removal_root/copy"
  tar -xf "$removal_root/tree.tar" -C "$removal_root/copy" || bad "outside-removal SETUP: extracting the scratch copy failed"
  git -C "$removal_root/copy" init -q || bad "outside-removal SETUP: git init failed"
  git -C "$removal_root/copy" add -A || bad "outside-removal SETUP: git add failed"
  git -C "$removal_root/copy" -c user.email=result-cache-controls@local -c user.name=result-cache-controls commit -qm "input and setup-only files" || bad "outside-removal SETUP: git commit failed"
  removal_out="$removal_root/release"
  mkdir -p "$removal_out"
  if (cd "$removal_root/copy" && nix run --quiet .#release-artifacts -- "$removal_out"); then
    ok "outside-removal: release-artifacts exits 0 with every outside file removed"
  else
    bad "outside-removal: release-artifacts failed with only input and setup-only files present (an outside file is needed)"
  fi
  # Able-to-fail: remove one file classified input and known to be read;
  # the same command must go red.
  rm "$removal_root/copy/.release-please-manifest.json"
  git -C "$removal_root/copy" add -A
  git -C "$removal_root/copy" -c user.email=result-cache-controls@local -c user.name=result-cache-controls commit -qm "remove a known-read input file"
  if (cd "$removal_root/copy" && nix run --quiet .#release-artifacts -- "$removal_out/removed"); then
    bad "able-to-fail outside-removal: assembly passed without .release-please-manifest.json"
  else
    able_ok "outside-removal (assembly without a known-read input file goes red)"
  fi
fi

# Marker controls use the file backend only. The hosted trio is simulated
# with explicit values; nothing here touches the real cache.
export GITHUB_ACTIONS=true GITHUB_RUN_ID=result-cache-controls-test CACHIX_AUTH_TOKEN=file-backend-dummy
export GITHUB_SERVER_URL=https://github.example GITHUB_REPOSITORY=example/repo GITHUB_JOB=result-cache-controls-test GITHUB_SHA=controls
file_root="$(mktemp -d "${TMPDIR:-/tmp}/result-cache-file.XXXXXX")"
trap 'git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; rm -rf "$removal_root" "$file_root"' EXIT

# Control marker-only-from-a-green-hosted-run, re-derived through run:
# `false` publishes nothing.
store="$file_root/green/store"
pins="$file_root/green/pins.json"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-green-leg --backend file --file-store "$store" --file-pins "$pins" -- false; then
  bad "run of \`false\` exited 0"
else
  if [ -f "$pins" ]; then
    bad "run of \`false\` published a marker"
  else
    ok "marker-only-from-a-green-hosted-run: \`false\` left no marker"
  fi
fi
# With the hosted trio unset, nothing is published while the command still
# runs and returns its exit code.
if env -u GITHUB_ACTIONS -u GITHUB_RUN_ID -u CACHIX_AUTH_TOKEN "$result_cache" run --family negative-host-pair --leg controls-laptop-leg --backend file --file-store "$file_root/laptop/store" --file-pins "$file_root/laptop/pins.json" -- true; then
  if [ -f "$file_root/laptop/pins.json" ]; then
    bad "laptop run published a marker"
  else
    ok "marker-only-from-a-green-hosted-run: trio unset publishes nothing and the command still runs"
  fi
else
  bad "laptop run of \`true\` failed"
fi
if env -u GITHUB_ACTIONS -u GITHUB_RUN_ID -u CACHIX_AUTH_TOKEN "$result_cache" run --family negative-host-pair --leg controls-laptop-false --backend file --file-store "$file_root/laptop2/store" --file-pins "$file_root/laptop2/pins.json" -- false; then
  bad "laptop run of \`false\` exited 0"
else
  if [ -f "$file_root/laptop2/pins.json" ]; then
    bad "laptop run of \`false\` published a marker"
  else
    ok "marker-only-from-a-green-hosted-run: trio unset with \`false\` publishes nothing and returns its exit code"
  fi
fi
# Able-to-fail, both directions, through run: a green hosted run
# publishes (so require-absent goes red); requiring refusal of a hosted
# green run goes red too.
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-true-leg --backend file --file-store "$file_root/true/store" --file-pins "$file_root/true/pins.json" -- true; then
  if [ -f "$file_root/true/pins.json" ]; then
    able_ok "marker-only-from-a-green-hosted-run (green run publishes, so require-absent goes red)"
  else
    bad "able-to-fail marker-only: green run published nothing"
  fi
else
  bad "able-to-fail marker-only: run of \`true\` failed"
fi

# Control marker-for-a-different-command-misses (#592-R2): `true`
# publishes under its own command hash; a different command misses even
# at the same identity and leg. The repeat uses the identical argv, so
# the command hash matches and the run must hit.
store2="$file_root/cmd/store"
pins2="$file_root/cmd/pins.json"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-cmd-leg --backend file --file-store "$store2" --file-pins "$pins2" -- true; then
  ok "control marker-for-a-different-command setup: \`true\` published its marker"
else
  bad "control marker-for-a-different-command setup: \`true\` failed"
fi
ran_other="$file_root/cmd-other.ran"
rm -f "$ran_other"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-cmd-leg --backend file --file-store "$store2" --file-pins "$pins2" -- bash -c "touch \"$ran_other\""; then
  if [ -f "$ran_other" ]; then
    ok "marker-for-a-different-command-misses: a different command ran past \`true\`'s marker"
  else
    bad "a different command skipped past \`true\`'s marker"
  fi
else
  bad "a different command failed"
fi
# Able-to-fail: repeating the identical different command hits, so
# require-ran goes red here. A failed run is a harness failure, not the demo.
rm -f "$ran_other"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-cmd-leg --backend file --file-store "$store2" --file-pins "$pins2" -- bash -c "touch \"$ran_other\""; then
  if [ -f "$ran_other" ]; then
    bad "able-to-fail different-command: repeated command executed past its own marker"
  else
    able_ok "marker-for-a-different-command-misses (repeated command hits, so require-ran goes red)"
  fi
else
  bad "able-to-fail different-command: repeated command failed"
fi

# Control forced-run-ignores-markers and read-failure-is-a-miss, all
# through one fixed command so the command hash stays identical: the
# setup publishes under it, the forced run must ignore it, the unforced
# run must hit it.
store5="$file_root/forced/store"
pins5="$file_root/forced/pins.json"
ran5="$file_root/forced.ran"
rm -f "$ran5"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-forced-leg --backend file --file-store "$store5" --file-pins "$pins5" -- bash -c "touch \"$ran5\""; then
  ok "control 5 setup: fixed command published its marker"
else
  bad "control 5 setup: fixed command failed"
fi
rm -f "$ran5"
if cd "$root" && RESULT_CACHE_FORCE=1 "$result_cache" run --family negative-host-pair --leg controls-forced-leg --backend file --file-store "$store5" --file-pins "$pins5" -- bash -c "touch \"$ran5\""; then
  if [ -f "$ran5" ]; then
    ok "forced-run-ignores-markers: RESULT_CACHE_FORCE=1 ran the command past a present marker"
  else
    bad "forced run skipped the command despite RESULT_CACHE_FORCE=1"
  fi
else
  bad "forced run failed"
fi
printf 'not json\n' >"$file_root/malformed.json"
ran5b="$file_root/malformed.ran"
rm -f "$ran5b"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-forced-leg --backend file --file-store "$store5" --file-pins "$file_root/malformed.json" -- bash -c "touch \"$ran5b\""; then
  if [ -f "$ran5b" ]; then
    ok "read-failure-is-a-miss: malformed pin file ran the test"
  else
    bad "malformed pin file skipped the test"
  fi
else
  bad "malformed pin file run failed"
fi
ran5c="$file_root/missing.ran"
rm -f "$ran5c"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-forced-leg --backend file --file-store "$store5" --file-pins "$file_root/absent.json" -- bash -c "touch \"$ran5c\""; then
  if [ -f "$ran5c" ]; then
    ok "read-failure-is-a-miss: missing pin file ran the test"
  else
    bad "missing pin file skipped the test"
  fi
else
  bad "missing pin file run failed"
fi
# Able-to-fail: without force the identical command must NOT run (hit),
# and with valid pins the identical run must NOT miss. A failed run is
# a harness failure.
rm -f "$ran5"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-forced-leg --backend file --file-store "$store5" --file-pins "$pins5" -- bash -c "touch \"$ran5\""; then
  if [ -f "$ran5" ]; then
    bad "able-to-fail forced-run: unforced run executed past a present marker"
  else
    able_ok "forced-run-ignores-markers (unforced run hits, so require-ran goes red)"
  fi
else
  bad "able-to-fail forced-run: unforced run failed"
fi
rm -f "$ran5"
if cd "$root" && "$result_cache" run --family negative-host-pair --leg controls-forced-leg --backend file --file-store "$store5" --file-pins "$pins5" -- bash -c "touch \"$ran5\""; then
  if [ -f "$ran5" ]; then
    bad "able-to-fail read-failure: valid pins missed"
  else
    able_ok "read-failure-is-a-miss (valid pins hit, so require-miss goes red)"
  fi
else
  bad "able-to-fail read-failure: valid-pins run failed"
fi

echo "result-cache-controls: pass=$pass fail=$fail able-to-fail=$able"
[ "$fail" -eq 0 ]
