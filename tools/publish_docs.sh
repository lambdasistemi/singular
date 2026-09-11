tag="$1"
expected_sha="$2"
[[ "$tag" == "v$DOCS_VERSION" && "$DOCS_VERSION" != "0.0.0" ]]
[[ "$(git rev-parse HEAD)" == "$expected_sha" ]]
[[ "$(git rev-parse "$tag^{commit}")" == "$expected_sha" ]]
git merge-base --is-ancestor "$expected_sha" origin/main
[[ "$(jq -r '."."' .release-please-manifest.json)" == "$DOCS_VERSION" ]]
pr="$(gh pr list --repo lambdasistemi/singular --state merged --base main --limit 100 \
  --json number,mergeCommit,headRefName,labels | jq -er --arg sha "$expected_sha" \
  '[.[] | select(.mergeCommit.oid == $sha and (.headRefName | startswith("release-please--")))
    | select(any(.labels[]; .name == "autorelease: pending" or .name == "autorelease: tagged"))]
   | if length == 1 then .[0].number else error("tag must match one merged release PR") end')"
if ! gh release view "$tag" --repo lambdasistemi/singular >/dev/null 2>&1; then
  gh release create "$tag" --repo lambdasistemi/singular --verify-tag \
    --title "Singular documentation and on-chain release $DOCS_VERSION" \
    --notes-file "${RELEASE_NOTES:-onchain-release/RELEASE.md}"
fi
gh release upload "$tag" "$DOCS_ARCHIVE"/* --repo lambdasistemi/singular --clobber
download="$(mktemp -d)"
trap 'rm -rf "$download"' EXIT
gh release download "$tag" --repo lambdasistemi/singular --dir "$download" \
  --pattern "singular-docs-$DOCS_VERSION.tar.gz" \
  --pattern "singular-onchain-$DOCS_VERSION.tar.gz" \
  --pattern SHA256SUMS
cmp "$DOCS_ARCHIVE/SHA256SUMS" "$download/SHA256SUMS"
(cd "$download" && sha256sum --check SHA256SUMS)
gh pr edit "$pr" --repo lambdasistemi/singular \
  --remove-label 'autorelease: pending' --add-label 'autorelease: tagged'
