"""Candidate-binding integration control: the release command against real Git.

No monkeypatching anywhere in this file: a temporary repository exercises
the publication boundary end to end. A clean tree at the exact candidate
proceeds past binding; a modified tracked input is rejected specifically
as a candidate-tree mismatch (binding runs before any debt computation,
so the reason is isolated); a nested root and a non-repository root are
rejected as unestablishable identity. Skipped where git is unavailable —
run with git on PATH (e.g. `nix shell nixpkgs#python3 nixpkgs#git`).
"""

from __future__ import annotations

import io
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from singular_coverage.gate import main
from singular_coverage.inventory import build_inventory
from singular_coverage.record import candidate_digest
from tests.fixtures import NAMING_STUBS, STATEMENTS, export_manifests

GIT = shutil.which("git")


def git(repo, *args):
    subprocess.run(["git", *args], cwd=repo, check=True,
                   capture_output=True, text=True, timeout=60)


def build_sufficient_tree(tree):
    """A five-obligation tree with one mapping and two distinct valid
    layers per obligation: enough for COMPLETE, so a clean run proves the
    probe passed binding (binding failure would exit 3 first). Commits the
    real tools/check_model.py bytes too: the release machinery binds the
    extraction tool from the candidate, so the fixture must carry it."""
    import shutil

    from tests.fixtures import REPO_ROOT

    (tree / "lean/Singular").mkdir(parents=True)
    (tree / "lean/Singular/Statements.lean").write_text(STATEMENTS)
    for rel, text in NAMING_STUBS.items():
        (tree / rel).write_text(text)
    (tree / "tools").mkdir(parents=True, exist_ok=True)
    shutil.copy(REPO_ROOT / "tools/check_model.py", tree / "tools/check_model.py")
    export_manifests(tree)
    obligations = build_inventory(tree).obligations
    assert len(obligations) == 5
    paths = ["lean/Singular/Statements.lean"]
    candidate = candidate_digest(tree, paths)

    def check(obligation, digest, layer, execution, check_id):
        return {
            "checkId": check_id,
            "obligation": obligation,
            "statementSha256": digest,
            "layer": layer,
            "executionIdentity": execution,
            "entryPoints": ["src/Synth.hs:f"],
            "definitionDigests": {},
            "evidence": {
                "status": "pass",
                "candidateDigest": candidate,
                "candidatePaths": paths,
                "command": "nix run .#synth-check",
                "seed": "11",
                "cases": 64,
                "discards": 1,
                "thenAssertions": 3,
                "resultDigest": "c" * 64,
            },
            "control": {"kind": "mutation", "target": "Synth.f", "status": "valid"},
        }

    record = {
        "schema": "singular-coverage-record-v1",
        "checks": [
            check(o.name, o.statementSha256, layer, f"exec-synth-{o.name}-{layer}",
                  f"C-synth-{o.name}-{layer}")
            for o in obligations
            for layer in ("property", "integration-story")
        ],
        "mappings": [{
            "obligation": o.name,
            "statementSha256": o.statementSha256,
            "storyId": f"SYNTH-{o.name}",
            "clauses": {"then": ["x"]},
            "vocabulary": {},
        } for o in obligations],
        "discoveredPopulation": sorted(build_inventory(tree).by_identity()),
    }
    path = tree / "conformance/coverage/record/record.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record))
    return path


@unittest.skipUnless(GIT, "git binary required for the binding control")
class ReleaseBindingTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.repo = Path(self._tmp.name) / "repo"
        self.repo.mkdir()
        self.record = build_sufficient_tree(self.repo)
        git(self.repo, "init", "-q")
        git(self.repo, "add", "-A")
        git(self.repo, "-c", "user.email=binding@t", "-c", "user.name=binding",
            "commit", "-qm", "sufficient fixture")
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo,
                             check=True, capture_output=True, text=True, timeout=60)
        self.head = out.stdout.strip()
        self.assertRegex(self.head, r"^[0-9a-f]{40}$")

    def tearDown(self):
        self._tmp.cleanup()

    def release(self, root, *argv):
        err = io.StringIO()
        with redirect_stderr(err):
            rc = main(["--root", str(root), "release", *argv])
        return rc, err.getvalue()

    def test_clean_tree_at_exact_candidate_proceeds_past_binding(self):
        rc, err = self.release(self.repo, "--candidate", self.head)
        self.assertEqual(rc, 0, f"a clean sufficient tree must pass; stderr: {err}")
        self.assertEqual(err, "")

    def test_committed_incomplete_record_still_refuses_as_debt(self):
        (self.repo / "conformance/coverage/record/record.json").write_text(
            json.dumps({"schema": "singular-coverage-record-v1",
                        "checks": [], "mappings": [],
                        "discoveredPopulation": sorted(
                            build_inventory(self.repo).by_identity())}))
        git(self.repo, "add", "-A")
        git(self.repo, "-c", "user.email=binding@t", "-c", "user.name=binding",
            "commit", "-qm", "insufficient record")
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo,
                             check=True, capture_output=True, text=True, timeout=60)
        rc, err = self.release(self.repo, "--candidate", out.stdout.strip())
        self.assertEqual(rc, 1, f"insufficient record must refuse as debt; stderr: {err}")

    def test_committed_symlink_at_canonical_path_fails_closed(self):
        # The canonical path is a committed symlink to a SUFFICIENT record
        # outside the candidate: HEAD and status are clean, but the bytes
        # are not candidate content. Must fail closed, not COMPLETE.
        external = Path(self._tmp.name) / "external-record.json"
        external.write_bytes(
            (self.repo / "conformance/coverage/record/record.json").read_bytes())
        target = self.repo / "conformance/coverage/record/record.json"
        target.unlink()
        target.symlink_to(external)
        git(self.repo, "add", "-A")
        git(self.repo, "-c", "user.email=binding@t", "-c", "user.name=binding",
            "commit", "-qm", "symlinked record")
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo,
                             check=True, capture_output=True, text=True, timeout=60)
        rc, err = self.release(self.repo, "--candidate", out.stdout.strip())
        self.assertEqual(rc, 3)
        self.assertIn("not a regular blob", err)

    def test_ignored_canonical_input_fails_closed(self):
        # The record is absent at the commit; a sufficient working-tree
        # file is git-ignored, so status stays clean. Ignored bytes must
        # not feed the verdict.
        git(self.repo, "rm", "-q", "conformance/coverage/record/record.json")
        (self.repo / ".gitignore").write_text(
            "conformance/coverage/record/record.json\n")
        git(self.repo, "add", "-A")
        git(self.repo, "-c", "user.email=binding@t", "-c", "user.name=binding",
            "commit", "-qm", "unrecorded candidate")
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo,
                             check=True, capture_output=True, text=True, timeout=60)
        rc, err = self.release(self.repo, "--candidate", out.stdout.strip())
        self.assertEqual(rc, 3)
        self.assertIn("not a single committed path", err)

    def test_parent_path_escape_in_candidate_paths_fails_closed(self):
        # A committed record naming inputs outside the candidate root must
        # fail closed, not crash and not read outside bytes.
        path = self.repo / "conformance/coverage/record/record.json"
        raw = json.loads(path.read_text())
        raw["checks"][0]["evidence"]["candidatePaths"] = ["../../outside-escape"]
        path.write_text(json.dumps(raw))
        git(self.repo, "add", "-A")
        git(self.repo, "-c", "user.email=binding@t", "-c", "user.name=binding",
            "commit", "-qm", "escaping record")
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo,
                             check=True, capture_output=True, text=True, timeout=60)
        rc, err = self.release(self.repo, "--candidate", out.stdout.strip())
        self.assertEqual(rc, 3)
        self.assertIn("escapes the candidate root", err)

    def test_external_complete_substitution_refused_as_unbound_input(self):
        # The committed record is INCOMPLETE (empty); a sufficient record
        # smuggled via --record must not authorize publication.
        external = Path(self._tmp.name) / "external-record.json"
        external.write_bytes(
            (self.repo / "conformance/coverage/record/record.json").read_bytes())
        (self.repo / "conformance/coverage/record/record.json").write_text(
            json.dumps({"schema": "singular-coverage-record-v1",
                        "checks": [], "mappings": []}))
        git(self.repo, "add", "-A")
        git(self.repo, "-c", "user.email=binding@t", "-c", "user.name=binding",
            "commit", "-qm", "insufficient record")
        out = subprocess.run(["git", "rev-parse", "HEAD"], cwd=self.repo,
                             check=True, capture_output=True, text=True, timeout=60)
        rc, err = self.release(self.repo, "--record", str(external),
                               "--candidate", out.stdout.strip())
        self.assertEqual(rc, 3)
        self.assertIn("unbound release input", err)

    def test_wrong_candidate_rejected_as_mismatch(self):
        rc, err = self.release(self.repo, "--candidate", "0" * 40)
        self.assertEqual(rc, 3)
        self.assertIn("candidate mismatch", err)

    def test_dirty_tracked_input_rejected_as_tree_mismatch(self):
        target = self.repo / "lean/Singular/Statements.lean"
        with target.open("a") as fh:
            fh.write("\n-- binding control: tracked modification, HEAD unchanged\n")
        rc, err = self.release(self.repo, "--candidate", self.head)
        self.assertEqual(rc, 3)
        self.assertIn("candidate-tree mismatch", err)

    def test_nested_root_rejected_as_root_mismatch(self):
        rc, err = self.release(self.repo / "lean", "--candidate", self.head)
        self.assertEqual(rc, 3)
        self.assertIn("candidate root mismatch", err)

    def test_non_repository_root_rejected_as_unknown(self):
        outside = Path(self._tmp.name) / "not-a-repo"
        outside.mkdir()
        rc, err = self.release(outside, "--candidate", self.head)
        self.assertEqual(rc, 3)
        self.assertIn("candidate identity unknown", err)


if __name__ == "__main__":
    unittest.main()
