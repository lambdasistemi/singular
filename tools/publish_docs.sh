tag="$1"
expected_sha="$2"
[[ "$tag" == "v$DOCS_VERSION" && "$DOCS_VERSION" != "0.0.0" ]]
[[ "$(git rev-parse HEAD)" == "$expected_sha" ]]
[[ "$(git rev-parse "$tag^{commit}")" == "$expected_sha" ]]
git merge-base --is-ancestor "$expected_sha" origin/main
[[ "$(jq -r '."."' .release-please-manifest.json)" == "$DOCS_VERSION" ]]
download="$(mktemp -d)"
trap 'rm -rf "$download"' EXIT
section=""
found=false
has_changes=false
while IFS= read -r line || [[ -n "$line" ]]; do
  if $found; then
    [[ "$line" != "## "* ]] || break
    [[ "$line" =~ ^[[:space:]]*$ ]] || has_changes=true
    section+="$line"$'\n'
  elif [[ "$line" == "## [$DOCS_VERSION]" || "$line" == "## [$DOCS_VERSION]("* || "$line" == "## [$DOCS_VERSION] "* ]]; then
    found=true
    section="$line"$'\n'
  fi
done < CHANGELOG.md
if ! $has_changes; then
  echo "FAIL: missing or empty CHANGELOG.md section for $DOCS_VERSION" >&2
  exit 1
fi
while [[ "$section" == *$'\n' ]]; do section="${section%$'\n'}"; done
printf '%s\n\n' "$section" > "$download/release-notes.md"
cat "${RELEASE_NOTES:-onchain-release/RELEASE.md}" >> "$download/release-notes.md"
pr="$(gh pr list --repo lambdasistemi/singular --state merged --base main --limit 100 \
  --json number,mergeCommit,headRefName,labels | jq -er --arg sha "$expected_sha" \
  '[.[] | select(.mergeCommit.oid == $sha and (.headRefName | startswith("release-please--")))
    | select(any(.labels[]; .name == "autorelease: pending" or .name == "autorelease: tagged"))]
   | if length == 1 then .[0].number else error("tag must match one merged release PR") end')"
if ! gh release view "$tag" --repo lambdasistemi/singular >/dev/null 2>&1; then
  gh release create "$tag" --repo lambdasistemi/singular --verify-tag \
    --title "Singular documentation and on-chain release $DOCS_VERSION" \
    --notes-file "$download/release-notes.md"
fi
gh release upload "$tag" "$DOCS_ARCHIVE"/* --repo lambdasistemi/singular --clobber
gh release download "$tag" --repo lambdasistemi/singular --dir "$download" \
  --pattern "singular-docs-$DOCS_VERSION.tar.gz" \
  --pattern "singular-onchain-$DOCS_VERSION.tar.gz" \
  --pattern SHA256SUMS
cmp "$DOCS_ARCHIVE/SHA256SUMS" "$download/SHA256SUMS"
(cd "$download" && sha256sum --check SHA256SUMS)
gh pr edit "$pr" --repo lambdasistemi/singular \
  --remove-label 'autorelease: pending' --add-label 'autorelease: tagged'
