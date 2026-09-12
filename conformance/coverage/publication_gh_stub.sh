#!/usr/bin/env bash
# Local double for the upload boundary in the publication-boundary
# control (issue #80 slice t80c, NOTE-022). Ported from the gh half of
# tools/check_publish.py's mock: bash plus coreutils only, so no network
# syscall is possible by construction — review this file to verify that.
#
# `release view` reports absent so the create+upload path is always
# exercised; `release download` materializes real local copies from
# DOCS_ARCHIVE so downstream checksum verification is real. Every call is
# appended to $GH_CALLS_LOG (required in the environment).
set -u
echo "GHCALL: $*" >> "$GH_CALLS_LOG"
if [ "$1" = release ] && [ "$2" = view ]; then exit 1; fi
if [ "$1" = release ] && [ "$2" = download ]; then
  dest=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = --dir ]; then dest="$2"; shift 2; else shift; fi
  done
  cp "$DOCS_ARCHIVE"/* "$dest"/
  exit 0
fi
if [ "$1" = pr ] && [ "$2" = list ]; then
  echo "[{\"number\":${PUB_PR_NUMBER:-42},\"mergeCommit\":{\"oid\":\"${PUB_PR_SHA:?}\"},\"headRefName\":\"release-please--branches--main\",\"labels\":[{\"name\":\"autorelease: pending\"}]}]"
  exit 0
fi
exit 0