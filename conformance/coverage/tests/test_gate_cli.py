"""CLI-level controls: exit codes are the gate contract, the two results are
reported distinctly, and the completion gate never defaults to passing."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from singular_coverage.gate import main
from tests.fixtures import build_base_tree


class GateCliTest(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.tree = Path(self._tmp.name)
        build_base_tree(self.tree)

    def tearDown(self):
        self._tmp.cleanup()

    def gate(self, *argv):
        return main(["--root", str(self.tree), *argv])

    def test_inventory_exit_zero_and_counts(self):
        report = self.tree / "inventory.json"
        rc = self.gate("inventory", "--report", str(report))
        self.assertEqual(rc, 0)
        payload = json.loads(report.read_text())
        self.assertEqual(payload["inventory"]["total"], 8)
        self.assertEqual(payload["inventory"]["manifestBound"], 5)
        self.assertEqual(payload["inventory"]["unclassified"], 3)

    def test_ratchet_passes_when_nothing_changed(self):
        from tests.fixtures import write_record

        empty = {"schema": "singular-coverage-record-v1", "checks": [], "mappings": []}
        write_record(self.tree, empty, "record.json")
        write_record(self.tree, empty, "base.json")
        self.assertEqual(self.gate("ratchet", "--record", str(self.tree / "record.json"),
                                   "--reference", str(self.tree / "base.json")), 0)

    def test_completion_is_incomplete_at_nonzero_debt_and_exits_nonzero(self):
        from tests.fixtures import write_record

        empty = {"schema": "singular-coverage-record-v1", "checks": [], "mappings": []}
        write_record(self.tree, empty, "record.json")
        rc = self.gate("completion", "--record", str(self.tree / "record.json"),
                       "--report", str(self.tree / "completion.json"))
        self.assertEqual(rc, 1, "strict completion must not pass a nonzero baseline")
        payload = json.loads((self.tree / "completion.json").read_text())
        self.assertEqual(payload["verdict"], "INCOMPLETE")
        self.assertEqual(len(payload["unclassified"]), 3)

    def test_expect_incomplete_asserts_the_honest_baseline(self):
        from tests.fixtures import write_record

        empty = {"schema": "singular-coverage-record-v1", "checks": [], "mappings": []}
        write_record(self.tree, empty, "record.json")
        self.assertEqual(self.gate("completion", "--record", str(self.tree / "record.json"),
                                   "--expect", "INCOMPLETE"), 0)

    def test_expect_complete_fails_while_debt_is_nonzero(self):
        from tests.fixtures import write_record

        empty = {"schema": "singular-coverage-record-v1", "checks": [], "mappings": []}
        write_record(self.tree, empty, "record.json")
        self.assertEqual(self.gate("completion", "--record", str(self.tree / "record.json"),
                                   "--expect", "COMPLETE"), 4,
                         "claiming completion without zero debt must be impossible")

    def test_lying_population_fails_closed(self):
        from tests.fixtures import write_record

        empty = {"schema": "singular-coverage-record-v1", "checks": [], "mappings": [],
                 "discoveredPopulation": ["Singular.Statements.greeter_iff@" + "0" * 64]}
        write_record(self.tree, empty, "record.json")
        rc = self.gate("ratchet", "--record", str(self.tree / "record.json"),
                       "--reference", str(self.tree / "record.json"))
        self.assertEqual(rc, 3, "a record claiming a population discovery refutes fails closed")

    def test_ratchet_reports_regression_distinctly(self):
        from singular_coverage.inventory import build_inventory

        population = sorted(build_inventory(self.tree).by_identity())
        base = {"schema": "singular-coverage-record-v1", "checks": [], "mappings": [
            {"obligation": "Singular.Statements.greeter_iff", "statementSha256":
             json.loads((self.tree / "lean/theorem-debt.json").read_text())[0]["statementSha256"],
             "storyId": "S-1", "clauses": {"then": ["x"]}, "vocabulary": {}},
        ], "discoveredPopulation": population}
        (self.tree / "base.json").write_text(json.dumps(base))
        (self.tree / "current.json").write_text(json.dumps(
            {"schema": "singular-coverage-record-v1", "checks": [], "mappings": [],
             "discoveredPopulation": population}))
        rc = main(["--root", str(self.tree), "ratchet",
                   "--record", str(self.tree / "current.json"),
                   "--reference", str(self.tree / "base.json")])
        self.assertEqual(rc, 2, "regression exit code must differ from fail-closed and ok")

    def test_unknown_row_fails_closed_distinctly(self):
        from singular_coverage.inventory import build_inventory

        current = {"schema": "singular-coverage-record-v1", "checks": [], "mappings": [
            {"obligation": "Singular.Statements.nonexistent_row", "statementSha256": "a" * 64,
             "storyId": "S-9", "clauses": {"then": ["x"]}, "vocabulary": {}},
        ], "discoveredPopulation": sorted(build_inventory(self.tree).by_identity())}
        (self.tree / "current.json").write_text(json.dumps(current))
        rc = main(["--root", str(self.tree), "ratchet",
                   "--record", str(self.tree / "current.json"),
                   "--reference", str(self.tree / "current.json")])
        self.assertEqual(rc, 3, "unrecognized rows fail closed, not as regression")

    def test_fail_closed_on_drifted_manifest(self):
        manifest_path = self.tree / "lean/theorem-debt.json"
        manifest = json.loads(manifest_path.read_text())
        manifest[0]["statementSha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        self.assertEqual(self.gate("inventory"), 3)
        self.assertEqual(self.gate("ratchet"), 3)
        self.assertEqual(self.gate("completion"), 3)


if __name__ == "__main__":
    unittest.main()
