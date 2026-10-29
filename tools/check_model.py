"""Extract exact Lean statement identities for the coverage inventory."""

import hashlib
import re


def digest(data):
    return hashlib.sha256(data).hexdigest()


def module_sources(path):
    """A compatibility facade and its cohesive submodules, in path order.

    The adjacent directory belongs to this surface. Discovery includes even an
    unimported module: the compiled report/reachability check must reject it,
    rather than letting a missing import remove an obligation.
    """
    return [path, *sorted(path.with_suffix("").rglob("*.lean"))]


def module_text(path):
    return "\n".join(p.read_text(encoding="utf-8") for p in module_sources(path))


def statement_inventory(path, prefix):
    """Parse a statements surface into exact declaration identities."""
    source = module_text(path)
    clean = re.sub(r"/\-.*?\-/", "", source, flags=re.S)
    clean = re.sub(r"--[^\n]*", "", clean)
    clean = re.sub(r'"(?:\\.|[^"\\])*"', '""', clean)
    declarations = list(
        re.finditer(
            r"(?ms)^theorem ([A-Za-z0-9_]+)\b(.*?) := by\b(.*?)(?=^(?:set_option[^\n]*\bin\n)?theorem |^end )",
            clean,
        )
    )
    assert len(declarations) == len(re.findall(r"\btheorem\b", clean)), (
        f"unrecognized theorem grammar: {path}"
    )
    records = []
    for match in declarations:
        name = prefix + match[1]
        admitted = re.search(r"\bsorry\b", match[3]) is not None
        records.append(
            {
                "name": name,
                "status": "STATED" if admitted else "PROVED",
                "debt": "sorryAx" if admitted else "none",
                "statementSha256": digest((match[1] + match[2]).encode()),
            }
        )
    assert records and len({r["name"] for r in records}) == len(records)
    return records
