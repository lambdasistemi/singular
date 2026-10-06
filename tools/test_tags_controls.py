#!/usr/bin/env python3
"""Falsify the tag inventory using mutations of the discovered source tree."""

import contextlib
import io
import re
import tempfile
from pathlib import Path

from test_tags import check, suites


def quiet_check(root):
    with contextlib.redirect_stdout(io.StringIO()):
        return check(root)


def main():
    root = Path(__file__).resolve().parent.parent
    assert not quiet_check(root), "baseline tag inventory must pass"
    with tempfile.TemporaryDirectory() as directory:
        copy = Path(directory)
        # The inventory reads Cabal and Haskell only; generated trees are excluded.
        for pattern in ("*.cabal", "*.hs"):
            for source in root.rglob(pattern):
                relative = source.relative_to(root)
                if any(
                    p.startswith(".") or p == "dist-newstyle" for p in relative.parts
                ):
                    continue
                target = copy / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(source.read_bytes())
        assert not quiet_check(copy), "copied extent must pass"
        for name, entry, _ in suites(copy):
            original = entry.read_text()
            # Remove every wrapper in turn, including multiline formatter output.
            wrappers = list(
                re.finditer(
                    r'describe\s*\(\s*tagged\s+"[^\"]+"\s*\[[^\]]*\]\s*\)\s*\$?',
                    original,
                )
            )
            assert wrappers, name
            for wrapper in wrappers:
                entry.write_text(
                    original[: wrapper.start()] + original[wrapper.end() :]
                )
                problems = quiet_check(copy)
                assert any(
                    "unwrapped" in p and p.startswith(name + ":") for p in problems
                ), (name, problems)
            entry.write_text(original)
            for wrapper in wrappers:
                unknown = re.sub(r"\[[^\]]*\]", "[UnknownArea]", wrapper[0], count=1)
                entry.write_text(
                    original[: wrapper.start()] + unknown + original[wrapper.end() :]
                )
                problems = quiet_check(copy)
                assert any("unknown tag UnknownArea" in p for p in problems), (
                    name,
                    problems,
                )
            entry.write_text(original)
            print(
                f"test-tags controls: {name}: removed and unknown-tag mutations rejected ({len(wrappers)} each)"
            )
        assert not quiet_check(copy), "restored tree must pass"
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
