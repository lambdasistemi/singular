"""Release-boundary controls: the `release` command refuses (nonzero) on honest
debt, on every fail-closed absence, on candidate mismatch, on unbound
release inputs and on checker crashes — each labelled distinctly — and only
a COMPLETE verdict for the declared candidate exits 0.

The record that authorizes publication is resolved from the candidate
root, never from `--record` (which `release` refuses) and never from the
tool closure. Binding is stubbed in this file; the debt verdicts run
against real fixture trees through the real inventory/record/debt code.
The COMPLETE fixture is a synthetic five-obligation tree proving the
exit-0 path is reachable — it represents no project state.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from singular_coverage.gate import CandidateBinding, main
from tests.fixtures import build_base_tree, export_manifests, identity_of, mapping_row

RECORD_REL = Path("conformance/coverage/record/record.json")
"""Authoritative record path under the candidate root."""


def write_tree_record(tree, record):
    """Write a record dict to the candidate-root authoritative path."""
    path = tree / RECORD_REL
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record))
    return path


HEAD = "f" * 40
OTHER = "e" * 40


def patched_binding(bind=True):
    """Stub the binding seam: True binds clean, 'mismatch' refuses."""
    if bind is True:
        binding = CandidateBinding(True, "bound")
    else:
        binding = CandidateBinding(
            False, "candidate mismatch: checked-out h is not claimed c"
        )
    return patch("singular_coverage.gate.check_candidate_binding", return_value=binding)


def run_release(tree, *argv, bind=True):
    """release against tmp-tree record paths with binding stubbed; returns (rc, err)."""
    stub = patched_binding(bind)
    err = io.StringIO()
    with stub, redirect_stderr(err):
        rc = main(["--root", str(tree), "release", *argv])
    return rc, err.getvalue()


class ReleaseGateTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tree = Path(self._tmp.name)
        build_base_tree(self.tree)

    def tearDown(self):
        self._tmp.cleanup()

    def empty_record(self):
        from tests.fixtures import write_record

        empty = {"schema": "singular-coverage-record-v1", "checks": [], "mappings": []}
        write_record(self.tree, empty)
        return write_tree_record(self.tree, empty)

    def test_release_refuses_honest_debt(self):
        self.empty_record()
        report = self.tree / "release.json"
        rc, err = run_release(self.tree, "--candidate", HEAD, "--report", str(report))
        self.assertEqual(rc, 1, "honest nonzero debt must refuse the release")
        payload = json.loads(report.read_text())
        self.assertEqual(payload["verdict"], "INCOMPLETE")
        self.assertEqual(payload["command"], "release")
        self.assertEqual(payload["candidate"], HEAD)
        self.assertEqual(payload["binding"], "bound")
        self.assertEqual(err, "")

    def test_release_candidate_mismatch_refuses(self):
        self.empty_record()
        rc, err = run_release(self.tree,
                              "--candidate", OTHER, bind="mismatch")
        self.assertEqual(rc, 3, "a run not bound to its candidate must fail closed")
        self.assertIn("FAIL-CLOSED candidate", err)

    def test_release_record_override_refused_as_unbound_input(self):
        self.empty_record()
        outside = Path(self._tmp.name) / "external-record.json"
        outside.write_text("{}")
        rc, err = run_release(self.tree, "--record", str(outside),
                              "--candidate", HEAD)
        self.assertEqual(rc, 3, "release must not accept --record")
        self.assertIn("unbound release input", err)

    def test_release_without_git_refuses(self):
        # No stubs: a tree that is not inside a repository cannot bind a
        # candidate at all. Uses the real git calls, which fail outside repos.
        self.empty_record()
        err = io.StringIO()
        with redirect_stderr(err):
            rc = main(["--root", str(self.tree), "release", "--candidate", HEAD])
        self.assertEqual(rc, 3)
        self.assertIn("candidate identity unknown", err.getvalue())

    def test_release_missing_inventory_refuses(self):
        import shutil

        shutil.rmtree(self.tree / "lean")
        write_tree_record(self.tree, {"schema": "singular-coverage-record-v1",
                                       "checks": [], "mappings": []})
        # binding stubbed clean so the probe reaches the inventory step.
        rc, err = run_release(self.tree, "--candidate", HEAD)
        self.assertEqual(rc, 3, "missing inventory must fail closed, not refuse as debt")
        self.assertIn("FAIL-CLOSED", err)

    def test_release_malformed_evidence_refuses(self):
        from singular_coverage.inventory import build_inventory

        obligation = build_inventory(self.tree).obligations[0]
        row = {
            "checkId": "C-broken",
            "obligation": obligation.name,
            "statementSha256": obligation.statementSha256,
            "layer": "property",
            "executionIdentity": "exec-broken",
            "entryPoints": ["src/X.hs:f"],
            "definitionDigests": {},
            "evidence": {"status": "pass"},
            "control": {"kind": "mutation", "target": "X.f", "status": "valid"},
        }
        record = {"schema": "singular-coverage-record-v1", "checks": [row],
                  "mappings": [],
                  "discoveredPopulation": sorted(build_inventory(self.tree).by_identity())}
        write_tree_record(self.tree, record)
        rc, err = run_release(self.tree, "--candidate", HEAD)
        self.assertEqual(rc, 3, "evidence with absent fields must fail closed")
        self.assertIn("FAIL-CLOSED", err)

    def test_release_unexecuted_status_blocks_as_debt(self):
        from singular_coverage.inventory import build_inventory
        from singular_coverage.record import candidate_digest

        obligation = build_inventory(self.tree).obligations[0]
        paths = ["lean/Singular/Statements.lean"]
        row = {
            "checkId": "C-idle",
            "obligation": obligation.name,
            "statementSha256": obligation.statementSha256,
            "layer": "property",
            "executionIdentity": "exec-idle",
            "entryPoints": ["src/X.hs:f"],
            "definitionDigests": {},
            "evidence": {
                "status": "unexecuted",
                "candidateDigest": candidate_digest(self.tree, paths),
                "candidatePaths": paths,
                "command": "nix run .#example-check",
                "seed": "7",
                "cases": 10,
                "discards": 0,
                "thenAssertions": 1,
                "resultDigest": "b" * 64,
            },
            "control": {"kind": "mutation", "target": "X.f", "status": "valid"},
        }
        record = {"schema": "singular-coverage-record-v1", "checks": [row],
                  "mappings": [],
                  "discoveredPopulation": sorted(build_inventory(self.tree).by_identity())}
        write_tree_record(self.tree, record)
        report = self.tree / "release.json"
        rc, _ = run_release(self.tree, "--candidate", HEAD,
                            "--report", str(report))
        self.assertEqual(rc, 1, "absent execution blocks the release as honest debt")
        self.assertEqual(json.loads(report.read_text())["verdict"], "INCOMPLETE")

    def test_release_unknown_status_refuses(self):
        from singular_coverage.inventory import build_inventory
        from tests.fixtures import full_check

        row = full_check(self.tree, layer="property", execution="exec-mystery",
                         check_id="C-mystery", name="Singular.Statements.greeter_iff",
                         definition_digest="", candidate="0" * 64)
        row["evidence"]["status"] = "mystery"
        record = {"schema": "singular-coverage-record-v1", "checks": [row],
                  "mappings": [],
                  "discoveredPopulation": sorted(build_inventory(self.tree).by_identity())}
        write_tree_record(self.tree, record)
        rc, err = run_release(self.tree, "--candidate", HEAD)
        self.assertEqual(rc, 3, "an unknown evidence status must fail closed")
        self.assertIn("FAIL-CLOSED", err)

    def test_release_crash_is_neither_green_nor_incomplete(self):
        self.empty_record()
        report = self.tree / "release.json"
        with patch("singular_coverage.gate.build_inventory", side_effect=RuntimeError("boom")):
            rc, err = run_release(self.tree,
                                  "--candidate", HEAD, "--report", str(report))
        self.assertEqual(rc, 5, "an unexpected checker exception must exit CRASH")
        self.assertIn("CRASH", err)
        payload = json.loads(report.read_text())
        self.assertEqual(payload["verdict"], "CRASH")
        self.assertNotIn("INCOMPLETE", json.dumps(payload))

    def test_release_complete_passes_on_sufficient_mini_tree(self):
        """The exit-0 path is reachable: a synthetic tree whose every
        declaration is manifest-bound, with one mapping and two distinct
        valid layers per obligation, passes. This exercises the release
        verdict code, not project state: the tree holds only theorems (no
        definitions to bind, so checks carry empty definition digests),
        which real trees — whose checks bind real definitions pending
        mapping work — do not yet achieve."""
        from singular_coverage.inventory import build_inventory
        from singular_coverage.record import candidate_digest
        from tests.fixtures import NAMING_STUBS, STATEMENTS

        mini = Path(self._tmp.name) / "mini"
        (mini / "lean/Singular").mkdir(parents=True)
        (mini / "lean/Singular/Statements.lean").write_text(STATEMENTS)
        for rel, text in NAMING_STUBS.items():
            (mini / rel).write_text(text)
        export_manifests(mini)
        obligations = build_inventory(mini).obligations
        self.assertEqual(len(obligations), 5)
        self.assertEqual(
            [o for o in obligations if o.classification == "unclassified"],
            [],
        )
        paths = ["lean/Singular/Statements.lean"]
        candidate = candidate_digest(mini, paths)

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
            "discoveredPopulation": sorted(build_inventory(mini).by_identity()),
        }
        path = write_tree_record(mini, record)
        report = mini / "release.json"
        stub = patched_binding()
        err = io.StringIO()
        with stub, redirect_stderr(err):
            rc = main(["--root", str(mini), "release",
                       "--candidate", HEAD,
                       "--report", str(report)])
        self.assertEqual(rc, 0, "a sufficient tree must pass the release gate")
        self.assertEqual(json.loads(report.read_text())["verdict"], "COMPLETE")


if __name__ == "__main__":
    unittest.main()
