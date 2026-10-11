#!/usr/bin/env python3
"""Inspect a compiled Nix executable and its actual registry-cli build flags."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inspect(binary, harness):
    binary = binary.resolve(strict=True)
    if binary.read_bytes()[:4] != b"\x7fELF":
        raise ValueError(f"{binary} is not the compiled ELF executable")
    output = binary.parent.parent
    deriver = subprocess.check_output(
        ["nix-store", "--query", "--deriver", str(output)], text=True
    ).strip()
    graph = json.loads(
        subprocess.check_output(
            ["nix", "derivation", "show", "--recursive", deriver], text=True
        )
    )
    builds = []
    for drv, value in graph.items():
        env = value.get("env", {})
        if not env.get("name", "").startswith("singular-registry-lib-registry-cli-"):
            continue
        phase = env["configurePhase"]
        # These are configure arguments in the resolved component's actual
        # builder, not a hand-written ordinary/test label beside the binary.
        flag_lines = [line for line in phase.splitlines() if "test-harness" in line]
        builds.append(
            {
                "derivation": drv,
                "outputs": value["outputs"],
                "configure_phase_sha256": hashlib.sha256(phase.encode()).hexdigest(),
                "flag_lines": flag_lines,
            }
        )
    if len(builds) != 1:
        raise ValueError(
            f"expected one resolved registry-cli component, found {len(builds)}"
        )
    with tempfile.TemporaryDirectory(prefix="release-binary-") as temporary:
        stripped = Path(temporary) / binary.name
        shutil.copyfile(binary, stripped)
        stripped.chmod(0o700)
        subprocess.run(["strip", "--strip-all", str(stripped)], check=True)
        hooks = sorted(
            {
                name.decode()
                for name in re.findall(
                    rb"SINGULAR_HARNESS_[A-Z_]+", stripped.read_bytes()
                )
            }
        )
        result = {
            "binary": str(binary),
            "sha256": digest(binary),
            "stripped_sha256": digest(stripped),
            "strip": shutil.which("strip"),
            "hooks": hooks,
            "registry_cli": builds[0],
        }
    print(json.dumps(result, sort_keys=True))
    expected = "test-harness" if harness else "-test-harness"
    actual = builds[0]["flag_lines"]
    required = f"echo --flags={expected} >> $configFiles/configure-flags"
    if not harness and hooks:
        raise ValueError("stripped executable contains " + ", ".join(hooks))
    if actual != [required]:
        raise ValueError(
            f"actual registry-cli flag must be {expected}; configuration is {actual}"
        )
    if harness and not hooks:
        raise ValueError("the explicit test build contains no harness inputs")
    return expected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--test-harness", action="store_true")
    args = parser.parse_args()
    try:
        flag = inspect(args.binary, args.test_harness)
        print(
            f"release-binary: PASS: compiled bytes and actual registry-cli flag {flag}"
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"release-binary: REFUSED: {error}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
