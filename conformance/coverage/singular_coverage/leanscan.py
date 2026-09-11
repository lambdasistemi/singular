"""Lexical scanning of Lean sources for theorem/lemma obligations (issue #80).

This is a lexical scan, not proof-term traceability: it establishes the
declaration population and stable statement identities over ALL of ``lean/``.
It cannot classify by use, so every declaration outside the theorem manifests
is reported as unclassified; a filename is never evidence of helper status.

Two hard rules bind this module because both of the epic owner's measurement
errors shrank the denominator:

- the identifier grammar covers dotted names (``Inv.fresh_id``), primed names
  (``not_mem_of_nodup_append'``) and names with ``?`` (``find?_filter_key_ne``);
- every ``theorem``/``lemma`` keyword occurrence in a cleaned source must be
  accounted for by a declaration match, so an unrecognized grammar form fails
  the scan instead of silently dropping declarations.

Statement identity for manifest-bound obligations comes from the manifests via
``tools/check_model.py`` (see inventory.py). For unclassified declarations this
module derives a signature digest: sha256 over the qualified name and the
cleaned signature text from the declaration keyword through the first
bracket-depth-zero ``:=`` (the proof terminator). Editing a statement changes
the digest; editing only the proof does not.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path

# Lean identifier: segments of [A-Za-z0-9_'!?], first char a letter or
# underscore; a qualified name joins segments with '.'. Primes may sit inside
# a segment (not_mem_of_nodup_append'), '?' inside one (find?_filter_key_ne).
_SEGMENT = r"[A-Za-z_][A-Za-z0-9_'!?]*"
QUALIDENT = rf"{_SEGMENT}(?:\.{_SEGMENT})*"

_DECL_START = re.compile(
    rf"(?m)^(?:@\[[^\]\n]*\]\s*)*"
    rf"(?:(?:private|protected|noncomputable|unsafe|partial|sealed)\s+)*"
    rf"(?P<kw>theorem|lemma)\s+(?P<name>{QUALIDENT})(?![A-Za-z0-9_'!?])"
)
_NAMESPACE = re.compile(rf"(?m)^namespace\s+(?P<name>{QUALIDENT})\s*$")
_END = re.compile(r"(?m)^end(?:\s+[^\s]+)?\s*$")
_SECTION = re.compile(r"(?m)^section(?:\s+[^\s]+)?\s*$")
_MUTUAL = re.compile(r"(?m)^mutual\s*$")


def clean_source(text: str) -> str:
    """Neutralize block comments, line comments and string literals.

    Removed spans are replaced with the newlines they contained so that every
    line anchor and line number survives cleaning (check_model.py deletes them
    outright; that is safe for its single-module grammar, not for a
    namespace-tracking scan).
    """
    out = []
    i, n = 0, len(text)
    while i < n:
        if text.startswith("/-", i):
            j = text.find("-/", i + 2)
            j = n if j == -1 else j + 2
            out.append("".join(c if c == "\n" else " " for c in text[i:j]))
            i = j
        elif text.startswith("--", i):
            j = text.find("\n", i)
            j = n if j == -1 else j
            out.append(" " * (j - i) + ("\n" if j < n else ""))
            i = j
        elif text.startswith('"', i):
            j = i + 1
            while j < n:
                if text[j] == "\\":
                    j += 2
                    continue
                if text[j] == '"':
                    j += 1
                    break
                j += 1
            j = min(j, n)
            out.append("".join(c if c == "\n" else " " for c in text[i:j]))
            i = j
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


@dataclass(frozen=True)
class Declaration:
    keyword: str          # theorem | lemma
    name: str             # qualified name, namespace stack + declared name
    source: str           # repo-relative file path
    line: int             # 1-based line of the declaration keyword
    attributed: bool      # declared with a leading @[...] attribute
    signature: str        # cleaned signature text, keyword through ':=' terminator
    signatureSha256: str  # sha256(qualified name + signature): statement identity

    @property
    def identity(self) -> str:
        return f"{self.name}@{self.signatureSha256}"


def _signature_span(clean: str, start: int, limit: int) -> int:
    """Index just past the first bracket-depth-zero '```:=```' in clean[start:limit]."""
    depth = 0
    i = start
    while i < limit:
        c = clean[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth = max(0, depth - 1)
        elif depth == 0 and c == ":" and clean.startswith(":=", i):
            return i + 2
        i += 1
    raise ValueError(
        f"no proof terminator ':=' found in declaration region "
        f"[{start}:{limit}] — unrecognized grammar: {clean[start:start + 80]!r}"
    )


def scan_text(clean: str, source: str) -> list[Declaration]:
    """Scan one cleaned module into declarations with qualified names.

    Namespace structure is tracked so that ``namespace Singular`` plus
    ``theorem Inv.fresh_id`` yields ``Singular.Inv.fresh_id``. ``section``
    blocks contribute nothing to the qualified name.
    """
    events: list[tuple[int, int, object]] = []
    for m in _NAMESPACE.finditer(clean):
        events.append((m.start(), 0, ("namespace", m.group("name"))))
    for m in _SECTION.finditer(clean):
        events.append((m.start(), 1, ("section", None)))
    for m in _MUTUAL.finditer(clean):
        events.append((m.start(), 1, ("section", None)))
    for m in _END.finditer(clean):
        events.append((m.start(), 2, ("end", None)))
    for m in _DECL_START.finditer(clean):
        events.append((m.start(), 3, m))
    # At one position, namespaces/ends must win over a declaration start that
    # could not share the line anyway; order by (position, kind).
    events.sort(key=lambda e: (e[0], e[1]))

    stack: list[str | None] = []
    decls: list[Declaration] = []
    for idx, (pos, _kind, payload) in enumerate(events):
        if isinstance(payload, tuple):
            op, name = payload
            if op == "namespace":
                stack.append(name)
            elif op == "section":
                stack.append(None)
            else:
                if not stack:
                    raise ValueError(f"{source}: 'end' without an open namespace/section")
                stack.pop()
            continue
        m = payload
        line_no = clean.count("\n", 0, m.start()) + 1
        qualified = ".".join([s for s in stack if s] + m.group("name").split("."))
        kw_start = m.start("kw")
        # bound this declaration's region by the next event of any kind
        limit = events[idx + 1][0] if idx + 1 < len(events) else len(clean)
        # the attribute prefix, if any, precedes the keyword on the same line
        line_start = clean.rfind("\n", 0, kw_start) + 1
        attributed = "@[" in clean[line_start:kw_start]
        sig_end = _signature_span(clean, m.end(), limit)
        signature = " ".join(clean[kw_start:sig_end].split())
        digest = hashlib.sha256((qualified + "\n" + signature).encode()).hexdigest()
        decls.append(
            Declaration(
                keyword=m.group("kw"),
                name=qualified,
                source=source,
                line=line_no,
                attributed=attributed,
                signature=signature,
                signatureSha256=digest,
            )
        )
    return decls


def scan_file(path: Path, source: str) -> list[Declaration]:
    return scan_text(clean_source(path.read_text()), source)


def scan_tree(lean_dir: Path) -> list[Declaration]:
    """Scan every .lean file under lean/ in sorted path order (lean/-relative)."""
    decls: list[Declaration] = []
    for path in sorted(lean_dir.rglob("*.lean")):
        rel = path.relative_to(lean_dir.parent).as_posix()
        decls.extend(scan_file(path, rel))
    return decls


def keyword_accounting(clean: str, source: str) -> None:
    """Every theorem/lemma keyword occurrence must be a scanned declaration.

    This is the control that would have caught the owner's measurement errors:
    any grammar form the declaration regex does not recognize (a new modifier,
    an attribute layout, an unusual declaration context) leaves an unaccounted
    keyword occurrence and fails the scan instead of shrinking the population.
    """
    occurrences = len(re.findall(r"\b(?:theorem|lemma)\b", clean))
    found = len(_DECL_START.findall(clean))
    if occurrences != found:
        raise ValueError(
            f"{source}: {occurrences} theorem/lemma keyword occurrences but "
            f"{found} recognized declarations — grammar incomplete, refusing to scan"
        )


def scan_tree_strict(lean_dir: Path) -> list[Declaration]:
    """scan_tree plus per-file keyword accounting (fail closed on grammar gaps)."""
    decls: list[Declaration] = []
    for path in sorted(lean_dir.rglob("*.lean")):
        rel = path.relative_to(lean_dir.parent).as_posix()
        clean = clean_source(path.read_text())
        keyword_accounting(clean, rel)
        decls.extend(scan_text(clean, rel))
    return decls
