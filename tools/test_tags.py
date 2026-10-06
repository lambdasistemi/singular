#!/usr/bin/env python3
"""Check module wrappers in every Cabal-declared Hspec entrypoint.

This is a source inventory: compilation and Hspec runs separately establish
runtime paths and preservation of examples. No product behavior is inferred.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def fields(stanza: str) -> dict[str, str]:
    result = {}
    key = None
    for line in stanza.splitlines()[1:]:
        line = line.split("--", 1)[0]
        match = re.match(r"\s+([\w-]+):\s*(.*)", line)
        if match:
            key, value = match.groups()
            result[key] = value
        elif key and line.strip():
            result[key] += " " + line.strip()
    return result


def suites(root: Path):
    for cabal in sorted(root.rglob("*.cabal")):
        if any(
            part.startswith(".") or part == "dist-newstyle"
            for part in cabal.relative_to(root).parts
        ):
            continue
        text = cabal.read_text()
        for stanza in re.findall(
            r"^test-suite\s+[^\n]+\n(?:(?!^\S).*(?:\n|$))*", text, re.M
        ):
            config = fields(stanza)
            name = stanza.splitlines()[0].split()[1]
            if not re.search(r"\bhspec\b", config.get("build-depends", "")):
                print(
                    f"test-tags: excluded {cabal.relative_to(root)}:{name} (not Hspec)"
                )
                continue
            dirs = [
                cabal.parent / d
                for d in config["hs-source-dirs"].replace(",", " ").split()
            ]
            entry = next(
                (
                    d / config["main-is"]
                    for d in dirs
                    if (d / config["main-is"]).is_file()
                ),
                None,
            )
            if entry is None:
                raise ValueError(f"{name}: missing entrypoint")
            yield name, entry, dirs


def spec_functions(source: str) -> set[str]:
    return {
        name
        for name, signature in re.findall(
            r"^([a-z]\w*)\s*::\s*([^=]+?)(?=^\w+\s|\Z)", source, re.M
        )
        if re.search(r"\bSpec(?:With)?\b", signature)
    }


def check(root: Path) -> list[str]:
    problems = []
    tag_file = root / "offchain/test-tags/Test/Tags.hs"
    constructors = set()
    if tag_file.is_file():
        enum = re.search(
            r"data Area\s*=\s*(.*?)\s*deriving", tag_file.read_text(), re.S
        )
        if enum:
            constructors = set(re.findall(r"\b[A-Z]\w*\b", enum[1]))
    count = 0
    for name, entry, dirs in suites(root):
        count += 1
        source = entry.read_text()
        wrappers = list(
            re.finditer(r'describe\s*\(tagged\s+"([^"]+)"\s*\[([^\]]*)\]\)', source)
        )
        for wrapper in wrappers:
            tags = [t.strip() for t in wrapper[2].split(",") if t.strip()]
            if not tags:
                problems.append(f"{name}: empty tags for {wrapper[1]}")
            for tag in tags:
                if tag not in constructors:
                    problems.append(f"{name}: unknown tag {tag} for {wrapper[1]}")
        calls = []
        for imported in re.finditer(
            r"^import\s+([A-Z][\w.]*)\s*(qualified)?(?:\s+as\s+(\w+))?", source, re.M
        ):
            module, qualified, alias = imported.groups()
            module_file = next(
                (
                    d / (module.replace(".", "/") + ".hs")
                    for d in dirs
                    if (d / (module.replace(".", "/") + ".hs")).is_file()
                ),
                None,
            )
            if module_file is None:
                continue
            functions = spec_functions(module_file.read_text())
            prefix = re.escape(alias or module) + r"\." if qualified else ""
            for function in functions:
                # Imports precede all calls; exclude the import list itself.
                body_start = re.search(r"^main\s*::", source, re.M).start()
                for call in re.finditer(
                    r"\b" + prefix + re.escape(function) + r"\b", source[body_start:]
                ):
                    calls.append((body_start + call.start(), module, function))
        for offset, module, function in calls:
            previous = [
                w
                for w in wrappers
                if w.end() <= offset and not source[w.end() : offset].strip().strip("$")
            ]
            if not previous:
                problems.append(f"{name}: unwrapped {module}.{function}")
                continue
            label = previous[-1][1]
            expected = module.removesuffix("Spec")
            if label != expected:
                problems.append(
                    f"{name}: wrong module label {label}, expected {expected}"
                )
        if re.search(r"\bit\s+\"", source) and not wrappers:
            problems.append(
                f"{name}: unwrapped inline examples in {entry.relative_to(root)}"
            )
        if not calls and not re.search(r"\bit\s+\"", source):
            problems.append(f"{name}: empty discovered spec extent")
        print(f"test-tags: {name}: {len(calls)} spec calls, {len(wrappers)} wrappers")
    if not count:
        problems.append("no Hspec suites discovered")
    return problems


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path("."))
    args = parser.parse_args()
    problems = check(args.root.resolve())
    for problem in problems:
        print(f"test-tags: {problem}")
    print(f"test-tags: {'FAIL' if problems else 'PASS'} ({len(problems)} findings)")
    return int(bool(problems))


if __name__ == "__main__":
    raise SystemExit(main())
