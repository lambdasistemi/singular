#!/usr/bin/env python3
"""The page checker must refuse a comparison with no carrying experiment.

Execute the real checker against the committed comparison, then remove only
the carrying receipt in a private copy. An unchanged page and valid creation
observations cannot substitute for this missing experiment.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

root = Path.cwd()
with tempfile.TemporaryDirectory(prefix="creation-carrying-") as directory:
    probe = Path(directory)
    shutil.copytree(
        root / "specs/745-shared-publications/evidence",
        probe / "specs/745-shared-publications/evidence",
    )
    (probe / "docs").mkdir()
    shutil.copyfile(root / "docs/creation-cost.md", probe / "docs/creation-cost.md")
    receipt = probe / "specs/745-shared-publications/evidence/carrying.json"
    receipt.unlink(missing_ok=True)
    answer = subprocess.run(
        [sys.executable, str(root / "tools/creation-cost.py"), "check"],
        cwd=probe,
        capture_output=True,
        text=True,
        check=False,
    )
    if answer.returncode == 0:
        sys.exit("creation-carrying: checker accepted a missing carrying experiment")
    if "carrying" not in answer.stderr.lower():
        sys.exit(
            "creation-carrying: another failure is not the missing-experiment control: "
            + answer.stderr
        )
    print(
        "creation-carrying: missing carrying experiment refused by the real page checker"
    )
