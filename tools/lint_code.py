#!/usr/bin/env python3
"""Lint and format every non-Haskell, non-Aiken code family (issue #278).

The extent is the code inventory's own: this tool asks tools/code_inventory.py
to discover and classify the tree, so every file the inventory maps to a code
family is checked here or by a named carrier elsewhere, and a family nobody
checks fails the run instead of passing silently. There is no file list.

Families and their checkers (pinned by the root development shell):

  nix            nixfmt (format), statix and deadnix (lint), and the
                 Conformance flake lock held byte-equal to the off-chain lock
  python         ruff format (format), ruff check (lint)
  shell          shfmt -i 2 -ci -bn (format), shellcheck (lint)
  javascript,css biome check: formatter and recommended lint rules,
                 warnings are errors (configuration: biome.json)
  just           just --fmt (format); a justfile that does not parse fails it
  workflow-yaml  yamlfmt (format), actionlint with shellcheck (lint)
  lean, html     explicit style rules, because no general formatter exists:
                 no tab, no carriage return, no trailing whitespace, exactly
                 one final newline

Carried elsewhere: haskell (Fourmolu and HLint: `just format-check`, the
offchain lint app and the Conformance format and HLint apps) and aiken
(`aiken fmt --check` and `aiken check` in the onchain and naming-onchain
flake checks). Generated rows are held by their generators' freshness checks
and are skipped here, except that generated Lean mirrors must still meet the
Lean style rules.

Usage:
  python3 tools/lint_code.py check [FAMILY ...]
  python3 tools/lint_code.py fix [FAMILY ...]

Exit codes: 0 clean; 1 findings; 2 usage or environment error.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True  # a Git-free tree would see the cache as source
sys.path.insert(0, str(Path(__file__).resolve().parent))
import code_inventory  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent

ELSEWHERE = {
    "haskell": "Fourmolu and HLint carriers (just format-check, offchain "
    "nix run .#lint, conformance nix run .#format-check / .#hlint-check)",
    "aiken": "aiken fmt --check and aiken check in the onchain and "
    "naming-onchain flake checks",
}

SHFMT = ["shfmt", "-i", "2", "-ci", "-bn"]

ACTIONLINT_CONFIG = "self-hosted-runner:\n  labels: [nixos]\n"


def discover() -> dict[str, list[dict]]:
    manifests = code_inventory.parse_manifests(ROOT)
    files, _context = code_inventory.walk_tree(ROOT)
    rows, findings = code_inventory.classify(ROOT, files, manifests)
    if findings:
        for f in findings:
            print(f"lint: unmapped file — {f.render()}", file=sys.stderr)
        raise SystemExit("lint: the inventory is incomplete; run just inventory")
    families: dict[str, list[dict]] = {}
    for r in rows:
        if r["kind"] == "code":
            families.setdefault(r["family"], []).append(r)
    return families


def run(cmd: list[str]) -> bool:
    print("+ " + " ".join(cmd[:4]) + (" ..." if len(cmd) > 4 else ""), flush=True)
    return subprocess.run(cmd, cwd=ROOT).returncode == 0


def each(cmd: list[str], paths: list[str]) -> bool:
    ok = True
    for p in paths:
        ok &= run(cmd + [p])
    return ok


def style_rules(paths: list[str]) -> bool:
    ok = True
    for p in paths:
        data = (ROOT / p).read_bytes()
        problems = []
        if not data:
            problems.append("empty file")
        if b"\t" in data:
            problems.append("tab character")
        if b"\r" in data:
            problems.append("carriage return")
        lines = data.split(b"\n")
        for n, line in enumerate(lines[:-1], 1):
            if line != line.rstrip(b" \t"):
                problems.append(f"trailing whitespace at line {n}")
                break
        if data and not data.endswith(b"\n"):
            problems.append("missing final newline")
        if data.endswith(b"\n\n"):
            problems.append("blank lines at end of file")
        for msg in problems:
            print(f"style: {p}: {msg}", file=sys.stderr)
        ok &= not problems
    return ok


# The Conformance flake declares the off-chain flake's inputs verbatim and
# carries a byte copy of its lock (conformance/flake.nix), so both trees
# resolve one dependency graph. Merging the two flakes would rewrite both
# locks; instead the copy is held equal here, so the duplicate cannot drift.
LOCK_PAIRS = [("offchain/flake.lock", "conformance/flake.lock")]


def lock_parity() -> bool:
    ok = True
    for canonical, copy in LOCK_PAIRS:
        if (ROOT / canonical).read_bytes() != (ROOT / copy).read_bytes():
            print(f"nix: {copy} differs from {canonical}", file=sys.stderr)
            ok = False
    return ok


def nix(paths: list[str], fix: bool) -> bool:
    if fix:
        ok = run(["deadnix", "--edit", *paths])
        ok &= each(["statix", "fix"], paths)
        return ok & run(["nixfmt", *paths])
    ok = run(["nixfmt", "--check", *paths])
    ok &= each(["statix", "check"], paths)
    ok &= run(["deadnix", "--fail", *paths])
    return ok & lock_parity()


def python(paths: list[str], fix: bool) -> bool:
    if fix:
        return run(["ruff", "check", "--no-cache", "--fix", *paths]) & run(
            ["ruff", "format", "--no-cache", *paths]
        )
    return run(["ruff", "check", "--no-cache", *paths]) & run(
        ["ruff", "format", "--no-cache", "--check", *paths]
    )


def shell(paths: list[str], fix: bool) -> bool:
    if fix:
        return run([*SHFMT, "-w", *paths])
    return run(["shellcheck", *paths]) & run([*SHFMT, "-d", *paths])


def web(paths: list[str], fix: bool) -> bool:
    if fix:
        return run(["biome", "check", "--write", *paths])
    return run(
        ["biome", "check", "--error-on-warnings", "--diagnostic-level=warn", *paths]
    )


def just(paths: list[str], fix: bool) -> bool:
    base = ["just", "--unstable", "--fmt"] + ([] if fix else ["--check"])
    return all([run(base + ["--justfile", p]) for p in paths])


def workflows(paths: list[str], fix: bool) -> bool:
    if fix:
        return run(["yamlfmt", *paths])
    with tempfile.TemporaryDirectory() as tmp:
        config = Path(tmp) / "actionlint.yaml"
        config.write_text(ACTIONLINT_CONFIG)
        ok = run(["actionlint", "-config-file", str(config), *paths])
    return ok & run(["yamlfmt", "-lint", *paths])


def styled(paths: list[str], fix: bool) -> bool:
    if fix:
        print("style: no automatic fix; edit the reported lines", file=sys.stderr)
    return style_rules(paths)


CHECKERS = {
    "nix": nix,
    "python": python,
    "shell": shell,
    "javascript": web,
    "css": web,
    "just": just,
    "workflow-yaml": workflows,
    "lean": styled,
    "html": styled,
}

TOOLS = [
    "nixfmt",
    "statix",
    "deadnix",
    "ruff",
    "shellcheck",
    "shfmt",
    "biome",
    "just",
    "actionlint",
    "yamlfmt",
]


def main(argv: list[str]) -> int:
    if not argv or argv[0] not in ("check", "fix"):
        print(__doc__, file=sys.stderr)
        return 2
    fix = argv[0] == "fix"
    wanted = set(argv[1:])
    missing = [t for t in TOOLS if shutil.which(t) is None]
    if missing:
        print(f"lint: missing tools {missing}; run inside nix develop", file=sys.stderr)
        return 2
    families = discover()
    unknown = sorted(set(families) - set(CHECKERS) - set(ELSEWHERE))
    if unknown:
        print(f"lint: code families with no checker: {unknown}", file=sys.stderr)
        return 1
    bad = sorted(wanted - set(CHECKERS) - set(ELSEWHERE))
    if bad:
        print(f"lint: unknown families requested: {bad}", file=sys.stderr)
        return 2
    ok = True
    groups: dict[object, list[str]] = {}
    for family in sorted(families):
        if family in ELSEWHERE:
            print(
                f"lint: {family}: {len(families[family])} files, carried by "
                f"{ELSEWHERE[family]}"
            )
            continue
        if wanted and family not in wanted:
            continue
        rows = families[family]
        paths = sorted(
            r["path"] for r in rows if not r["generated"] or family == "lean"
        )
        print(
            f"lint: {family}: {len(paths)} files "
            f"({len(rows) - len(paths)} generated files skipped, held by their generators)"
        )
        groups.setdefault(CHECKERS[family], []).extend(paths)
    for checker, paths in groups.items():
        if paths:
            ok &= checker(sorted(paths), fix)
    print("lint: PASS" if ok else "lint: FAILED")
    return 0 if ok else 1


if __name__ == "__main__":
    os.environ.setdefault("NO_COLOR", "1")
    sys.exit(main(sys.argv[1:]))
