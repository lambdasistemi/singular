"""Judge the export surface of the module that owns SignedTx (#326 R4).

Reads, on standard input, what GHCi prints for an importer of
Singular.Registry.Node.Submit: ``:browse`` of the module (its exports,
re-exports included, with their types) followed by ``:info SignedTx``
(every instance in scope). Exits 0 when signing is the only way an importer obtains a
SignedTx, and 1 naming every other way:

* an exported binding whose type mentions SignedTx anywhere but as a
  whole top-level argument — a result, a field of a result, or inside a
  continuation all hand a SignedTx to the caller — other than signTx;
* any instance of SignedTx, since a class method can manufacture one.

The extent is what GHC reports, not a list kept here: a binding added
to the module's exports is judged without editing this file.
"""

import re
import sys

PRODUCERS = {"signTx"}
WORD = re.compile(r"\bSignedTx\b")


def entries(text):
    """GHCi output as logical lines: continuations joined to their head."""
    out = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("--"):
            continue
        if line[0].isspace() and out:
            out[-1] += " " + line.strip()
        else:
            out.append(line.strip())
    return out


def unqualify(text):
    """Drop module qualifiers: GHCi names a compiled module's things in full."""
    return re.sub(r"\b(?:[A-Z][\w']*\.)+(?=[\w'])", "", text)


def top_level_args(ty):
    """Split a type at its top-level arrows, after foralls and contexts."""
    ty = re.sub(r"^forall\b[^.]*\.\s*", "", ty)
    parts, depth, cur = [], 0, ""
    i = 0
    while i < len(ty):
        c = ty[i]
        if c in "([":
            depth += 1
        elif c in ")]":
            depth -= 1
        if depth == 0 and ty.startswith("=>", i):
            parts, cur = [], ""
            i += 2
            continue
        if depth == 0 and ty.startswith("->", i):
            parts.append(cur.strip())
            cur = ""
            i += 2
            continue
        cur += c
        i += 1
    parts.append(cur.strip())
    return parts


def judge(text):
    findings, producers = [], []
    for e in entries(unqualify(text)):
        if e.startswith("instance") and WORD.search(e):
            findings.append(f"instance of SignedTx: {e}")
            continue
        if re.match(r"^(?:type|newtype|data)\s", e):
            continue
        m = re.match(r"^(?:pattern\s+)?([\w']+)\s*::\s*(.*)$", e)
        if not m or not WORD.search(m.group(2)):
            continue
        name, ty = m.group(1), m.group(2)
        *args, result = top_level_args(ty)
        hands_out = WORD.search(result) or any(
            WORD.search(a) and a != "SignedTx" for a in args
        )
        if not hands_out:
            continue
        producers.append(name)
        if name not in PRODUCERS:
            findings.append(f"exported producer of SignedTx other than signTx: {e}")
    return findings, producers


def main():
    text = sys.stdin.read()
    if ":: " not in text:
        print("SETUP-FAIL: no GHCi :browse output to judge", file=sys.stderr)
        return 2
    findings, producers = judge(text)
    for f in findings:
        print(f"refused: {f}")
    if findings:
        return 1
    if producers != ["signTx"]:
        print(
            f"SETUP-FAIL: signTx not found among producers {producers}", file=sys.stderr
        )
        return 2
    print("surface: signTx is the only exported producer of SignedTx; no instance")
    return 0


if __name__ == "__main__":
    sys.exit(main())
