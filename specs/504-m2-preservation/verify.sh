#!/usr/bin/env bash
set -euo pipefail
manifest_commit=${1:?usage: verify.sh MANIFEST_COMMIT}
manifest_commit=$(git rev-parse "${manifest_commit}^{commit}")
manifest=specs/504-m2-preservation/manifest.json
test "$(git hash-object "$manifest")" = "$(git rev-parse "$manifest_commit:$manifest")"
printf 'manifest_commit=%s\n' "$manifest_commit"
baseline=$(jq -r .baseline.sha "$manifest")
tree=$(jq -r .baseline.tree "$manifest")
ref=$(jq -r .baseline.permanentRef "$manifest")
remote_ref=${ref/refs\/heads\//refs\/remotes\/origin\/}
test "$(git rev-parse "$baseline^{tree}")" = "$tree"
git merge-base --is-ancestor "$baseline" "$remote_ref"
test "$(git rev-parse "$remote_ref")" = "$manifest_commit"
printf 'baseline=%s tree=%s ref=%s exit=0\n' "$baseline" "$tree" "$ref"
while IFS=$'\t' read -r sha expected_tree ref; do
  remote_ref=${ref/refs\/heads\//refs\/remotes\/origin\/}
  test "$(git rev-parse "$remote_ref")" = "$sha"
  test "$(git rev-parse "$remote_ref^{tree}")" = "$expected_tree"
  git merge-base --is-ancestor "$sha" "$remote_ref"
  printf 'candidate=%s tree=%s ref=%s exit=0\n' "$sha" "$expected_tree" "$ref"
done < <(jq -r '.candidates[] | [.sha,.tree,.permanentRef] | @tsv' "$manifest")
while IFS=$'\t' read -r path expected_blob; do
  test "$(git rev-parse "$baseline:$path")" = "$expected_blob"
  test "$(git rev-parse "$manifest_commit:$path")" = "$expected_blob"
done < <(jq -r '.sourceBlobs[] | [.path,.blob] | @tsv' "$manifest")
while IFS= read -r path; do
  [[ "$path" == specs/504-m2-preservation/* ]]
done < <(git diff --name-only "$baseline" "$manifest_commit")
census_checked=0
while IFS=$'\t' read -r source sha expected_tree disposition ref; do
  [[ "$source" == source ]] && continue
  [[ "$disposition" == unclassified-excluded-from-cleanup ]] && continue
  test "$(git rev-parse "$sha^{tree}")" = "$expected_tree"
  if [[ "$disposition" == reachable-integrated-baseline ]]; then
    git merge-base --is-ancestor "$sha" "$baseline"
  elif [[ "$disposition" == retained-candidate ]]; then
    remote_ref=${ref/refs\/heads\//refs\/remotes\/origin\/}
    git merge-base --is-ancestor "$sha" "$remote_ref"
  else
    printf 'unknown census disposition: %s\n' "$disposition" >&2
    exit 1
  fi
  census_checked=$((census_checked + 1))
done < specs/504-m2-preservation/evidence/census.tsv
printf 'retained_census_rows=%s exit=0\n' "$census_checked"
sha256sum -c specs/504-m2-preservation/evidence/SHA256SUMS.txt
printf 'PASS candidates=%s source_blobs=%s doc_only=1\n' "$(jq '.candidates | length' "$manifest")" "$(jq '.sourceBlobs | length' "$manifest")"
