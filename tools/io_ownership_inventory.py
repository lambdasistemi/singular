#!/usr/bin/env python3
"""Haskell effect census (issue #544).

Every Haskell source the tree holds is discovered by walking it — no
per-file list anywhere in this tool — classified into exactly one
structural category (production, tool, conformance library, conformance
runner, test/harness, application), and scanned for the
effect classes below. Anything unclassified fails closed.

Effect classes are import-anchored: a class is reported only when the
file imports the module that provides it, so prose about an effect
("release_burns_atomically" is a theorem name, not STM) never counts.
A use-shaped token without its import is a separate finding, not a row:
it means the scanner, not the tree, is wrong, and the run fails until
the scanner is fixed.

Gated classes (each site needs a file-level entry in
tools/io-ownership.allow, checked by tools/io_ownership_check.sh):
  ioref    Data.IORef
  mvar     Control.Concurrent.MVar, or the whole Control.Concurrent import
           beside an MVar use token (newEmptyMVar in the MVar-based test
           coordinations) — GHC still requires one of the two imports
  stm      Control.Concurrent.STM / Control.Monad.STM
  unsafe   System.IO.Unsafe (unsafePerformIO and kin)
  fork     forkIO / forkFinally / forkOS / forkOn (no import anchors these;
           the tokens are code-only)
  async    Control.Concurrent.Async — import-anchored only. The combinator
           words (concurrently, withAsync, link, wait, cancel) all have
           prose readings in comments, so a token-anchored async class
           would flag sentences, not sites. GHC requires the import at
           every use site and no local module re-exports the Async API,
           so import-anchored detection is complete.

Informational classes (structural facts for the ownership guide; their
enforcing carriers live elsewhere, named in the report):
  timeout  System.Timeout — the #540 calling-thread bound; never a thread
  env      System.Environment / System.Posix.Env — explicit inputs at the
           composition boundary; hidden reads in release builds are #343's
  concurrent
           the whole Control.Concurrent import (threadDelay, myThreadId,
           throwTo) — naming the module without the gated primitives above

This census establishes structural facts, never runtime behavior: that a
file can name an effect says nothing about what it does with it. What a
command does is settled by the cage tests, the journeys and the hosted
runs named in docs/io-ownership.md, not here.

Usage:
  python3 tools/io_ownership_inventory.py [--root DIR] [--json]
  python3 tools/io_ownership_inventory.py --root DIR --sites > tools/io-ownership.sites

Exit codes: 0 census complete; 1 unclassified category or use-without-import
finding; 2 usage or environment error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Categories: ordered, first match wins. Every discovered .hs file must hit
# exactly one. A source that hits none is a finding, never a silent skip.
# ---------------------------------------------------------------------------

CATEGORIES: list[tuple[str, str, tuple[str, ...]]] = [
    # (category, description, path prefixes)
    (
        "production",
        "library code shipped in release builds",
        (
            "offchain/lib/",
            "offchain/naming/src/",
            "offchain/local-services/",
            "offchain/koios-http/src/",
            "offchain/cli/src/",
            "applications/open-datum/offchain/src/",
        ),
    ),
    (
        "tool",
        "standalone operator executables (devnet, recorders)",
        (
            "offchain/devnet/",
            "offchain/koios-http/app/",
            "offchain/app/",
            "offchain/cli/Main.hs",
            "applications/open-datum/offchain/app/",
        ),
    ),
    (
        "conformance-library",
        "the suite's library: programs, bindings, comparisons, receipts",
        ("conformance/lib/",),
    ),
    (
        "conformance-runner",
        "the live runner and its CLIs: effects live here, never in the library",
        (
            "conformance/app/",
            "conformance/app-cli/",
            "conformance/app-default/",
            "conformance/coverage/",
        ),
    ),
    (
        "test",
        "suites, fixtures and harness libraries owned by the test run",
        (
            "offchain/test/",
            "offchain/test-tags/",
            "offchain/contract-test/",
            "offchain/e2e-test/",
            "offchain/record-value-test/",
            "offchain/naming/test/",
            "offchain/naming/drift/",
            "offchain/signed-tx-control/",
            "offchain/private-facade/",
            "offchain/cli/test-harness/",
            "offchain/cli/ordinary/",
            "conformance/test/",
            "applications/open-datum/offchain/test/",
            "applications/open-datum/offchain/test-tags/",
            "applications/open-datum/offchain/refusals/",
        ),
    ),
]

SKIP_DIRS = frozenset(
    [".git", "dist-newstyle", "result", ".stack-work", "node_modules"]
)

# ---------------------------------------------------------------------------
# Effect classes.
# ---------------------------------------------------------------------------

# import-anchored classes: (class, (modules whose import reports it))
IMPORT_CLASSES: dict[str, tuple[str, ...]] = {
    "ioref": ("Data.IORef",),
    "mvar": ("Control.Concurrent.MVar",),
    "stm": ("Control.Concurrent.STM", "Control.Monad.STM"),
    "unsafe": ("System.IO.Unsafe",),
    "async": ("Control.Concurrent.Async",),
    "timeout": ("System.Timeout",),
    "env": ("System.Environment", "System.Posix.Env"),
}

# Whole-module import recorded informatively (threadDelay territory).
CONCURRENT_MODULE = "Control.Concurrent"

# Token-anchored classes: code-only tokens with no prose reading.
TOKEN_CLASSES: dict[str, tuple[str, ...]] = {
    "fork": ("forkIO", "forkFinally", "forkOS", "forkOn"),
    "unsafe": (
        "unsafePerformIO",
        "unsafeInterleaveIO",
        "unsafeDupablePerformIO",
        "unsafeDupableInterleaveIO",
    ),
    "stm": ("atomically", "newTVar", "newTMVar", "newTChan", "newTBQueue"),
}

# Tokens that need their import and are a scanner finding without it.
# Tokens that need their import and are a scanner finding without it.
# (class, tokens, modules that must anchor them)
#
# async is deliberately absent: every combinator word (withAsync,
# concurrently, link, wait, cancel) appears in prose comments, so a token
# backstop would fail files for sentences. The import anchor is complete
# because GHC requires it at each use site.
USE_NEEDS_IMPORT: dict[str, tuple[tuple[str, ...], tuple[str, ...]]] = {
    "ioref": (
        (
            "newIORef",
            "readIORef",
            "writeIORef",
            "modifyIORef",
            "atomicModifyIORef",
        ),
        ("Data.IORef",),
    ),
    "mvar": (
        (
            "newMVar",
            "newEmptyMVar",
            "putMVar",
            "takeMVar",
            "readMVar",
            "withMVar",
            "tryTakeMVar",
            "swapMVar",
            "modifyMVar",
        ),
        ("Control.Concurrent.MVar", "Control.Concurrent"),
    ),
}

GATED = ("ioref", "mvar", "stm", "unsafe", "fork", "async")


def _import_re(module: str) -> "re.Pattern[str]":
    return re.compile(
        r"^\s*import\s+(qualified\s+)?" + re.escape(module) + r"\b", re.MULTILINE
    )


IMPORT_RES: dict[str, list["re.Pattern[str]"]] = {
    cls: [_import_re(m) for m in mods] for cls, mods in IMPORT_CLASSES.items()
}
# An MVar site may also arrive through the whole Control.Concurrent import
# (newEmptyMVar in ProviderSpec/CommandRunSpec): the import plus a use token
# reports mvar, since GHC still requires one of the two imports at the site.
WHOLE_CONCURRENT_RES = [
    re.compile(
        r"^\s*import\s+(qualified\s+)?Control\.Concurrent\s*($|\(|hiding)",
        re.MULTILINE,
    ),
    re.compile(
        r"^\s*import\s+(qualified\s+)?Control\.Concurrent\s+as\s+\w+",
        re.MULTILINE,
    ),
]
CONCURRENT_RE = _import_re(CONCURRENT_MODULE)

# An exact whole-module Control.Concurrent import does not count when the
# import names a submodule (Control.Concurrent.Async etc.).
CONCURRENT_SUB_RE = re.compile(
    r"^\s*import\s+(qualified\s+)?Control\.Concurrent\.\w+", re.MULTILINE
)


def _token_re(token: str) -> "re.Pattern[str]":
    return re.compile(
        r"(?<![A-Za-z0-9_'])" + re.escape(token) + r"(?![A-Za-z0-9_'])", re.MULTILINE
    )


TOKEN_RES: dict[str, list["re.Pattern[str]"]] = {
    cls: [_token_re(t) for t in toks] for cls, toks in TOKEN_CLASSES.items()
}
USE_RES: dict[str, tuple[list["re.Pattern[str]"], list["re.Pattern[str]"]]] = {
    cls: ([_token_re(t) for t in toks], [_import_re(m) for m in mods])
    for cls, (toks, mods) in USE_NEEDS_IMPORT.items()
}


# ---------------------------------------------------------------------------
# Site binding (NOTE-001, NOTE-002): per-file per-function per-token
# occurrence counts over comment- and string-stripped sources. A new site of
# an already-allowed class in an already-allowed file changes a count with
# its imports untouched (NOTE-001); moving a site between functions changes
# the per-function counts with the file totals untouched (NOTE-002). The
# committed tools/io-ownership.sites file rejects both until regenerated,
# reviewed and committed beside the code change.
# bare `wait` is excluded: it is overwhelmingly a binder for a handle the
# same owned expression spawned, and the spawn token tripwires it.
# ---------------------------------------------------------------------------

SITE_TOKENS: dict[str, tuple[str, ...]] = {
    "ioref": (
        "IORef",
        "newIORef",
        "readIORef",
        "writeIORef",
        "modifyIORef",
        "modifyIORef'",
        "atomicModifyIORef",
        "atomicModifyIORef'",
    ),
    "mvar": (
        "MVar",
        "newMVar",
        "newEmptyMVar",
        "putMVar",
        "takeMVar",
        "readMVar",
        "withMVar",
        "tryTakeMVar",
        "tryPutMVar",
        "swapMVar",
        "modifyMVar",
        "modifyMVar_",
    ),
    "stm": (
        "atomically",
        "newTVar",
        "readTVar",
        "writeTVar",
        "newTMVar",
        "newTChan",
        "newTBQueue",
    ),
    "unsafe": (
        "unsafePerformIO",
        "unsafeInterleaveIO",
        "unsafeDupablePerformIO",
        "unsafeDupableInterleaveIO",
    ),
    "fork": ("forkIO", "forkFinally", "forkOS", "forkOn"),
    "async": (
        "async",
        "withAsync",
        "concurrently",
        "mapConcurrently",
        "mapConcurrently_",
        "race",
        "race_",
        "link",
        "waitCatch",
        "cancel",
    ),
}

SITE_RES: dict[str, list["re.Pattern[str]"]] = {
    cls: [_token_re(t) for t in toks] for cls, toks in SITE_TOKENS.items()
}


def strip_haskell(text: str) -> str:
    """Blank strings, chars and comments, preserving newlines.

    A single pass so a quote inside a comment never starts a string and a
    comment opener inside a string never starts a comment. Pragma blocks
    ({-# ... #-}) are blanked like comments: they carry no site tokens.
    """
    out: list[str] = []
    i, n = 0, len(text)
    block = 0
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if block > 0:
            if c == "{" and nxt == "-":
                block += 1
                out.append("  ")
                i += 2
            elif c == "-" and nxt == "}":
                block -= 1
                out.append("  ")
                i += 2
            else:
                out.append("\n" if c == "\n" else " ")
                i += 1
        elif c == "{" and nxt == "-":
            block = 1
            out.append("  ")
            i += 2
        elif c == "-" and nxt == "-":
            while i < n and text[i] != "\n":
                out.append(" ")
                i += 1
        elif c == '"':
            out.append(" ")
            i += 1
            while i < n:
                if text[i] == "\\":
                    out.append("  ")
                    i += 2
                elif text[i] == '"':
                    out.append(" ")
                    i += 1
                    break
                else:
                    out.append("\n" if text[i] == "\n" else " ")
                    i += 1
        elif c == "'":
            # A lone quote is code (a prime suffix or a promoted tick), not
            # a char literal, unless it closes on the same line: 'x' or '\n'.
            j = i + 1
            if j < n and text[j] == "\\":
                j += 2
            else:
                j += 1
            if j < n and text[j] == "'" and "\n" not in text[i : j + 1]:
                out.append("   "[: j + 1 - i])
                i = j + 1
            else:
                out.append(c)
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


def site_rows(stripped: str) -> dict[str, dict[str, int]]:
    """Map enclosing top-level function to its site token counts.

    Contexts are column-0 binding starts; instance methods attribute to
    their instance head, declarations to `<decl>`, and anything before the
    first header to `<top>`. Import lines are never counted: an import
    list naming a combinator is not a site. A site moved between
    functions changes both functions' counts with the file totals
    untouched (NOTE-002); only the bound file rejects it.
    """
    header = re.compile(r"^([A-Za-z_'][A-Za-z0-9_']*)")
    keywords = frozenset(
        ["deriving", "infix", "infixl", "infixr", "pattern", "foreign"]
    )
    decls = frozenset(["data", "newtype", "type", "class"])
    rows: dict[str, dict[str, int]] = {}
    ctx = "<top>"
    in_header = False
    in_import = False
    for line in stripped.splitlines():
        if in_header:
            # The module header's export list names what the module shares;
            # those mentions are not sites. Skip through its `where`.
            if re.search(r"\bwhere\b", line):
                in_header = False
            continue
        if in_import:
            # An import's parenthesized continuation lines are indented;
            # the first column-0 line ends the statement. An import list
            # naming a combinator is not a site.
            if line[:1].isspace() or not line.strip():
                continue
            in_import = False
        if re.match(r"^\s*import\b", line):
            in_import = True
            continue
        if re.match(r"^module\b", line):
            ctx = "<module>"
            if not re.search(r"\bwhere\b", line):
                in_header = True
            continue
        match = header.match(line)
        if match:
            word = match.group(1)
            if word == "instance":
                head = line[len("instance") :].split("where")[0]
                ctx = "instance_" + re.sub(r"\W+", "_", head).strip("_")[:60]
            elif word in decls:
                ctx = "<decl>"
            elif word not in keywords:
                ctx = word
        for cls, res in SITE_RES.items():
            for pattern, token in zip(res, SITE_TOKENS[cls]):
                found = len(pattern.findall(line))
                if found:
                    rows.setdefault(ctx, {}).setdefault(token, 0)
                    rows[ctx][token] += found
    return rows


def discover(root: Path) -> list[str]:
    out: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_DIRS)
        for name in sorted(filenames):
            if name.endswith(".hs"):
                rel = str(Path(dirpath, name).relative_to(root))
                out.append(rel)
    return sorted(out)


def categorize(rel: str) -> str | None:
    for category, _description, prefixes in CATEGORIES:
        for prefix in prefixes:
            if rel.startswith(prefix):
                return category
    return None


def scan(text: str) -> tuple[set[str], list[str]]:
    """Return (classes, findings). Findings are scanner defects, not rows."""
    classes: set[str] = set()
    findings: list[str] = []
    for cls, res in IMPORT_RES.items():
        if any(r.search(text) for r in res):
            classes.add(cls)
    if any(r.search(text) for r in WHOLE_CONCURRENT_RES):
        if any(r.search(text) for r in USE_RES["mvar"][0]):
            classes.add("mvar")
    if CONCURRENT_RE.search(text) and not CONCURRENT_SUB_RE.search(text):
        # Whole-module import beside a submodule import still counts: the
        # file names the whole vocabulary too.
        classes.add("concurrent")
    for cls, res in TOKEN_RES.items():
        if any(r.search(text) for r in res):
            classes.add(cls)
    for cls, (use_res, import_res) in USE_RES.items():
        if any(r.search(text) for r in use_res) and not any(
            r.search(text) for r in import_res
        ):
            findings.append(
                f"use-without-import {cls}: {sorted({r.pattern for r in use_res if r.search(text)})}"
            )
    return classes, findings


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=".")
    parser.add_argument("--json", action="store_true")
    parser.add_argument(
        "--sites",
        action="store_true",
        help="emit the bound site inventory: '<path> <token> <count>' lines",
    )
    args = parser.parse_args()
    root = Path(args.root)
    if not root.is_dir():
        print(f"usage error: no such directory: {root}", file=sys.stderr)
        return 2
    rels = discover(root)
    if not rels:
        print("census failure: no Haskell sources discovered", file=sys.stderr)
        return 2
    rows: list[dict] = []
    failures: list[str] = []
    for rel in rels:
        category = categorize(rel)
        if category is None:
            failures.append(f"unclassified haskell source: {rel}")
            continue
        try:
            text = (root / rel).read_text(encoding="utf-8")
        except OSError as exc:
            print(f"environment error: cannot read {rel}: {exc}", file=sys.stderr)
            return 2
        classes, findings = scan(text)
        for finding in findings:
            failures.append(f"{finding}: {rel}")
        gated = sorted(c for c in classes if c in GATED)
        info = sorted(c for c in classes if c not in GATED)
        sites = site_rows(strip_haskell(text))
        rows.append(
            {
                "file": rel,
                "category": category,
                "gated": gated,
                "info": info,
                "sites": sites,
            }
        )
    if args.sites:
        for row in rows:
            for func in sorted(row["sites"]):
                for token in sorted(row["sites"][func]):
                    print(f"{row['file']} {func} {token} {row['sites'][func][token]}")
    elif args.json:
        print(
            json.dumps({"files": rows, "count": len(rows)}, indent=1, sort_keys=False)
        )
    else:
        by_category: dict[str, int] = {}
        gated_count = 0
        for row in rows:
            by_category[row["category"]] = by_category.get(row["category"], 0) + 1
            if row["gated"]:
                gated_count += 1
        print(f"census: {len(rows)} Haskell sources in {len(by_category)} categories")
        for category, _description, _prefixes in CATEGORIES:
            if category in by_category:
                print(f"  {category}: {by_category[category]}")
        print(
            f"gated effect sites (ioref/mvar/stm/unsafe/fork/async): {gated_count} files"
        )
        print(
            "unsafe IO escapes: " + str(sum(1 for r in rows if "unsafe" in r["gated"]))
        )
        print("forkIO sites: " + str(sum(1 for r in rows if "fork" in r["gated"])))
        print("async sites: " + str(sum(1 for r in rows if "async" in r["gated"])))
    if failures:
        print("FAIL io-ownership-inventory:", file=sys.stderr)
        for failure in failures:
            print(f"  {failure}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
