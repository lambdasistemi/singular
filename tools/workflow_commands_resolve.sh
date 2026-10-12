#!/usr/bin/env bash
# shellcheck disable=SC2094 # the outer scan and the step helpers read the same workflow file; nothing writes it
# workflow-commands-resolve: every hosted nix run/build/develop reference resolves.
#
# Usage: workflow_commands_resolve.sh [ROOT] [FILE...]
#   ROOT defaults to the working tree (the repository root). When FILEs are
#   given they are checked with flake directories resolved against ROOT;
#   otherwise ROOT/.github/workflows/*.yml is checked.
#
# For each non-comment line naming `nix run`, `nix build` or `nix develop`,
# the script extracts the flake reference with its working directory (the
# step's `working-directory:` and a leading `cd <dir> &&` on the same line),
# resolves matrix values it can read from the same file, and requires the
# attribute to exist:
#   run:   apps.<system>.<name>.program (falling back to packages)
#   build: packages (falling back to checks)
#   external nixpkgs#<pkg>: nixpkgs#<pkg>.name (falling back to .pname),
#     resolved through the repository's pinned registry. References needing
# a matrix expansion the file does not list literally, and dynamic scratch
# directories, are named as unresolved and do not fail; a network failure
# while evaluating an external reference is logged and likewise named, never
# silently skipped. The closing summary counts resolved N of M with every
# unevaluated reference named.
#
# Exit 0: every static reference resolves. Exit 1: a static reference is
# missing. Exit 2: the harness failed.
#
# With --emit-references as the first argument the script instead prints
# every statically resolved hosted reference to stdout, one per line, and
# nothing else: `run <flake-dir> <attr>` for a step that runs an app,
# `build <flake-dir> <attr>` for a step that builds an attribute (a dotted
# `checks.<system>.<name>` build or a bare attribute), and
# `flake-check <flake-dir> -` for a `nix flake check` step, whose base
# directory comes from the step's working-directory or preceding cd like
# every other reference. Dynamic references are named on stderr and skipped
# (stdout stays pure for the census that consumes it); nothing is evaluated
# and the exit is 0 unless the harness itself failed.
set -euo pipefail

SYSTEM="x86_64-linux"
MATRIX_TOKEN="__MATRIX__"

emit=0
if [ "${1:-}" = "--emit-references" ]; then
  emit=1
  shift || true
fi

root="${1:-$PWD}"
if [ -d "$root" ]; then
  shift || true
else
  root="$PWD"
fi
root=$(realpath -m "$root")
files=()
if [ "$#" -eq 0 ]; then
  for f in "$root"/.github/workflows/*.yml; do
    files+=("$f")
  done
else
  files=("$@")
fi
[ "${#files[@]}" -gt 0 ] || {
  echo "workflow-commands-resolve: no workflow files" >&2
  exit 2
}

fail=0
resolved_count=0
net_probe=""
declare -A seen
unresolved=()

report_unresolved() {
  if [ "$emit" = 1 ]; then
    echo "unresolved: $1" >&2
  else
    unresolved+=("$1")
  fi
}

has_dollar() {
  [[ "$1" == *'$'* ]]
}

has_matrix() {
  [[ "$1" == *"$MATRIX_TOKEN"* ]]
}

has_squote() {
  [[ "$1" == *"'"* ]]
}

has_dquote() {
  [[ "$1" == *'"'* ]]
}

strip_quotes() {
  printf '%s' "$1" | tr -d '"' | tr -d "'"
}

# Step working directory for a line number: the working-directory: value
# inside the same `- ` step block, or empty when the step sets none.
step_workdir() {
  local file="$1" lineno="$2" prev next val
  prev=$(awk -v n="$lineno" '/^[[:space:]]*-[[:space:]]/ {if (NR<=n) s=NR} END{print s+0}' "$file")
  next=$(awk -v n="$lineno" '/^[[:space:]]*-[[:space:]]/ {if (NR>n) {print NR; exit}}' "$file")
  [ -n "$next" ] || next=$(wc -l <"$file")
  [ -n "$prev" ] || prev=1
  val=$(sed -n "${prev},$((next - 1))p" "$file" | grep -E '^[[:space:]]*working-directory:' | head -n 1 | sed -E 's/^[[:space:]]*working-directory:[[:space:]]*//' | tr -d '\r' || true)
  val=$(strip_quotes "$val")
  printf '%s' "$val"
}

# Full step text for a line number (for dynamic scratch-directory detection).
step_text() {
  local file="$1" lineno="$2" prev next total
  prev=$(awk -v n="$lineno" '/^[[:space:]]*-[[:space:]]/ {if (NR<=n) s=NR} END{print s+0}' "$file")
  next=$(awk -v n="$lineno" '/^[[:space:]]*-[[:space:]]/ {if (NR>n) {print NR; exit}}' "$file")
  total=$(wc -l <"$file")
  [ -n "$next" ] || next=$((total + 1))
  [ -n "$prev" ] || prev=1
  sed -n "${prev},$((next - 1))p" "$file" || true
}

# The last `cd <target>` line before a line number inside the same step,
# or empty when the step sets none. The target is raw (quotes kept) so the
# caller can tell static directories from dynamic scratch paths.
preceding_cd() {
  local file="$1" lineno="$2" prev line target
  prev=$(awk -v n="$lineno" '/^[[:space:]]*-[[:space:]]/ {if (NR<n) s=NR} END{print s+0}' "$file")
  [ -n "$prev" ] || prev=1
  target=""
  while IFS= read -r line; do
    case "$line" in
      *"cd "*)
        target=$(printf '%s' "$line" | sed -nE 's/^[[:space:]]*(\(|\ )?cd[[:space:]]+([^ ;&()]+).*/\2/p' || true)
        ;;
    esac
  done < <(sed -n "${prev},$((lineno - 1))p" "$file" || true)
  printf '%s' "$target"
}

# Literal `part: [a, b]` matrix values in a file, one per line.
matrix_parts() {
  grep -E 'part:[[:space:]]*\[' "$1" | head -n 1 | sed -E 's/.*\[//' | sed -E 's/\].*//' | tr ',' '\n' | sed -E 's/^[[:space:]]+//;s/[[:space:]]+$//' | tr -d '"' | tr -d "'" | grep -v '^$' || true
}

check_run() {
  local dir="$1" attr="$2" where="$3"
  local key="run|$dir|$attr"
  [ -z "${seen[$key]+x}" ] || return 0
  seen[$key]=1
  if nix eval --raw "$dir#apps.$SYSTEM.$attr.program" >/dev/null 2>&1; then
    resolved_count=$((resolved_count + 1))
    return 0
  fi
  if nix eval --raw "$dir#packages.$SYSTEM.$attr.outPath" >/dev/null 2>&1; then
    resolved_count=$((resolved_count + 1))
    return 0
  fi
  echo "FAIL: $where: nix run .#$attr does not resolve in $dir" >&2
  fail=1
}

check_build() {
  local dir="$1" attr="$2" where="$3"
  local key="build|$dir|$attr"
  [ -z "${seen[$key]+x}" ] || return 0
  seen[$key]=1
  case "$attr" in
    *.*)
      if nix eval --raw "$dir#$attr" >/dev/null 2>&1; then
        resolved_count=$((resolved_count + 1))
        return 0
      fi
      if nix eval --raw "$dir#$attr.outPath" >/dev/null 2>&1; then
        resolved_count=$((resolved_count + 1))
        return 0
      fi
      echo "FAIL: $where: nix build #$attr does not resolve in $dir" >&2
      fail=1
      return 0
      ;;
  esac
  if nix eval --raw "$dir#packages.$SYSTEM.$attr.outPath" >/dev/null 2>&1; then
    resolved_count=$((resolved_count + 1))
    return 0
  fi
  if nix eval --raw "$dir#checks.$SYSTEM.$attr.outPath" >/dev/null 2>&1; then
    resolved_count=$((resolved_count + 1))
    return 0
  fi
  echo "FAIL: $where: nix build .#$attr does not resolve in $dir" >&2
  fail=1
}

check_devshell() {
  local dir="$1" where="$2"
  local key="devshell|$dir"
  [ -z "${seen[$key]+x}" ] || return 0
  seen[$key]=1
  if nix eval --raw "$dir#devShells.$SYSTEM.default.outPath" >/dev/null 2>&1; then
    resolved_count=$((resolved_count + 1))
    return 0
  fi
  echo "FAIL: $where: devShell does not resolve in $dir" >&2
  fail=1
}

# External registry references: the attribute must exist in nixpkgs. A
# failure first probes a known package: if the probe also fails the network
# is unavailable, and the reference stays listed as unevaluated with that
# reason instead of failing the run.
check_external() {
  local pkg="$1" where="$2"
  local key="ext|$pkg"
  [ -z "${seen[$key]+x}" ] || return 0
  seen[$key]=1
  if nix eval --raw "nixpkgs#$pkg.name" >/dev/null 2>&1; then
    resolved_count=$((resolved_count + 1))
    return 0
  fi
  if nix eval --raw "nixpkgs#$pkg.pname" >/dev/null 2>&1; then
    resolved_count=$((resolved_count + 1))
    return 0
  fi
  if [ -z "$net_probe" ]; then
    if nix eval --raw nixpkgs#jq.name >/dev/null 2>&1; then
      net_probe="up"
    else
      net_probe="down"
    fi
  fi
  if [ "$net_probe" = "down" ]; then
    report_unresolved "$where: external nixpkgs#$pkg (unevaluated: registry unreachable)"
    return 0
  fi
  echo "FAIL: $where: external nixpkgs#$pkg does not resolve" >&2
  fail=1
}

# The two sinks of the one parser. In checking mode a reference is
# resolved against its flake; in emit mode it is printed once for the
# census. Dev shells and external registry references host no repository
# app or check, so emit mode skips them.
emit_ref() {
  local kind="$1" dir="$2" attr="$3" key
  if [ "$dir" = "$root" ]; then
    dir="."
  else
    case "$dir" in
      "$root"/*) dir="${dir#"$root"/}" ;;
      *)
        report_unresolved "reference outside the repository: $kind $dir $attr (skipped)"
        return 0
        ;;
    esac
  fi
  key="$kind|$dir|$attr"
  [ -z "${seen[$key]+x}" ] || return 0
  seen[$key]=1
  printf '%s %s %s\n' "$kind" "$dir" "$attr"
}

ref_run() {
  if [ "$emit" = 1 ]; then
    emit_ref run "$1" "$2"
  else
    check_run "$1" "$2" "$3"
  fi
}

ref_build() {
  if [ "$emit" = 1 ]; then
    emit_ref build "$1" "$2"
  else
    check_build "$1" "$2" "$3"
  fi
}

ref_devshell() {
  if [ "$emit" = 1 ]; then
    return 0
  else
    check_devshell "$1" "$2"
  fi
}

ref_external() {
  if [ "$emit" = 1 ]; then
    return 0
  else
    check_external "$1" "$2"
  fi
}

# Resolve a flake path against an effective base (both relative to root).
resolve_dir() {
  local base="$1" flake="$2" out
  if [ "$flake" = "." ] || [ "$flake" = "./." ]; then
    printf '%s' "$base"
    return 0
  fi
  if [ "$flake" = ".." ] || [ "$flake" = "../." ]; then
    printf '%s' "$(dirname "$base")"
    return 0
  fi
  if [ "$base" = "." ]; then
    out=$(realpath -m "$root/$flake")
  else
    out=$(realpath -m "$root/$base/$flake")
  fi
  out=${out#"$root"/}
  out=${out#"$root"}
  [ -n "$out" ] || out="."
  printf '%s' "$out"
}

# Map a scratch cd target naming the extracted archive back onto the tree.
extracted_suffix() {
  local target="$1" s
  s=${target##*extracted/}
  s=$(strip_quotes "$s")
  s=${s%%[ )]*}
  printf '%s' "$s"
}

# The base flake directory of a `nix flake check` line: the step's
# working-directory, refined by an inline or preceding static cd, resolved
# against the root. Emits `flake-check <dir> -`, or names the line
# unresolved on stderr when the base is dynamic.
emit_flake_check() {
  local file="$1" lineno="$2" sanitized="$3" base cd_target pcd suffix rel
  case "$sanitized" in
    *"nix flake check"*) ;;
    *) return 0 ;;
  esac
  base=$(step_workdir "$file" "$lineno")
  [ -n "$base" ] || base="."
  cd_target=$(printf '%s' "$sanitized" | sed -nE 's/.*cd[[:space:]]+([^ ;&()]+).*/\1/p' || true)
  if [ -n "$cd_target" ]; then
    if has_dollar "$cd_target" || has_squote "$cd_target" || has_dquote "$cd_target" || has_matrix "$cd_target"; then
      if [[ "$cd_target" == *"extracted"* ]]; then
        suffix=$(extracted_suffix "$cd_target")
        if has_dollar "$suffix" || [ -z "$suffix" ]; then
          report_unresolved "$file:$lineno: dynamic cd $cd_target (skipped)"
          return 0
        fi
        base="$suffix"
      else
        report_unresolved "$file:$lineno: dynamic cd $cd_target (skipped)"
        return 0
      fi
    else
      if [ "$base" = "." ]; then
        base="$cd_target"
      else
        base="$base/$cd_target"
      fi
    fi
  else
    pcd=$(preceding_cd "$file" "$lineno")
    if [ -n "$pcd" ]; then
      if has_dollar "$pcd" || has_squote "$pcd" || has_dquote "$pcd" || has_matrix "$pcd"; then
        if [[ "$pcd" == *"extracted"* ]]; then
          suffix=$(extracted_suffix "$pcd")
          if has_dollar "$suffix" || [ -z "$suffix" ]; then
            report_unresolved "$file:$lineno: dynamic cd $pcd (skipped)"
            return 0
          fi
          base="$suffix"
        else
          report_unresolved "$file:$lineno: dynamic cd $pcd (skipped)"
          return 0
        fi
      else
        if [ "$base" = "." ]; then
          base="$pcd"
        else
          base="$base/$pcd"
        fi
      fi
    fi
  fi
  if has_dollar "$base" || has_matrix "$base"; then
    report_unresolved "$file:$lineno: dynamic base $base (skipped)"
    return 0
  fi
  rel="$base"
  if [ "$rel" = ".." ] || [[ "$rel" == "../"* ]] || [[ "$rel" == /* ]]; then
    report_unresolved "$file:$lineno: dynamic directory $rel (skipped)"
    return 0
  fi
  if [ "$rel" = "." ]; then
    emit_ref flake-check "$root" "-"
  else
    emit_ref flake-check "$root/$rel" "-"
  fi
}

for file in "${files[@]}"; do
  [ -f "$file" ] || {
    echo "workflow-commands-resolve: no file $file" >&2
    exit 2
  }
  lineno=0
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    stripped=$(printf '%s' "$line" | sed -E 's/^[[:space:]]*//')
    case "$stripped" in
      \#*) continue ;;
      "") continue ;;
    esac
    case "$line" in
      *"nix run"* | *"nix build"* | *"nix develop"* | *"nix flake check"*) ;;
      *) continue ;;
    esac
    sanitized=$(printf '%s' "$line" | sed -E 's/\$\{\{[^{}]*\}\}/'"$MATRIX_TOKEN"'/g')
    case "$sanitized" in
      *"nix develop"*)
        case "$sanitized" in
          *"#"*) ;;
          *)
            base=$(step_workdir "$file" "$lineno")
            [ -n "$base" ] || base="."
            if has_dollar "$base"; then
              report_unresolved "$file:$lineno: dynamic working directory $base"
            else
              abs="$root"
              [ "$base" = "." ] || abs="$root/$base"
              ref_devshell "$abs" "$file:$lineno"
            fi
            ;;
        esac
        ;;
    esac
    if [ "$emit" = 1 ]; then
      emit_flake_check "$file" "$lineno" "$sanitized"
    fi
    matches=$(printf '%s' "$sanitized" | grep -oE 'nix[[:space:]]+(run|build|develop)[^#]*#[^[:space:]]+' || true)
    [ -n "$matches" ] || continue
    while IFS= read -r match || [ -n "$match" ]; do
      [ -n "$match" ] || continue
      cmd=$(printf '%s' "$match" | sed -E 's/^nix[[:space:]]+(run|build|develop).*/\1/')
      token=$(printf '%s' "$match" | grep -oE '[^[:space:]]+#[^[:space:]]+' | tail -n 1)
      flake=${token%%#*}
      attr=${token#*#}
      attr=$(printf '%s' "$attr" | sed -E 's/[^A-Za-z0-9_./-]+$//')
      where="$file:$lineno"
      case "$flake" in
        *"nixpkgs"*)
          ref_external "$attr" "$where"
          continue
          ;;
      esac
      if has_matrix "$attr"; then
        prefix=${attr%%"$MATRIX_TOKEN"*}
        rest=${attr#*"$MATRIX_TOKEN"}
        suffix="$rest"
        mapfile -t vals < <(matrix_parts "$file")
        if [ "${#vals[@]}" -eq 0 ]; then
          report_unresolved "$where: matrix reference $token (no literal values)"
          continue
        fi
        for v in "${vals[@]}"; do
          expanded="$prefix$v$suffix"
          base=$(step_workdir "$file" "$lineno")
          [ -n "$base" ] || base="."
          cd_target=$(printf '%s' "$sanitized" | sed -nE 's/.*cd[[:space:]]+([^ ;&()]+).*/\1/p' || true)
          if [ -n "$cd_target" ]; then
            if has_dollar "$cd_target" || has_squote "$cd_target" || has_dquote "$cd_target"; then
              :
            else
              if [ "$base" = "." ]; then
                base="$cd_target"
              else
                base="$base/$cd_target"
              fi
            fi
          fi
          rel=$(resolve_dir "$base" "$flake")
          [ -n "$rel" ] || rel="."
          if [ "$rel" = "." ]; then
            abs="$root"
          elif [[ "$rel" == /* ]]; then
            abs="$rel"
          else
            abs="$root/$rel"
          fi
          if [ "$cmd" = "run" ]; then
            ref_run "$abs" "$expanded" "$where (matrix $v)"
          else
            ref_build "$abs" "$expanded" "$where (matrix $v)"
          fi
        done
        continue
      fi
      base=$(step_workdir "$file" "$lineno")
      [ -n "$base" ] || base="."
      cd_target=$(printf '%s' "$sanitized" | sed -nE 's/.*cd[[:space:]]+([^ ;&()]+).*/\1/p' || true)
      if [ -n "$cd_target" ]; then
        if has_dollar "$cd_target" || has_squote "$cd_target" || has_dquote "$cd_target" || has_matrix "$cd_target"; then
          if [[ "$cd_target" == *"extracted"* ]]; then
            suffix=$(extracted_suffix "$cd_target")
            if has_dollar "$suffix" || [ -z "$suffix" ]; then
              report_unresolved "$where: dynamic cd $cd_target (skipped)"
              continue
            fi
            base="$suffix"
          else
            st=$(step_text "$file" "$lineno")
            if [[ "$st" == *"cd"*"extracted"* ]]; then
              suffix=$(printf '%s' "$st" | grep -E 'cd.*extracted/' | grep -oE 'extracted/[^" )]*' | head -n 1 | sed -E 's/^extracted\///' | tr -d "'" || true)
              if [ "$suffix" = ".git" ]; then
                report_unresolved "$where: dynamic cd $cd_target (skipped)"
                continue
              fi
              if [ -n "$suffix" ]; then
                base="$suffix"
              else
                report_unresolved "$where: dynamic cd $cd_target (skipped)"
                continue
              fi
            else
              report_unresolved "$where: dynamic cd $cd_target (skipped)"
              continue
            fi
          fi
        else
          if [ "$base" = "." ]; then
            base="$cd_target"
          else
            base="$base/$cd_target"
          fi
        fi
      else
        pcd=$(preceding_cd "$file" "$lineno")
        if [ -n "$pcd" ]; then
          if has_dollar "$pcd" || has_squote "$pcd" || has_dquote "$pcd" || has_matrix "$pcd"; then
            if [[ "$pcd" == *"extracted"* ]]; then
              suffix=$(extracted_suffix "$pcd")
              if has_dollar "$suffix" || [ -z "$suffix" ] || [ "$suffix" = ".git" ]; then
                report_unresolved "$where: dynamic cd $pcd (skipped)"
                continue
              fi
              base="$suffix"
            else
              report_unresolved "$where: dynamic cd $pcd (skipped)"
              continue
            fi
          else
            if [ "$base" = "." ]; then
              base="$pcd"
            else
              base="$base/$pcd"
            fi
          fi
        fi
      fi
      if has_dollar "$base" || has_matrix "$base"; then
        report_unresolved "$where: dynamic base $base (skipped)"
        continue
      fi
      rel=$(resolve_dir "$base" "$flake")
      [ -n "$rel" ] || rel="."
      if has_dollar "$rel" || has_matrix "$rel" || [ "$rel" = ".." ] || [[ "$rel" == "../"* ]] || [[ "$rel" == /* ]]; then
        report_unresolved "$where: dynamic directory $token in $base (skipped)"
        continue
      fi
      if [ "$rel" = "." ]; then
        abs="$root"
      else
        abs="$root/$rel"
      fi
      [ -d "$abs" ] || {
        if [ "$emit" = 1 ]; then
          report_unresolved "$where: no directory $abs for $token (skipped)"
          continue
        fi
        echo "FAIL: $where: no directory $abs for $token" >&2
        fail=1
        continue
      }
      if [ "$cmd" = "run" ]; then
        ref_run "$abs" "$attr" "$where"
      elif [ "$cmd" = "build" ]; then
        ref_build "$abs" "$attr" "$where"
      else
        case "$token" in
          *"#"*) ref_build "$abs" "$attr" "$where" ;;
          *) ref_devshell "$abs" "$where" ;;
        esac
      fi
    done <<<"$matches"
  done <"$file"
done

if [ "$emit" = 0 ]; then
  printf '%s\n' "resolved $resolved_count of ${#seen[@]}, unevaluated ${#unresolved[@]}"
  if [ "${#unresolved[@]}" -gt 0 ]; then
    printf '  %s\n' "${unresolved[@]}"
  fi
  if [ "$fail" -ne 0 ]; then
    echo "workflow-commands-resolve: FAIL" >&2
    exit 1
  fi
  echo "workflow-commands-resolve: PASS"
fi
