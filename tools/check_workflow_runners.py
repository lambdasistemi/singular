"""Every workflow job runs on a runner the repository allows (#695).

Jobs run on the self-hosted `nixos` runner, which carries Nix and the binary
cache. Three workflows may also use a GitHub-hosted runner, each for a reason:
the release bundles are built and tested on the platform they are for, and
macOS is not a machine the self-hosted runner can be; the release workflow
runs the published macOS bundle on macOS; the Cabal version sync only edits
a file and pushes a commit. A job that calls a workflow of this
repository has no runner of its own.

usage: check_workflow_runners.py ROOT     check the workflows under ROOT
       check_workflow_runners.py --selftest
"""

import sys
from pathlib import Path

import yaml

SELF_HOSTED = "nixos"
HOSTED = {
    "release-bundles.yml": {"ubuntu-24.04", "macos-15"},
    "release.yml": {"macos-15"},
    "sync-cabal-version.yml": {"ubuntu-24.04"},
}
MATRIX_RUNNER = "${{ matrix.runner }}"


def load(root: Path) -> dict:
    return {
        p.name: yaml.load(p.read_text(), Loader=yaml.BaseLoader)
        for p in sorted((root / ".github/workflows").glob("*.yml"))
    }


def violations(workflows: dict) -> list[str]:
    found = []
    for name, workflow in workflows.items():
        allowed = {SELF_HOSTED} | HOSTED.get(name, set())
        for job_name, job in workflow["jobs"].items():
            where = f"{name}: job {job_name}"
            if "uses" in job:
                if not job["uses"].startswith("./.github/workflows/"):
                    found.append(
                        f"{where} calls {job['uses']}, not a workflow of this repository"
                    )
                continue
            runner = job.get("runs-on")
            if runner == MATRIX_RUNNER:
                runners = {
                    entry.get("runner")
                    for entry in job.get("strategy", {})
                    .get("matrix", {})
                    .get("include", [])
                }
                if not runners:
                    found.append(f"{where} runs on a matrix that names no runner")
            else:
                runners = {runner}
            for each in sorted(r for r in runners if r not in allowed):
                found.append(f"{where} runs on {each}, allowed here: {sorted(allowed)}")
            # the self-hosted runner has Nix; only a hosted machine sets it up
            if name not in HOSTED and any(
                "dev-assets/setup-nix" in step.get("uses", "")
                for step in job.get("steps", [])
            ):
                found.append(f"{where} sets Nix up with dev-assets/setup-nix")
    return found


def selftest() -> None:
    good = {
        "ci.yml": {"jobs": {"a": {"runs-on": "nixos", "steps": []}}},
        "release-bundles.yml": {
            "jobs": {
                "b": {
                    "runs-on": MATRIX_RUNNER,
                    "strategy": {
                        "matrix": {
                            "include": [{"runner": "nixos"}, {"runner": "macos-15"}]
                        }
                    },
                },
                "c": {
                    "runs-on": "ubuntu-24.04",
                    "steps": [{"uses": "paolino/dev-assets/setup-nix@x"}],
                },
            }
        },
        "release.yml": {
            "jobs": {"d": {"uses": "./.github/workflows/release-bundles.yml"}}
        },
    }
    assert violations(good) == [], violations(good)
    planted = {
        "a hosted runner outside the allowed workflows": (
            {"ci.yml": {"jobs": {"a": {"runs-on": "ubuntu-24.04"}}}},
            "ci.yml: job a runs on ubuntu-24.04",
        ),
        "a runner the allowed workflow does not list": (
            {"release-bundles.yml": {"jobs": {"a": {"runs-on": "windows-2022"}}}},
            "runs on windows-2022",
        ),
        "a matrix runner that is not allowed": (
            {
                "release-bundles.yml": {
                    "jobs": {
                        "a": {
                            "runs-on": MATRIX_RUNNER,
                            "strategy": {
                                "matrix": {"include": [{"runner": "macos-14"}]}
                            },
                        }
                    }
                }
            },
            "runs on macos-14",
        ),
        "a call of another repository's workflow": (
            {
                "release.yml": {
                    "jobs": {"a": {"uses": "owner/repo/.github/workflows/x.yml@main"}}
                }
            },
            "not a workflow of this repository",
        ),
        "a job with no runner": (
            {"ci.yml": {"jobs": {"a": {"steps": []}}}},
            "runs on None",
        ),
        "the shared setup action": (
            {
                "ci.yml": {
                    "jobs": {
                        "a": {
                            "runs-on": "nixos",
                            "steps": [{"uses": "paolino/dev-assets/setup-nix@x"}],
                        }
                    }
                }
            },
            "dev-assets/setup-nix",
        ),
    }
    for label, (workflows, expected) in planted.items():
        found = violations(workflows)
        assert any(expected in line for line in found), (label, found)
        print(f"check-workflow-runners: {label} refused: {found[0]}")
    print("check-workflow-runners: selftest PASS")


def main() -> None:
    if sys.argv[1:] == ["--selftest"]:
        selftest()
        return
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    workflows = load(Path(sys.argv[1]))
    assert workflows, "no workflow found"
    found = violations(workflows)
    for line in found:
        print(f"check-workflow-runners: FAIL {line}")
    if found:
        raise SystemExit(1)
    jobs = sum(len(w["jobs"]) for w in workflows.values())
    print(f"check-workflow-runners: PASS {jobs} jobs in {len(workflows)} workflows")


if __name__ == "__main__":
    main()
