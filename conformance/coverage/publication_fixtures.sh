#!/usr/bin/env bash
# Repository-owned fixture construction for the publication-boundary
# control (issue #80 slice t80c, NOTE-022).
#
# Builds, under OUTDIR (default: a fresh mktemp dir):
#   sufficient/  five obligations with mappings plus two valid layers each,
#                the real extractor bytes, a minimal flake re-exporting the
#                PROVIDER repo's coverage-gate app (same closure as
#                production), and the release-required marker — all committed.
#   missing/     same content but the record absent at the commit with a
#                git-ignored working-tree copy (clean status), plus the
#                release-required marker — all committed.
# Prints SUFFICIENT_HEAD / MISSING_HEAD SHAs on stdout.
#
# Pinned runnable command (run from the provider checkout):
#   OUTDIR=/tmp/pub-fixtures \
#     conformance/coverage/publication_fixtures.sh
# PROVIDER defaults to the git top level enclosing this script; both are
# logged, and no other path is hardcoded.
set -u
PROVIDER="${PROVIDER:-$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)}"
OUTDIR="${OUTDIR:-$(mktemp -d -t pub-fixtures-XXXXXX)}"
mkdir -p "$OUTDIR"
echo "provider: $PROVIDER"
echo "outdir: $OUTDIR"

nix shell --quiet nixpkgs#python3 nixpkgs#git --command python3 - "$PROVIDER" "$OUTDIR" <<'PYEOF'
import subprocess, sys
from pathlib import Path

provider, outdir = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(provider / "conformance/coverage"))
from tests.test_release_binding import build_sufficient_tree


def git(repo, *args):
    subprocess.run(["git", *args], cwd=repo, check=True, capture_output=True)


def commit_all(repo, message):
    git(repo, "add", "-A")
    git(repo, "-c", "user.email=pub@t", "-c", "user.name=pub", "commit", "-qm", message)
    return subprocess.run(
        ["git", "rev-parse", "HEAD"], cwd=repo, check=True,
        capture_output=True, text=True).stdout.strip()


suff = outdir / "sufficient"
suff.mkdir(parents=True, exist_ok=True)
build_sufficient_tree(suff)
version = (provider / "version.txt").read_text().strip()
(suff / ".release-please-manifest.json").write_text('{\n  ".": "%s"\n}\n' % version)
(suff / "conformance/coverage/release-required").write_text("")
(suff / "flake.nix").write_text(
    '{\n'
    f'  inputs.main.url = "path:{provider}";\n'
    '  outputs = { self, main, ... }: {\n'
    '    apps.x86_64-linux.coverage-gate = main.apps.x86_64-linux.coverage-gate;\n'
    '  };\n'
    '}\n')
git(suff, "init", "-q")
git(suff, "add", "-A")
subprocess.run(["nix", "flake", "lock"], cwd=suff, check=True,
               capture_output=True)
suff_head = commit_all(suff, "sufficient fixture plus release-required")
print(f"SUFFICIENT_HEAD={suff_head}")
print(f"SUFFICIENT_TAG=v{version}")
git(suff, "tag", f"v{version}", suff_head)
git(suff, "update-ref", "refs/remotes/origin/main", suff_head)

miss = outdir / "missing"
miss.mkdir(parents=True, exist_ok=True)
build_sufficient_tree(miss)
(miss / "conformance/coverage/release-required").write_text("")
external_sufficient = (miss / "conformance/coverage/record/record.json").read_bytes()
(miss / "flake.nix").write_text((suff / "flake.nix").read_text())
git(miss, "init", "-q")
git(miss, "add", "-A")
subprocess.run(["nix", "flake", "lock"], cwd=miss, check=True,
               capture_output=True)
commit_all(miss, "base fixture")
git(miss, "rm", "-q", "conformance/coverage/record/record.json")
(miss / ".gitignore").write_text("conformance/coverage/record/record.json\n")
# Restore sufficient bytes on disk (ignored): the candidate lacks the
# record, the working tree still carries bytes that must not feed it.
miss_record = miss / "conformance/coverage/record/record.json"
miss_record.parent.mkdir(parents=True, exist_ok=True)
miss_record.write_bytes(external_sufficient)
miss_head = commit_all(miss, "unrecorded candidate plus release-required")
print(f"MISSING_HEAD={miss_head}")
PYEOF
