#!/usr/bin/env bash
# tool: update packaged application identities and release rows from compiled
# blueprints. Freshness is an application-owned hosted test, not this maintenance
# tool.
#
# Two modes, each reading one published on-chain archive. The applied mode adds
# the row of an applied state policy (the state program applied to the
# application's policy). The legacy mode (--legacy-state-title) adds a release to
# the row of the state contract its blueprint states, creating the row when none
# holds it; it is for a release whose state program takes no application. Neither
# mode edits a hash or removes a release.
set -euo pipefail

usage() {
  echo 'usage: fill_contract_table.sh --table FILE --state-blueprint FILE --application-blueprint FILE --state-title TITLE --policy-title TITLE --script-title TITLE --project DIR [--singular-release TAG --application-release TAG] [--archive FILE]' >&2
  echo '   or: fill_contract_table.sh --table FILE --state-blueprint FILE --legacy-state-title TITLE --project DIR --singular-release TAG [--archive FILE]' >&2
  exit 64
}

table_file=''
state_blueprint=''
application_blueprint=''
state_title=''
policy_title=''
script_title=''
legacy_title=''
project_dir=''
singular_release=''
application_release=''
archive_file=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --table) table_file=$2 ;;
    --state-blueprint) state_blueprint=$2 ;;
    --application-blueprint) application_blueprint=$2 ;;
    --state-title) state_title=$2 ;;
    --policy-title) policy_title=$2 ;;
    --script-title) script_title=$2 ;;
    --legacy-state-title) legacy_title=$2 ;;
    --project) project_dir=$2 ;;
    --singular-release) singular_release=$2 ;;
    --application-release) application_release=$2 ;;
    --archive) archive_file=$2 ;;
    *) usage ;;
  esac
  shift 2
done
if [ -n "$legacy_title" ]; then
  for required in "$table_file" "$state_blueprint" "$project_dir" "$singular_release"; do
    [ -n "$required" ] || usage
  done
  [ -z "$application_blueprint$state_title$policy_title$script_title$application_release" ] || usage
else
  for required in "$table_file" "$state_blueprint" "$application_blueprint" "$state_title" "$policy_title" "$script_title" "$project_dir"; do
    [ -n "$required" ] || usage
  done
fi
table_file=$(realpath "$table_file")
state_blueprint=$(realpath "$state_blueprint")
[ -z "$application_blueprint" ] || application_blueprint=$(realpath "$application_blueprint")
project_dir=$(realpath "$project_dir")
[ -f "$project_dir/aiken.toml" ] || {
  echo 'the project has no aiken.toml' >&2
  exit 1
}

# This invocation owns its scratch directory; the table is replaced only after
# all derivation, identity and merge checks have succeeded.
scratch=$(mktemp -d)
table_tmp=$(mktemp "${table_file}.XXXXXX")
trap 'rm -rf "$scratch"; rm -f "$table_tmp"' EXIT

hash_of() {
  local blueprint=$1 title=$2 module validator purpose hash declared
  IFS=. read -r module validator purpose <<<"$title"
  [ -n "$module" ] && [ -n "$validator" ] && [ -n "$purpose" ] || usage
  declared=$(jq -er --arg title "$title" '
    [.validators[] | select(.title == $title and ((.parameters // []) | length == 0))]
    | if length == 1 then .[0].hash else error("expected one fully applied validator") end
  ' "$blueprint")
  hash=$(cd "$project_dir" && aiken blueprint hash -i "$blueprint" -m "$module" -v "$validator")
  [[ "$hash" =~ ^[0-9a-f]{56}$ ]] && [ "$hash" = "$declared" ] || {
    echo 'the computed validator hash disagrees with its blueprint' >&2
    exit 1
  }
  printf '%s' "$hash"
}

archive_hash=
if [ -n "$archive_file" ]; then
  archive_hash=$(sha256sum "$archive_file" | cut -d' ' -f1)
  [ -n "$singular_release" ] || {
    echo 'an archive needs its release tag' >&2
    exit 1
  }
fi

if [ -n "$legacy_title" ]; then
  state=$(hash_of "$state_blueprint" "$legacy_title")
  jq --arg state "$state" --arg singular "$singular_release" --arg archive "$archive_hash" '
    def tags($tag): if ($tag | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) then [$tag] else error("invalid release tag") end;
    def ordered: unique | sort_by(ltrimstr("v") | split(".") | map(tonumber));
    .rows = (.rows // [])
    | [.rows[] | select(."state-contract" == $state)] as $held
    | if ($held | length) > 1 then error("duplicate state contract") else . end
    | ([.rows[] | select(."state-contract" != $state) | .releases[]] + [(.applications // [])[]."singular-releases"[]]) as $elsewhere
    | if ($elsewhere | index($singular)) != null then error("the release is already in another row") else . end
    | .rows = (if ($held | length) == 1
        then [.rows[] | if ."state-contract" == $state then .releases = ((.releases + tags($singular)) | ordered) else . end]
        else .rows + [{"state-contract": $state, "releases": tags($singular)}] end)
    | if $archive != "" then
        if .archives[$singular] != null and .archives[$singular] != $archive then error("archive checksum changed")
        else .archives[$singular] = $archive end
      else . end
  ' "$table_file" >"$table_tmp"
  mv "$table_tmp" "$table_file"
  printf 'state contract %s is carried by %s\n' "$state" "$singular_release"
  exit 0
fi

policy=$(hash_of "$application_blueprint" "$policy_title")
script=$(hash_of "$application_blueprint" "$script_title")
IFS=. read -r state_module state_validator state_purpose <<<"$state_title"
[ -n "$state_purpose" ] || usage
aiken blueprint apply -i "$state_blueprint" -m "$state_module" -v "$state_validator" "581c$policy" >"$scratch/applied.json"
state=$(hash_of "$scratch/applied.json" "$state_title")
jq --arg state "$state" --arg policy "$policy" --arg script "$script" \
  --arg singular "$singular_release" --arg application "$application_release" \
  --arg archive "$archive_hash" '
  def tags($tag): if $tag == "" then [] elif ($tag | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) then [$tag] else error("invalid release tag") end;
  def ordered: unique | sort_by(ltrimstr("v") | split(".") | map(tonumber));
  .applications = (.applications // [])
  | [.applications[] | select(."state-policy" == $state)] as $old
  | if ($old | length) > 1 then error("duplicate applied state policy")
    elif ($old | length) == 1 and ($old[0]."application-policy" != $policy or $old[0]."application-script" != $script)
    then error("an applied state policy already names a different application") else . end
  | .applications = ([.applications[] | select(."state-policy" != $state)] + [{
      "state-policy": $state, "application-policy": $policy, "application-script": $script,
      "singular-releases": ((($old[0]."singular-releases" // []) + tags($singular)) | ordered),
      "application-releases": ((($old[0]."application-releases" // []) + tags($application)) | ordered)
    }] | sort_by(."state-policy"))
  | if $archive != "" then
      if .archives[$singular] != null and .archives[$singular] != $archive then error("archive checksum changed")
      else .archives[$singular] = $archive end
    else . end
' "$table_file" >"$table_tmp"
mv "$table_tmp" "$table_file"
printf 'applied state policy %s identifies policy %s and script %s\n' "$state" "$policy" "$script"
