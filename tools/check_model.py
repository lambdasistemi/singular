#!/usr/bin/env python3
"""Execute Lean's finite oracles and enforce the exact source-derived theorem manifests.

The source inventory establishes declaration identities and proof status. The compiled
axiom report, produced by `Singular.Audit` and `Singular.NamingAudit`, is cross-checked
against both manifests so that a declaration reported PROVED is one Lean elaborated from
the standard axioms alone.

Three corpora are enforced. The generic corpus is frozen: it must reproduce byte-for-byte
from the generic binary over the generic source extent, where `lean/Singular.lean` counts
in its base form — the current file may differ from that base only by `import
Singular.Naming*` lines (the naming layer hangs off the generic library by imports and
nothing else). The naming corpus is checked the same way over the full current Lean
extent, so every naming module is hash-bound to the exported evidence.
The lifecycle corpus is produced by its own Lean executable over that same full source
extent and replayed by the public simulator adapter.
"""

import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import subprocess

STANDARD = {"propext", "Classical.choice", "Quot.sound"}

# The frozen generic corpus source extent, in rglob order. Naming modules join the
# naming corpus's extent instead; they must never widen this one.
GENERIC_SOURCES = [
    "lean/Main.lean",
    "lean/Singular.lean",
    "lean/Singular/Audit.lean",
    "lean/Singular/Driver.lean",
    "lean/Singular/Lemmas.lean",
    "lean/Singular/Model.lean",
    "lean/Singular/Statements.lean",
]

NAMING_IMPORT = re.compile(r"^import Singular\.Naming\w*\n?", re.M)

LIFECYCLE_IDS = {
    "LM01-maintenance-accepts",
    "LM02-maintenance-unauthorized-refused",
    "LM03-maintenance-field-tamper-refused",
    "LM04-root-equal-after-maintenance",
    "LR01-recovery-accepts",
    "LR02-wrong-reveal-refused",
    "LR03-missing-recovery-signer-refused",
    "LR05-old-controller-dead-after-recovery",
    "LR06-forged-public-digest-refused",
    "LR11-root-equal-after-recovery",
    "LT02-quorum-retirement-accepts",
    "LT03-insufficient-quorum-refused",
    "LT04-retirement-completes",
    "LT08-control-key-alone-refused",
    "LI01-canonical-initialization-accepts",
    "LI02-alternate-seed-refused",
    "LI05-substituted-active-policy-refused",
    "LI06-substituted-terminal-policy-refused",
    "LI07-substituted-registry-refused",
    "WD01-fixture-datum-roundtrip",
    "WD02-two-destinations-refused",
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def audit_sources(root):
    """Keyword and proof-hole audit over every Lean source, generic and naming."""
    for path in sorted((root / "lean").rglob("*.lean")):
        source = path.read_text()
        # This bounded source grammar disallows nested block comments and escape hatches.
        clean = re.sub(r"/\-.*?\-/", "", source, flags=re.S)
        clean = re.sub(r"--[^\n]*", "", clean)
        clean = re.sub(r'"(?:\\.|[^"\\])*"', '""', clean)
        assert not re.search(
            r"\b(axiom|admit|unsafe|implemented_by|extern)\b", clean
        ), path
        if path.name != "Statements.lean":
            assert not re.search(r"\bsorry\b", clean), (
                f"proof hole outside the frozen module: {path}"
            )


def statement_inventory(path, prefix):
    """Parse one statements module into exact declaration identities."""
    source = path.read_text()
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


def axiom_report(root, path):
    text = (
        path.read_text()
        if path
        else subprocess.check_output(
            ["lake", "env", "lean", "tools/axioms.lean"], cwd=root, text=True
        )
    )
    report = {}
    for line in text.splitlines():
        if line.startswith("AXIOMS "):
            _, name, axioms = line.split(" ", 2)
            report[name] = set(re.findall(r"[A-Za-z_][A-Za-z0-9_.]*", axioms))
    assert report, "empty compiled axiom report"
    return report


def check_records(records, report, label):
    for record in records:
        axioms = report[record["name"]]
        if record["status"] == "PROVED":
            assert axioms <= STANDARD, (
                f"{record['name']} depends on {sorted(axioms - STANDARD)}"
            )
        else:
            assert "sorryAx" in axioms, (
                f"{record['name']} is admitted in source but not in the compiled report"
            )
    print(
        f"{label}: {sum(r['status'] == 'PROVED' for r in records)}/{len(records)} "
        f"exact identities PROVED from {sorted(STANDARD)}"
    )


def corpus_envelope(
    corpus,
    sources,
    manifest_path,
    statements_key,
    statements_source,
    model_source,
    corpus_source,
):
    corpus["sourceHashes"] = sources
    corpus["modelSha256"] = sources[model_source]
    corpus[statements_key] = sources[statements_source]
    corpus["corpusSourceSha256"] = sources[corpus_source]
    corpus["theoremManifestSha256"] = digest(manifest_path.read_bytes())
    corpus["payloadSha256"] = digest(
        json.dumps(
            {k: v for k, v in corpus.items() if k != "payloadSha256"},
            sort_keys=True,
            separators=(",", ":"),
        ).encode()
    )
    return corpus


def check_or_compare(target, encoded, export, label):
    if export:
        target.write_text(encoded)
        print(f"{label}: exported")
    else:
        assert target.read_text() == encoded, f"{label} identity drift"


def unreachable_modules(root):
    """Modules on disk that `lake build` will never build.

    The library root is the only entry point lake follows, so a module nobody
    imports is never compiled — and a stale `.olean` from an earlier build makes
    that invisible to every local check, including one that elaborates a file
    importing it. `Singular.NamingAudit` sat unreachable this way: the naming
    axiom gate was in the tree, passing locally, and absent from a clean build.
    The extent is read off the directory, never listed here.
    """
    seen, pending = set(), ["Singular"]
    while pending:
        module = pending.pop()
        if module in seen:
            continue
        seen.add(module)
        source = root / "lean" / (module.replace(".", "/") + ".lean")
        if not source.exists():
            continue
        for line in source.read_text(encoding="utf-8").splitlines():
            if line.startswith("import Singular"):
                pending.append(line.split()[1])
    on_disk = {
        "Singular." + f.stem for f in sorted((root / "lean/Singular").glob("*.lean"))
    }
    assert on_disk, "EMPTY EXTENT: no modules discovered under lean/Singular"
    return sorted(on_disk - seen)


# ---------------------------------------------------------------------------
# The generic model driver (#209 S01, R01-R04).
#
# The driver is one executable over the model's own law: given a scenario it
# runs `Singular.step` and reports the declared boundary observations of what
# the law actually did. These checks exist so that the four ways of faking that
# are detected rather than reported as conformance.
# ---------------------------------------------------------------------------

REFUSAL_LITERAL = re.compile(r'"([a-z][a-z0-9]*(?:-[a-z0-9]+)+)"')


def model_refusal_vocabulary(root):
    """Every refusal reason the driver's law can produce, read off the model:
    `Singular.refusal`'s, and `Singular.exitStep`'s for a fold of an edge the
    request does not name.

    The expected value is obtained from the producer rather than typed here, so
    a reason the model cannot say — an infrastructure error dressed up as a
    ledger refusal — has nowhere to hide. The subject of the assertion is the
    driver's executed output; this only supplies the vocabulary it is held to.
    """
    source = (root / "lean/Singular/Model.lean").read_text(encoding="utf-8")
    body = source.split("\ndef refusal ", 1)[1].split("\n/--", 1)[0]
    vocabulary = set(REFUSAL_LITERAL.findall(body))
    assert vocabulary, "EMPTY EXTENT: no refusal reasons discovered in Singular.refusal"
    exit_body = source.split("\ndef exitStep ", 1)[1].split("\n/--", 1)[0]
    exit_vocabulary = set(REFUSAL_LITERAL.findall(exit_body))
    assert exit_vocabulary, (
        "EMPTY EXTENT: no refusal reasons discovered in Singular.exitStep"
    )
    vocabulary |= exit_vocabulary
    return vocabulary


def model_retraction(root):
    """What a retraction may be refused for, and which retractions are admitted,
    read off the model.

    Its refusal vocabulary is admission's, `Singular.retractAdmission`'s reasons,
    and the retract exit's own: what `Singular.spendRefusal` gives it for what it
    spends and what `Singular.unpaidReason` gives the return bound to its request.
    The reason admission gives a non-retractable request is the one on its
    `retractableEdge` line, the reason it gives a retraction its owner did not
    sign the one on its `signatories` line; the retractable edges are the
    `=> true` arm of `Singular.retractableEdge`. Nothing here is typed from the
    model's words.
    """
    source = (root / "lean/Singular/Model.lean").read_text(encoding="utf-8")
    body = source.split("\ndef retractAdmission ", 1)[1].split("\n/--", 1)[0]
    admission = REFUSAL_LITERAL.findall(body)
    assert admission, (
        "EMPTY EXTENT: no admission reasons discovered in Singular.retractAdmission"
    )

    def reason_on(keyword):
        found = [
            r
            for line in body.splitlines()
            if keyword in line
            for r in REFUSAL_LITERAL.findall(line)
        ]
        assert len(found) == 1, (
            f"Singular.retractAdmission names {found} on its {keyword} line, not one reason"
        )
        return found[0]

    spend = source.split("\ndef spendRefusal ", 1)[1].split("\n/--", 1)[0]
    unpaid = source.split("\ndef unpaidReason ", 1)[1].split("\n/--", 1)[0]
    exit_reasons = set(REFUSAL_LITERAL.findall(spend)) | {
        r
        for line in unpaid.splitlines()
        if ".bound" in line
        for r in REFUSAL_LITERAL.findall(line)
    }
    assert exit_reasons, "EMPTY EXTENT: no reasons discovered for the retract exit"
    table = source.split("\ndef retractableEdge ", 1)[1].split("\n/--", 1)[0]
    retractable = {
        edge
        for line in table.splitlines()
        if line.rstrip().endswith("=> true")
        for edge in re.findall(r"\.(\w+)", line)
    }
    assert retractable, "EMPTY EXTENT: Singular.retractableEdge admits no edge"
    return {
        "admission": set(admission),
        "vocabulary": set(admission) | exit_reasons,
        "edge": reason_on("retractableEdge"),
        "owner": reason_on("signatories"),
        "retractable": retractable,
    }


RETRACT_WITNESS_FIELDS = {"submittedAt", "validFrom", "validTo", "signatories"}


def check_retraction(s, retraction):
    """A retraction row is admitted by the model before anything else: it carries
    the witness admission read, and its outcome is the one admission gives it — a
    request whose edge is not retractable refused for that, then one its owner did
    not sign refused for that, and an accepted retraction only of a retractable
    request its owner signed. The window is the third check; its bounds are the
    model's theorem and Main rows, and here only its reason's vocabulary.
    """
    sid = s["id"]
    if s["outcome"] == "unsupported":
        return
    witness = s.get("witness")
    assert isinstance(witness, dict) and set(witness) == RETRACT_WITNESS_FIELDS, (
        f"{sid}: a retraction row carries no witness for its admission: {witness!r}"
    )
    edge, owner = s["request"]["edge"], s["request"]["owner"]
    if edge not in retraction["retractable"]:
        expected = retraction["edge"]
    elif owner not in witness["signatories"]:
        expected = retraction["owner"]
    else:
        expected = None
    if expected is not None:
        assert s["outcome"] == "refused" and s["reason"] == expected, (
            f"{sid}: a retraction of a {edge!r} request signed by {witness['signatories']} "
            f"for owner {owner} is {s['outcome']} ({s['reason']!r}); Singular.retractAdmission "
            f"refuses it {expected!r} (retractable: {sorted(retraction['retractable'])})"
        )
    elif s["outcome"] == "refused":
        assert s["reason"] in retraction["admission"] - {
            retraction["edge"],
            retraction["owner"],
        }, (
            f"{sid}: a retraction its owner signed of a retractable request is refused "
            f"{s['reason']!r}, which admission gives for neither"
        )


EDGE_INDUCTIVE = re.compile(r"\ninductive Edge where\n((?:  \|[^\n]*\n)+)")
EXIT_INDUCTIVE = re.compile(r"\ninductive Exit where\n((?:  \|[^\n]*\n)+)")
CONSTRUCTOR = re.compile(r"\| (\w+)")


def model_exits(root):
    """The exits a request can take, read off the model: every edge by its own
    name (`fold e`), then every other `Exit` constructor, in declaration order.

    This is the extent the driver's declared operations must equal; it is
    obtained from `Singular.Edge` and `Singular.Exit` rather than typed here, so a
    new exit the driver does not declare fails the check.
    """
    source = (root / "lean/Singular/Model.lean").read_text(encoding="utf-8")
    edges = CONSTRUCTOR.findall(EDGE_INDUCTIVE.search(source).group(1))
    exits = CONSTRUCTOR.findall(EXIT_INDUCTIVE.search(source).group(1))
    assert edges, "EMPTY EXTENT: no constructors discovered in Singular.Edge"
    assert "fold" in exits, "Singular.Exit has no fold constructor"
    others = [e for e in exits if e != "fold"]
    assert others, "EMPTY EXTENT: Singular.Exit has no exit besides a fold"
    return edges, others


DRIVER_SCHEMA = "singular-driver-corpus-v1"

# The outcome classes a scenario may land in. `accepted` and `refused` are the
# model speaking; `unsupported` is the driver saying it cannot reach the case.
# A crashed driver produces none of these, which is the point: an execution
# failure can never be read as a domain refusal.
DRIVER_OUTCOMES = {"accepted", "refused", "unsupported"}


def driver_surface(corpus):
    """The declared boundary: what the driver says it can do and see."""
    surface = corpus["surface"]
    for field in (
        "declaration",
        "definitionDigest",
        "protocolVersion",
        "operations",
        "observations",
        "unobservable",
        "judgements",
    ):
        assert field in surface, f"driver surface omits {field} (D01)"
    assert surface["operations"], "EMPTY EXTENT: driver declares no operations"
    assert surface["observations"], "EMPTY EXTENT: driver declares no observations"
    assert surface["judgements"], "EMPTY EXTENT: driver declares no judgements"
    return surface


def check_driver_scenarios(
    corpus, generic_names, statement_digests, vocabulary, exits, retraction
):
    """R01-R03 over every scenario the driver executed.

    R01 is the one that needs saying out loud: a scenario's observations must
    cover the WHOLE declared boundary. A per-theorem projection — a row that
    reports only the two fields its own theorem happens to talk about — is
    exactly the substitution the requirement forbids, and it is caught here by
    comparing each accepted row's observation keys against the declared set
    rather than against the theorem's interest.
    """
    surface = driver_surface(corpus)
    declared = set(surface["observations"])
    edges, others = exits
    assert surface["operations"] == edges + others, (
        f"the declared operations are not the model's exits: declared "
        f"{surface['operations']}, exits {edges + others}"
    )
    scenarios = corpus["scenarios"]
    assert scenarios, "EMPTY EXTENT: driver corpus carries no scenarios"

    ids = [s["id"] for s in scenarios]
    assert len(set(ids)) == len(ids), "duplicate driver scenario identity"

    seen_outcomes = set()
    accepted = refused = 0
    for s in scenarios:
        sid = s["id"]
        outcome = s["outcome"]
        assert outcome in DRIVER_OUTCOMES, f"{sid}: unknown outcome class {outcome!r}"
        seen_outcomes.add(outcome)

        # R02 — the scenario is bound to a theorem that exists, at the digest
        # the manifest records. A stale binding names a real theorem whose
        # statement has since changed; comparing digests is what catches it.
        assert s["operation"] in surface["operations"], (
            f"{sid}: operation {s['operation']!r} is not a declared operation (D01)"
        )
        theorem = s["theorem"]
        assert theorem in generic_names, f"{sid}: unknown theorem binding {theorem}"
        assert s["statementSha256"] == statement_digests[theorem], (
            f"{sid}: stale theorem binding — {theorem} statement digest moved"
        )

        # R02 — a setup trace is a trace of accepted transitions. A scenario
        # that needs a non-empty starting state must have REACHED it by running
        # the law, not by being handed a constructed state.
        for i, stp in enumerate(s["setup"]):
            assert stp["accepted"] is True, (
                f"{sid}: setup step {i} was not an accepted transition "
                f"({stp.get('reason')!r}); a refused setup cannot establish a starting state"
            )
        if s["requiresReachableState"]:
            assert s["setup"], (
                f"{sid}: claims a reachable non-initial starting state with an empty setup trace"
            )

        if outcome == "accepted":
            accepted += 1
            # R03 — a checked law premise precedes an accepted observation.
            premise = s["premise"]
            assert premise["checked"] is True, (
                f"{sid}: accepted without checking its law premise"
            )
            assert premise["declaration"].startswith("Singular."), (
                f"{sid}: premise {premise['declaration']!r} is not a model declaration"
            )
            # R01 — the complete declared boundary, not a projection of it.
            observed = set(s["observations"])
            assert observed == declared, (
                f"{sid}: observations are a projection of the declared boundary; "
                f"missing {sorted(declared - observed)}, undeclared {sorted(observed - declared)}"
            )
            assert s["reason"] is None, f"{sid}: accepted rows carry no refusal reason"
        elif outcome == "refused":
            refused += 1
            # R03 — a refusal is the model's, with the model's own words.
            assert s["reason"], f"{sid}: refused with no reason"
            allowed = (
                retraction["vocabulary"] if s["operation"] == "retract" else vocabulary
            )
            assert s["reason"] in allowed, (
                f"{sid}: refusal reason {s['reason']!r} is not one the model can produce for "
                f"{s['operation']}; a transport or process failure is an execution failure, "
                f"never a ledger refusal"
            )
            assert s["observations"] is None, (
                f"{sid}: refused rows observe nothing — there was no transition to observe"
            )
            # A refusal is the LAW saying no, which means the law ran, which
            # means its premise held on the state it ran against. A refusal
            # reported without a checked premise is the driver failing to reach
            # the case, and that is `unsupported`, not a ledger refusal.
            assert s["premise"]["checked"] is True, (
                f"{sid}: refused without establishing the premise the law was applied under"
            )
        else:
            # `unsupported` carries no premise constraint on purpose: it covers
            # a setup that would not run and a premise that does not hold (both
            # unestablished) as well as a transaction the model cannot build
            # from an accepted step (established). What makes it distinct is
            # that it observes nothing and says what it could not reach.
            assert s["reason"], f"{sid}: unsupported rows must name what is unsupported"
            assert s["observations"] is None, f"{sid}: unsupported rows observe nothing"

        # A retraction is admitted before it is paid; no other exit reads a witness.
        if s["operation"] == "retract":
            check_retraction(s, retraction)
        else:
            assert "witness" not in s, (
                f"{sid}: a {s['operation']} row carries a retraction witness"
            )

    # Each class must actually occur, or the classification is untested.
    assert accepted, "driver corpus contains no accepted transition"
    assert refused, "driver corpus contains no domain refusal"
    assert {"accepted", "refused"} <= seen_outcomes, (
        f"driver outcome classes exercised: {sorted(seen_outcomes)}"
    )

    # Every exit that is not a fold has an accepted witness: an exit declared
    # but never executed would be a name with no evidence behind it.
    for other in others:
        assert any(
            s["kind"] == "witness"
            and s["operation"] == other
            and s["outcome"] == "accepted"
            for s in scenarios
        ), f"no accepted witness row executes the {other} exit"

    # Every reason admission gives is exhibited by a refused retraction, so no
    # admission check is declared without a row that runs it.
    exhibited = {
        s["reason"]
        for s in scenarios
        if s["operation"] == "retract" and s["outcome"] == "refused"
    }
    assert retraction["admission"] <= exhibited, (
        f"admission reasons the model states but no refused retraction exhibits: "
        f"{sorted(retraction['admission'] - exhibited)}"
    )

    # R02 — a mutant is only a mutant relative to the witness it perturbs.
    witnesses = {s["id"] for s in scenarios if s["kind"] == "witness"}
    for s in scenarios:
        if s["kind"] == "mutant":
            assert s["mutates"] in witnesses, (
                f"{s['id']}: mutant of unknown witness {s['mutates']!r}"
            )
            assert s["mutates"] != s["id"], f"{s['id']}: mutant of itself"
    return accepted, refused, len(scenarios)


# --- independent derivation -------------------------------------------------
#
# Everything above reads what the driver SAYS. That is not enough on its own: a
# driver that never called `Singular.step` and simply printed well-shaped JSON —
# the right keys, a plausible leaf, a reason spelled from the model's own
# vocabulary — would satisfy all of it. So the checker re-derives the model's
# commitment from the state the driver reported and compares. A fabricated row
# cannot produce a correct FNV-1a root over a trie it did not compute, and the
# constants below are read off the model source rather than written here.

STATE_BYTE_ARM = re.compile(r"\| \.(\w+) => (0x[0-9A-Fa-f]+)")
UNKNOWN_BYTE = re.compile(r"\| \.unknown => (0x[0-9A-Fa-f]+)")
DELTA_ARM = re.compile(r"^\s*\| \.(\w+) => \[(.*)\]$", re.M)
TRANSITION_ARM = re.compile(
    r"^\s*\| \.(\w+), (\.unknown|\.known \.\w+) => some (\(\.known \.\w+\)|\.unknown)$",
    re.M,
)


def leaf_name(spelling):
    """A Lean leaf spelling as the corpus writes it: `null` for an unbound key."""
    spelling = spelling.strip("()")
    return None if spelling == ".unknown" else spelling.split(".")[-1]


DELTA_CELL = re.compile(r"\(\.(\w+), (-?\d+)\)")


def model_constants(root):
    """The leaf byte table and the R2 delta table, read off the model."""
    source = (root / "lean/Singular/Model.lean").read_text(encoding="utf-8")
    state_body = source.split("\ndef stateByte ", 1)[1].split("\n/--", 1)[0]
    leaf_bytes = {
        name: int(value, 16) for name, value in STATE_BYTE_ARM.findall(state_body)
    }
    assert leaf_bytes, "EMPTY EXTENT: no state bytes discovered in Singular.stateByte"
    leaf_body = source.split("\ndef leafByte ", 1)[1].split("\n/--", 1)[0]
    unknown = UNKNOWN_BYTE.search(leaf_body)
    assert unknown, "Singular.leafByte states no byte for an unbound key"
    leaf_bytes[None] = int(unknown.group(1), 16)

    delta_body = source.split("\ndef delta (e : Edge)", 1)[1].split("\n/--", 1)[0]
    deltas = {
        edge: [(kind, int(qty)) for kind, qty in DELTA_CELL.findall(cells)]
        for edge, cells in DELTA_ARM.findall(delta_body)
    }
    assert deltas, "EMPTY EXTENT: no delta rows discovered in Singular.delta"
    return leaf_bytes, deltas


def model_transitions(root):
    """The R2 from-to column, read off `Singular.transition`.

    This is the law's core, and re-deriving the expected after-leaf from it is
    what separates a transition that happened from a driver reporting a state.
    An internally consistent row that simply echoes its starting state passes
    every other check here and fails this one.
    """
    source = (root / "lean/Singular/Model.lean").read_text(encoding="utf-8")
    body = source.split("\ndef transition (e : Edge) (before : Leaf)", 1)[1].split(
        "\n/--", 1
    )[0]
    table = {
        (edge, leaf_name(before)): leaf_name(after)
        for edge, before, after in TRANSITION_ARM.findall(body)
    }
    assert table, "EMPTY EXTENT: no transitions discovered in Singular.transition"
    return table


def fnv1a(data):
    """The model's canonical commitment function, `Singular.fnv1a`."""
    acc = 14695981039346656037
    for byte in data:
        acc = ((acc ^ byte) * 16777619) % (1 << 64)
    return acc


def u64bytes(value):
    return [(value >> shift) & 0xFF for shift in (56, 48, 40, 32, 24, 16, 8, 0)]


def root_of(trie, leaf_bytes):
    """`Singular.rootOf`: FNV-1a over the sorted (key, leaf byte) pairs."""
    data = []
    for entry in sorted(trie, key=lambda e: e["key"]):
        key = entry["key"] & 0xFF
        data += u64bytes(fnv1a([key])) + [key, leaf_bytes[entry["leaf"]]]
    return u64bytes(fnv1a(data))


def check_derived(corpus, leaf_bytes, deltas, transitions):
    """Re-derive what the law must have produced, for every row.

    Every state the driver reports — each setup step's, and an accepted row's
    result — must carry the root the model's commitment function gives for its
    own trie. That binds the whole trace to real execution, including a refused
    row, whose starting state had to be reached by running the law.
    """
    derived = 0
    for s in corpus["scenarios"]:
        sid = s["id"]
        states = [("start", s["start"])]
        states += [
            (f"setup step {i}", stp["state"])
            for i, stp in enumerate(s["setup"])
            if stp["accepted"]
        ]
        if s["observations"] is not None:
            states.append(("result", s["observations"]["state"]))
        for where, state in states:
            expected = root_of(state["trie"], leaf_bytes)
            assert state["config"]["root"] == expected, (
                f"{sid}: {where} reports a root the model does not commit to for its own "
                f"trie — the state was not produced by executing the law"
            )
            derived += 1
        if s["observations"] is None:
            continue

        obs = s["observations"]
        assert obs["root"] == obs["config"]["root"], (
            f"{sid}: the reported root and the config root disagree"
        )
        key = s["request"]["key"]
        leaf = next((e["leaf"] for e in obs["state"]["trie"] if e["key"] == key), None)
        assert obs["leaf"] == leaf, (
            f"{sid}: reports leaf {obs['leaf']!r} while its own produced trie holds "
            f"{leaf!r} at key {key}"
        )

        before = s["setup"][-1]["state"] if s["setup"] else s["start"]
        before_leaf = next((e["leaf"] for e in before["trie"] if e["key"] == key), None)

        # An exit that folds no edge — a reject, a retract — leaves the
        # registry as it found it and mints nothing: the whole state the row
        # reports must be the state the exit was taken from.
        if s["operation"] not in {edge for edge, _ in transitions}:
            assert obs["state"] == before, (
                f"{sid}: {s['operation']} folds no edge, yet the state it reports differs "
                f"from the state it was taken from"
            )
            assert obs["mint"] == [] and obs["tx"]["mint"] == [], (
                f"{sid}: {s['operation']} folds no edge, yet mints {obs['mint']}"
            )
            derived += 2
            continue

        # The transition itself, derived from the model's R2 table rather than
        # read back off the row: the state the law was applied to decides what
        # the leaf must now be. A row that echoes its own starting state is
        # internally consistent and fails here.
        assert (s["operation"], before_leaf) in transitions, (
            f"{sid}: accepted {s['operation']} on a {before_leaf!r} leaf, which the R2 "
            f"table refuses"
        )
        expected_leaf = transitions[(s["operation"], before_leaf)]
        assert obs["leaf"] == expected_leaf, (
            f"{sid}: {s['operation']} on a {before_leaf!r} leaf must produce "
            f"{expected_leaf!r}; the row reports {obs['leaf']!r}"
        )
        derived += 1

        # The mint is the edge's R2 row, keyed by the request's key, named by
        # the registry's pinned policy for the kind.
        policies = {
            "active": obs["config"]["activePolicy"],
            "absent": obs["config"]["absentPolicy"],
            "terminal": obs["config"]["terminalPolicy"],
        }
        expected_mint = [
            {
                "kind": kind,
                "key": key,
                "quantity": qty,
                "policy": policies[kind],
                "assetName": key,
            }
            for kind, qty in deltas[s["operation"]]
        ]
        actual_mint = [
            {k: m[k] for k in ("kind", "key", "quantity", "policy", "assetName")}
            for m in obs["mint"]
        ]
        assert actual_mint == expected_mint, (
            f"{sid}: mint {actual_mint} is not the R2 delta of {s['operation']} at key "
            f"{key}, which is {expected_mint}"
        )
        assert obs["tx"]["mint"] == obs["mint"], (
            f"{sid}: the transaction mints something other than the executed step did"
        )
        derived += 3
    assert derived, "EMPTY EXTENT: nothing was independently derived"
    return derived


# ---------------------------------------------------------------------------
# The driver's batch questions (#344).
#
# Lean states two batch laws the single-request scenarios never reach:
# `Singular.foldBatch`, which folds several requests atomically, and the
# judgement of several rejects as `Singular.settle` over their concatenated
# obligations. The driver answers each as a declared question with its own
# observation extent. These checks hold the batch rows to the same standard as
# the scenarios and re-derive, from the model's own tables, what each batch must
# have answered, so a row with a wrong expected refusal fails here rather than
# being exported.
# ---------------------------------------------------------------------------

BATCH_QUESTIONS = {"foldBatch", "rejectBatch"}


def model_batch_refusals(root):
    """What a fold batch may be refused for, read off the model: every reason
    `Singular.refusal` gives a request, and `Singular.foldBatch`'s own two — the
    one on its `isEmpty` line and the one its mint guard throws."""
    source = (root / "lean/Singular/Model.lean").read_text(encoding="utf-8")
    body = source.split("\ndef foldBatch ", 1)[1].split("\n/--", 1)[0]

    def reason_on(keyword):
        found = [
            r
            for line in body.splitlines()
            if keyword in line
            for r in REFUSAL_LITERAL.findall(line)
        ]
        assert len(found) == 1, (
            f"Singular.foldBatch names {found} on its {keyword} line, not one reason"
        )
        return found[0]

    step = source.split("\ndef refusal ", 1)[1].split("\n/--", 1)[0]
    vocabulary = set(REFUSAL_LITERAL.findall(step))
    assert vocabulary, "EMPTY EXTENT: no refusal reasons discovered in Singular.refusal"
    return {
        "empty": reason_on("isEmpty"),
        "mismatch": reason_on("assetSame"),
        "step": vocabulary,
    }


def model_unpaid_reasons(root):
    """Every reason `Singular.unpaidReason` gives a recipient left unpaid."""
    source = (root / "lean/Singular/Model.lean").read_text(encoding="utf-8")
    body = source.split("\ndef unpaidReason ", 1)[1].split("\n/--", 1)[0]
    reasons = set(REFUSAL_LITERAL.findall(body))
    assert reasons, "EMPTY EXTENT: no reasons discovered in Singular.unpaidReason"
    return reasons


OBLIGATION = re.compile(r"recipient := \.(\w+) request\.(\w+), atLeast := ([^}]+?) \}")


def model_reject_settlement(root):
    """How a batch of rejects is settled, read off the model: the recipient and
    floor `Singular.obligations` gives a reject, the role `Singular.paysRecipient`
    reads for that recipient, and the reason `Singular.unpaidReason` gives it
    unpaid. Nothing here is typed from the model's words."""
    source = (root / "lean/Singular/Model.lean").read_text(encoding="utf-8")
    body = source.split("\ndef obligations ", 1)[1].split("\n/--", 1)[0]
    arms = re.split(r"\n  \| ", body)
    arm = next(a for a in arms if re.search(r"(^|\| )\.reject\b", a))
    owed = OBLIGATION.search(arm)
    assert owed, f"Singular.obligations states no reject payment: {arm!r}"
    recipient, key_field, floor = owed.group(1), owed.group(2), owed.group(3)
    floor_fields = re.findall(r"request\.(\w+)", floor)
    assert floor_fields, f"a reject's floor names no request field: {floor!r}"
    pays = source.split("\ndef paysRecipient ", 1)[1].split("\n/--", 1)[0]
    pays_arm = next(
        (
            line
            for line in pays.splitlines()
            if line.strip().startswith(f"| .{recipient} ")
        ),
        None,
    )
    assert pays_arm, f"Singular.paysRecipient reads no {recipient} recipient"
    role = re.search(r"output\.role == \.(\w+)", pays_arm)
    assert role and "output.address == some" in pays_arm, (
        f"Singular.paysRecipient reads a {recipient} otherwise than by role and address"
    )
    unpaid = source.split("\ndef unpaidReason ", 1)[1].split("\n/--", 1)[0]
    reason_arm = next(line for line in unpaid.splitlines() if f".{recipient} " in line)
    reasons = REFUSAL_LITERAL.findall(reason_arm)
    assert len(reasons) == 1, (
        f"Singular.unpaidReason gives an unpaid {recipient} {reasons}, not one reason"
    )
    return {
        "key": key_field,
        "floor": floor_fields,
        "role": role.group(1),
        "reason": reasons[0],
    }


def reject_batch_settle(settlement, requests, outputs):
    """`Singular.settle` over the concatenated reject obligations of `requests`:
    each recipient, in the order first owed, owed its summed floors and receiving
    the summed lovelace of the outputs paying it; the first short one names the
    model's reason."""
    owed = {}
    for r in requests:
        key = r[settlement["key"]]
        owed[key] = owed.get(key, 0) + sum(r[f] for f in settlement["floor"])
    for key, floor in owed.items():
        received = sum(
            o["lovelace"]
            for o in outputs
            if o["role"] == settlement["role"] and o["address"] == key
        )
        if received < floor:
            return settlement["reason"]
    return None


def batch_surface(surface):
    """The declared batch questions, each with its own observation extent.

    A batch question reports a subset of the single-request boundary and never a
    transaction: the model builds none for a batch, so a `tx` in a batch extent
    would be an observation nothing produces.
    """
    batches = surface.get("batchQuestions")
    assert isinstance(batches, dict) and batches, (
        "driver surface declares no batch questions (#344)"
    )
    assert set(batches) == BATCH_QUESTIONS, (
        f"driver batch questions {sorted(batches)} are not {sorted(BATCH_QUESTIONS)}"
    )
    declared = set(surface["observations"])
    for name, extent in batches.items():
        assert extent, f"EMPTY EXTENT: batch question {name} declares no observation"
        assert len(set(extent)) == len(extent), (
            f"batch question {name} declares an observation twice: {extent}"
        )
        assert "tx" not in extent, (
            f"batch question {name} declares a transaction observation; the model builds "
            "no transaction for a batch"
        )
        assert set(extent) <= declared, (
            f"batch question {name} declares observations the driver does not: "
            f"{sorted(set(extent) - declared)}"
        )
    return batches


def leaf_at(state, key):
    return next((e["leaf"] for e in state["trie"] if e["key"] == key), None)


def distinct_keys(requests):
    keys = []
    for r in requests:
        if r["key"] not in keys:
            keys.append(r["key"])
    return keys


def asset_sums(entries):
    """Per-asset sums of a keyed delta list, zero sums dropped: `assetSame`
    compares `assetKind` at every asset, where a zero sum and an absent one
    agree."""
    sums = {}
    for kind, key, qty in entries:
        sums[(kind, key)] = sums.get((kind, key), 0) + qty
    return {asset: qty for asset, qty in sums.items() if qty != 0}


def fold_batch_expectation(row, refusals, transitions, deltas):
    """What `Singular.foldBatch` must answer for this row, re-derived from the
    model's tables and the step trace the row carries: `(outcome, reason)`."""
    requests = row["requests"]
    if not requests:
        assert row["folded"] == [], f"{row['id']}: an empty batch folds nothing"
        return "refused", refusals["empty"]
    folded = row["folded"]
    assert folded, f"{row['id']}: a non-empty batch carries no step trace"
    assert len(folded) <= len(requests), f"{row['id']}: more steps than requests"
    before = row["setup"][-1]["state"] if row["setup"] else row["start"]
    for i, (request, stp) in enumerate(zip(requests, folded)):
        assert stp["request"] == request, (
            f"{row['id']}: step {i} folds another request than the batch names"
        )
        edge, key = request["edge"], request["key"]
        before_leaf = leaf_at(before, key)
        if not stp["accepted"]:
            assert i == len(folded) - 1, (
                f"{row['id']}: the trace continues past the refused step {i}"
            )
            assert stp["reason"] in refusals["step"], (
                f"{row['id']}: step {i} is refused {stp['reason']!r}, which "
                "Singular.refusal cannot say"
            )
            return "refused", stp["reason"]
        assert (edge, before_leaf) in transitions, (
            f"{row['id']}: step {i} accepts {edge} on a {before_leaf!r} leaf, which "
            "the R2 table refuses"
        )
        assert leaf_at(stp["state"], key) == transitions[(edge, before_leaf)], (
            f"{row['id']}: step {i} {edge} on a {before_leaf!r} leaf leaves "
            f"{leaf_at(stp['state'], key)!r}"
        )
        before = stp["state"]
    assert len(folded) == len(requests), (
        f"{row['id']}: every step accepted, yet the trace stops early"
    )
    claimed = asset_sums(
        (c["kind"], r["key"], c["quantity"]) for r in requests for c in r["claimed"]
    )
    actual = asset_sums(
        (kind, r["key"], qty) for r in requests for kind, qty in deltas[r["edge"]]
    )
    if claimed != actual:
        return "refused", refusals["mismatch"]
    return "accepted", None


def check_batch_rows(
    corpus,
    generic_names,
    statement_digests,
    refusals,
    unpaid,
    transitions,
    deltas,
    leaf_bytes,
    settlement,
):
    """Every batch row the driver answered, held to its declared question.

    The expected outcome and reason of every fold batch are re-derived here, not
    read back off the row: a row whose refusal differs from what the model's
    tables and its own step trace imply fails, whatever the driver printed.
    """
    surface = driver_surface(corpus)
    batches = batch_surface(surface)
    rows = corpus.get("batches")
    assert isinstance(rows, list) and rows, (
        "EMPTY EXTENT: driver corpus carries no batch rows"
    )
    ids = [r["id"] for r in rows] + [s["id"] for s in corpus["scenarios"]]
    assert len(set(ids)) == len(ids), "duplicate driver row identity"
    exits = set(surface["operations"])
    derived = 0
    for row in rows:
        rid = row["id"]
        question = row["question"]
        assert question in batches, f"{rid}: question {question!r} is not declared"
        theorem = row["theorem"]
        assert theorem in generic_names, f"{rid}: unknown theorem binding {theorem}"
        assert row["statementSha256"] == statement_digests[theorem], (
            f"{rid}: stale theorem binding — {theorem} statement digest moved"
        )
        for i, stp in enumerate(row["setup"]):
            assert stp["accepted"] is True, (
                f"{rid}: setup step {i} was not an accepted transition"
            )
        if row["requiresReachableState"]:
            assert row["setup"], (
                f"{rid}: claims a reachable state with an empty setup trace"
            )
        assert "witness" not in row, f"{rid}: a batch row carries a retraction witness"

        outcome = row["outcome"]
        assert outcome in DRIVER_OUTCOMES, f"{rid}: unknown outcome class {outcome!r}"
        observations = row["observations"]
        if outcome == "accepted":
            assert row["premise"]["checked"] is True, (
                f"{rid}: accepted without checking its law premise"
            )
            assert "tx" not in observations, (
                f"{rid}: a batch row observes a transaction; the model builds none for a batch"
            )
            assert set(observations) == set(batches[question]), (
                f"{rid}: observations are not the {question} extent; missing "
                f"{sorted(set(batches[question]) - set(observations))}, undeclared "
                f"{sorted(set(observations) - set(batches[question]))}"
            )
            assert row["reason"] is None, (
                f"{rid}: accepted rows carry no refusal reason"
            )
        else:
            assert row["reason"], f"{rid}: {outcome} rows must name a reason"
            assert observations is None, f"{rid}: {outcome} rows observe nothing"
            if outcome == "refused":
                assert row["premise"]["checked"] is True, (
                    f"{rid}: refused without establishing the premise"
                )

        before = row["setup"][-1]["state"] if row["setup"] else row["start"]
        states = [row["start"]] + [stp["state"] for stp in row["setup"]]
        if question == "foldBatch":
            assert all(isinstance(r, dict) and "edge" in r for r in row["requests"]), (
                f"{rid}: a fold batch names requests, each folded on its own edge"
            )
            if outcome != "unsupported":
                expected = fold_batch_expectation(row, refusals, transitions, deltas)
                assert (outcome, row["reason"]) == expected, (
                    f"{rid}: Singular.foldBatch answers {expected}, the row reports "
                    f"{(outcome, row['reason'])} — a wrong expected batch refusal"
                )
                derived += 1
                states += [stp["state"] for stp in row["folded"] if stp["accepted"]]
            if outcome == "accepted":
                obs = observations
                states.append(obs["state"])
                assert obs["state"] == row["folded"][-1]["state"], (
                    f"{rid}: the batch reports another state than its last step produced"
                )
                keys = distinct_keys(row["requests"])
                assert [e["key"] for e in obs["leaf"]] == keys, (
                    f"{rid}: leaves are not reported for every request key, in order"
                )
                for entry in obs["leaf"]:
                    assert entry["leaf"] == leaf_at(obs["state"], entry["key"]), (
                        f"{rid}: leaf at {entry['key']} differs from the produced trie"
                    )
                assert obs["root"] == obs["config"]["root"], (
                    f"{rid}: the reported root and the config root disagree"
                )
                policies = {
                    "active": obs["config"]["activePolicy"],
                    "absent": obs["config"]["absentPolicy"],
                    "terminal": obs["config"]["terminalPolicy"],
                }
                for m in obs["mint"]:
                    assert (
                        m["policy"] == policies[m["kind"]]
                        and m["assetName"] == m["key"]
                    ), (
                        f"{rid}: mint entry {m} is not named by the pinned policy and key"
                    )
                reported = asset_sums(
                    (m["kind"], m["key"], m["quantity"]) for m in obs["mint"]
                )
                summed = asset_sums(
                    (kind, r["key"], qty)
                    for r in row["requests"]
                    for kind, qty in deltas[r["edge"]]
                )
                assert reported == summed, (
                    f"{rid}: the batch mints {reported}, the summed R2 deltas are {summed}"
                )
                derived += 3
        else:
            items = row["requests"]
            assert all(set(i) == {"exit", "request"} for i in items), (
                f"{rid}: a reject batch names each request with its exit"
            )
            for i in items:
                assert i["exit"] in exits, f"{rid}: undeclared exit {i['exit']!r}"
            supported = bool(items) and all(i["exit"] == "reject" for i in items)
            assert outcome != "refused", (
                f"{rid}: a reject batch is never refused; a reject carries no admission"
            )
            assert (outcome == "accepted") == supported, (
                f"{rid}: a reject batch of {[i['exit'] for i in items]} is {outcome}; "
                "only a non-empty batch of rejects is answered, every other is unsupported"
            )
            derived += 1
            if outcome == "accepted":
                obs = observations
                states.append(obs["state"])
                assert obs["state"] == before, (
                    f"{rid}: a reject batch changes the state it was taken from"
                )
                assert obs["mint"] == [], f"{rid}: a reject batch mints {obs['mint']}"
                assert [e["key"] for e in obs["leaf"]] == distinct_keys(
                    [i["request"] for i in items]
                ), f"{rid}: leaves are not reported for every request key, in order"
                derived += 2
            if "outputs" in row:
                assert outcome == "accepted", f"{rid}: only an answered batch is judged"
                assert "settle" in row, (
                    f"{rid}: judged outputs carry no settle judgement"
                )
                assert row["settle"] is None or row["settle"] in unpaid, (
                    f"{rid}: settle {row['settle']!r} is not a reason Singular.settle gives"
                )
                expected = reject_batch_settle(
                    settlement, [i["request"] for i in items], row["outputs"]
                )
                assert row["settle"] == expected, (
                    f"{rid}: Singular.settle over the batch's concatenated obligations "
                    f"answers {expected!r}, the row reports {row['settle']!r}"
                )
                derived += 1
            else:
                assert "settle" not in row, f"{rid}: a settle judgement with no outputs"
        for state in states:
            assert state["config"]["root"] == root_of(state["trie"], leaf_bytes), (
                f"{rid}: a reported state carries a root the model does not commit to"
            )
            derived += 1

    witnesses = {r["id"] for r in rows if r["kind"] == "witness"}
    for row in rows:
        if row["kind"] == "mutant":
            assert row["mutates"] in witnesses and row["mutates"] != row["id"], (
                f"{row['id']}: mutant of unknown batch witness {row['mutates']!r}"
            )

    check_batch_controls(corpus, refusals)
    return len(rows), derived


def check_batch_controls(corpus, refusals):
    """The controls each batch question must exhibit, found by what the rows
    do rather than by their names."""
    rows = corpus["batches"]
    folds = [r for r in rows if r["question"] == "foldBatch"]
    rejects = [r for r in rows if r["question"] == "rejectBatch"]

    def some(rows, why, predicate):
        assert any(predicate(r) for r in rows), f"no batch row exhibits {why}"

    some(
        folds,
        "a lawful multi-request fold",
        lambda r: r["outcome"] == "accepted" and len(r["requests"]) >= 2,
    )
    some(
        folds,
        "a batch refused for its claimed mint",
        lambda r: r["outcome"] == "refused"
        and r["reason"] == refusals["mismatch"]
        and len(r["requests"]) >= 2,
    )
    some(
        folds,
        "an empty batch refused",
        lambda r: r["outcome"] == "refused" and r["reason"] == refusals["empty"],
    )
    some(
        folds,
        "a batch whose later request fails its step",
        lambda r: r["outcome"] == "refused"
        and len(r["folded"]) >= 2
        and not r["folded"][-1]["accepted"],
    )
    some(
        rejects,
        "a multi-request reject judged paid",
        lambda r: r["outcome"] == "accepted"
        and len(r["requests"]) >= 2
        and "outputs" in r
        and r["settle"] is None,
    )
    some(
        rejects,
        "a multi-request reject judged short",
        lambda r: r["outcome"] == "accepted"
        and len(r["requests"]) >= 2
        and "outputs" in r
        and r["settle"] is not None,
    )

    def short_in_sum(r):
        if r["outcome"] != "accepted" or "outputs" not in r or r["settle"] is None:
            return False
        owners = [i["request"]["owner"] for i in r["requests"]]
        return any(
            owners.count(o) >= 2
            and all(
                i["request"]["deposit"]
                <= sum(x["lovelace"] for x in r["outputs"] if x["address"] == o)
                for i in r["requests"]
                if i["request"]["owner"] == o
            )
            for o in owners
        )

    some(
        rejects,
        "one owner owed by two rejects, each covered alone, short in sum",
        short_in_sum,
    )
    some(
        rejects,
        "a mixed batch answered unsupported",
        lambda r: r["outcome"] == "unsupported"
        and len({i["exit"] for i in r["requests"]}) >= 2,
    )

    # Preservation, exhibited: a one-request batch beside the single-request
    # scenario taking the same request from the same state answers the same.
    def twin(row, operation):
        request = row["requests"][0]
        request = request["request"] if operation == "reject" else request
        return [
            s
            for s in corpus["scenarios"]
            if s["operation"] == operation
            and s["request"] == request
            and s["start"] == row["start"]
            and [x["request"] for x in s["setup"]]
            == [x["request"] for x in row["setup"]]
        ]

    shared = ("config", "custody", "held", "mint", "root", "state")
    pairs = 0
    for row in rows:
        if len(row["requests"]) != 1 or row["outcome"] == "unsupported":
            continue
        if row["question"] == "foldBatch":
            operation = row["requests"][0]["edge"]
        else:
            operation = "reject"
        for s in twin(row, operation):
            assert (row["outcome"], row["reason"]) == (s["outcome"], s["reason"]), (
                f"{row['id']}: a one-request batch answers {(row['outcome'], row['reason'])}, "
                f"the single {operation} of {s['id']} {(s['outcome'], s['reason'])}"
            )
            if row["outcome"] == "accepted":
                for name in shared:
                    assert row["observations"][name] == s["observations"][name], (
                        f"{row['id']}: a one-request batch observes another {name} than "
                        f"the single {operation} of {s['id']}"
                    )
                assert row["observations"]["leaf"] == [
                    {"key": s["request"]["key"], "leaf": s["observations"]["leaf"]}
                ], f"{row['id']}: a one-request batch reads another leaf than {s['id']}"
                if operation == "reject":
                    assert row["observations"]["paid"] == s["observations"]["paid"], (
                        f"{row['id']}: a one-request reject batch pays otherwise than {s['id']}"
                    )
            pairs += 1
    for question, operation_of in (
        ("foldBatch", "a fold"),
        ("rejectBatch", "a reject"),
    ):
        assert any(
            r["question"] == question
            and len(r["requests"]) == 1
            and r["outcome"] == "accepted"
            and twin(
                r, r["requests"][0]["edge"] if question == "foldBatch" else "reject"
            )
            for r in rows
        ), (
            f"no one-request {question} row stands beside {operation_of} scenario it preserves"
        )
    return pairs


def must_refuse(label, check, *args):
    """A control: the check must fail on the mutated input, or it is not a check."""
    try:
        check(*args)
    except AssertionError:
        return
    raise AssertionError(f"control did not fire: {label}")


def batch_controls(corpus, refusals, run, settlement):
    """Falsify the batch checks on mutants of the corpus they just passed."""
    rows = corpus["batches"]
    refused = next(
        r for r in rows if r["question"] == "foldBatch" and r["outcome"] == "refused"
    )
    for wrong in sorted({refusals["empty"], refusals["mismatch"]} | refusals["step"]):
        if wrong == refused["reason"]:
            continue
        mutant = copy.deepcopy(corpus)
        next(r for r in mutant["batches"] if r["id"] == refused["id"])["reason"] = wrong
        must_refuse(f"{refused['id']} expected refused {wrong!r}", run, mutant)
    accepted = next(r for r in rows if r["outcome"] == "accepted")
    mutant = copy.deepcopy(corpus)
    row = next(r for r in mutant["batches"] if r["id"] == accepted["id"])
    row["observations"]["tx"] = {}
    must_refuse(f"{accepted['id']} observing a transaction", run, mutant)
    judged = [r for r in rows if "settle" in r]
    for row in judged:
        wrong = settlement["reason"] if row["settle"] is None else None
        mutant = copy.deepcopy(corpus)
        next(r for r in mutant["batches"] if r["id"] == row["id"])["settle"] = wrong
        must_refuse(f"{row['id']} judged {wrong!r}", run, mutant)
    for question in BATCH_QUESTIONS:
        mutant = copy.deepcopy(corpus)
        mutant["surface"]["batchQuestions"][question] = mutant["surface"][
            "batchQuestions"
        ][question] + ["tx"]
        must_refuse(f"{question} declaring a transaction observation", run, mutant)
    return 3 + len(refusals["step"]) + len(judged)


TRANSLATION_HEADING = "## The model driver translation"
TRANSLATION_ROW = re.compile(
    r"^\| `?([^|`]+?)`? \| (realization|identity|unobservable) \| (.+?) \|$", re.M
)


def check_translation(root, surface):
    """R04 — the constitution states the concrete realization of every declared
    law, observation and judgement, the identity rules, and the named unobservable fields.

    Mechanical reconciliation only, in both directions: a declared name with no
    row fails, and a row naming something the driver does not declare fails.
    Whether a stated realization is TRUE is a semantic review, not this check,
    and this check must never be read as establishing it.
    """
    text = (root / ".specify/memory/constitution.md").read_text(encoding="utf-8")
    assert TRANSLATION_HEADING in text, (
        f"the constitution states no model driver translation ({TRANSLATION_HEADING!r} absent) — R04"
    )
    section = text.split(TRANSLATION_HEADING, 1)[1]
    rows = {}
    for name, kind, body in TRANSLATION_ROW.findall(section):
        assert body.strip(), f"translation row {name} states nothing"
        rows.setdefault(kind, {})[name] = body.strip()

    declared = (
        set(surface["operations"])
        | set(surface["observations"])
        | set(surface["judgements"])
        | set(batch_surface(surface))
    )
    stated = set(rows.get("realization", {}))
    assert stated == declared, (
        "constitutional translation does not reconcile with the declared surface; "
        f"undeclared rows: {sorted(stated - declared)}; "
        f"unmapped declarations: {sorted(declared - stated)}"
    )

    named_unobservable = set(rows.get("unobservable", {}))
    assert named_unobservable == set(surface["unobservable"]), (
        "named unobservable fields differ between the driver surface and the constitution; "
        f"constitution-only: {sorted(named_unobservable - set(surface['unobservable']))}; "
        f"driver-only: {sorted(set(surface['unobservable']) - named_unobservable)}"
    )
    assert rows.get("identity"), "the translation states no identity rules (D05, R04)"
    return len(declared), len(named_unobservable), len(rows["identity"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--binary", type=Path)
    parser.add_argument("--naming-binary", type=Path)
    parser.add_argument("--lifecycle-binary", type=Path)
    parser.add_argument("--driver-binary", type=Path)
    parser.add_argument(
        "--axioms-report",
        type=Path,
        help="saved output of `lake env lean tools/axioms.lean`",
    )
    parser.add_argument("--export", action="store_true")
    args = parser.parse_args()
    root = args.root.resolve()

    # Name the source that actually ran, so a receipt cites the checker it
    # was produced by rather than the one someone assumed.
    print(f"provenance: check_model.py sha256={digest(Path(__file__).read_bytes())}")

    audit_sources(root)
    generic_records = statement_inventory(
        root / "lean/Singular/Statements.lean", "Singular.Statements."
    )
    naming_records = statement_inventory(
        root / "lean/Singular/NamingStatements.lean", "Singular.NamingStatements."
    )
    lifecycle_records = statement_inventory(
        root / "lean/Singular/NamingLifecycleStatements.lean",
        "Singular.NamingLifecycleStatements.",
    )
    wire_records = statement_inventory(
        root / "lean/Singular/NamingWireStatements.lean",
        "Singular.NamingWireStatements.",
    )
    generic_names = {r["name"] for r in generic_records}
    naming_names = {r["name"] for r in naming_records}
    lifecycle_names = {r["name"] for r in lifecycle_records}
    wire_names = {r["name"] for r in wire_records}
    assert (
        not generic_names & naming_names
        and not generic_names & lifecycle_names
        and not naming_names & lifecycle_names
        and not wire_names & (generic_names | naming_names | lifecycle_names)
    ), "theorem declaration inventories collide"

    generic_manifest_path = root / "lean/theorem-debt.json"
    naming_manifest_path = root / "lean/naming-theorem-debt.json"
    lifecycle_manifest_path = root / "lean/lifecycle-theorem-debt.json"
    wire_manifest_path = root / "lean/wire-theorem-debt.json"
    if args.export:
        generic_manifest_path.write_text(json.dumps(generic_records, indent=2) + "\n")
        naming_manifest_path.write_text(json.dumps(naming_records, indent=2) + "\n")
        lifecycle_manifest_path.write_text(
            json.dumps(lifecycle_records, indent=2) + "\n"
        )
        wire_manifest_path.write_text(json.dumps(wire_records, indent=2) + "\n")
    generic_manifest = json.loads(generic_manifest_path.read_text())
    naming_manifest = json.loads(naming_manifest_path.read_text())
    lifecycle_manifest = json.loads(lifecycle_manifest_path.read_text())
    wire_manifest = json.loads(wire_manifest_path.read_text())
    assert generic_records == generic_manifest, (
        "exact named theorem/debt manifest mismatch"
    )
    assert naming_records == naming_manifest, (
        "exact named naming theorem/debt manifest mismatch"
    )
    assert lifecycle_records == lifecycle_manifest, (
        "exact named lifecycle theorem/debt manifest mismatch"
    )
    assert wire_records == wire_manifest, (
        "exact named wire theorem/debt manifest mismatch"
    )

    report = axiom_report(root, args.axioms_report)
    assert set(report) == generic_names | naming_names | lifecycle_names | wire_names, (
        "compiled report names differ from the manifests"
    )
    check_records(generic_records, report, "model-check")
    check_records(naming_records, report, "naming-check")
    check_records(lifecycle_records, report, "lifecycle-check")
    check_records(wire_records, report, "wire-check")

    orphans = unreachable_modules(root)
    assert not orphans, f"modules lake will never build: {orphans}"
    print(
        "reachability: every module under lean/Singular is reachable from the library root"
    )

    binary = args.binary or root / ".lake/build/bin/singular-corpus"
    corpus = json.loads(subprocess.check_output([str(binary)]))
    sources = {}
    for rel in GENERIC_SOURCES:
        data = (root / rel).read_bytes()
        if rel == "lean/Singular.lean":
            # The generic library may differ from its base only by `import
            # Singular.Naming*` lines; hash the base form so the frozen generic
            # corpus stays byte-reproducible. Any other edit drifts.
            data = NAMING_IMPORT.sub("", data.decode()).encode()
        sources[rel] = digest(data)
    corpus_envelope(
        corpus,
        sources,
        generic_manifest_path,
        "statementsSha256",
        "lean/Singular/Statements.lean",
        "lean/Singular/Model.lean",
        "lean/Main.lean",
    )
    ids = [c["id"] for c in corpus["cases"]]
    assert len(set(ids)) == len(ids)
    families = {i[:2] for i in ids}
    assert {"GA", "GR", "GD", "GC"} <= families, f"generic corpus families: {families}"
    for section in ("folds", "ada", "codec"):
        assert corpus[section], f"empty generic corpus section: {section}"
    assert corpus["configRoundtrip"] is True
    check_or_compare(
        root / "lean/corpus.json",
        json.dumps(corpus, indent=2, sort_keys=True) + "\n",
        args.export,
        "Lean corpus",
    )

    naming_binary = args.naming_binary or root / ".lake/build/bin/naming-corpus"
    naming_corpus = json.loads(subprocess.check_output([str(naming_binary)]))
    all_sources = {
        str(p.relative_to(root)): digest(p.read_bytes())
        for p in sorted((root / "lean").rglob("*.lean"))
    }
    corpus_envelope(
        naming_corpus,
        all_sources,
        naming_manifest_path,
        "namingStatementsSha256",
        "lean/Singular/NamingStatements.lean",
        "lean/Singular/Model.lean",
        "lean/NamingMain.lean",
    )
    naming_ids = [
        row["id"]
        for section in ("spellings", "queues", "folds", "steps", "resolves", "replays")
        for row in naming_corpus[section]
    ]
    assert len(set(naming_ids)) == len(naming_ids), "duplicate naming corpus identity"
    for section in ("spellings", "queues", "folds", "steps", "resolves", "replays"):
        assert naming_corpus[section], f"empty naming corpus section: {section}"
    assert {"NQ", "NF", "NS", "NRP"} <= {
        re.match(r"[A-Z]+", i).group(0) for i in naming_ids
    }
    check_or_compare(
        root / "lean/naming-corpus.json",
        json.dumps(naming_corpus, indent=2, sort_keys=True) + "\n",
        args.export,
        "naming corpus",
    )

    lifecycle_binary = (
        args.lifecycle_binary or root / ".lake/build/bin/lifecycle-corpus"
    )
    lifecycle_corpus = json.loads(subprocess.check_output([str(lifecycle_binary)]))
    assert lifecycle_corpus["schema"] == "singular-naming-lifecycle-corpus-v2"
    lifecycle_corpus["wireTheoremManifestSha256"] = digest(
        wire_manifest_path.read_bytes()
    )
    corpus_envelope(
        lifecycle_corpus,
        all_sources,
        lifecycle_manifest_path,
        "lifecycleStatementsSha256",
        "lean/Singular/NamingLifecycleStatements.lean",
        "lean/Singular/NamingLifecycle.lean",
        "lean/LifecycleMain.lean",
    )
    lifecycle_sections = ("steps", "recovery", "retirement", "initializations", "wire")
    lifecycle_ids = [
        row["id"] for section in lifecycle_sections for row in lifecycle_corpus[section]
    ]
    assert len(lifecycle_ids) == len(set(lifecycle_ids)), (
        "duplicate lifecycle corpus identity"
    )
    assert set(lifecycle_ids) == LIFECYCLE_IDS, (
        "exact lifecycle corpus identities differ"
    )
    check_or_compare(
        root / "lean/lifecycle-corpus.json",
        json.dumps(lifecycle_corpus, indent=2, sort_keys=True) + "\n",
        args.export,
        "lifecycle corpus",
    )

    # --- the generic model driver (#209 S01) ---------------------------------
    # Run the driver over the same source extent as the generic corpus, compare
    # its output byte-for-byte with the committed scenarios, then check what the
    # scenarios claim. The driver is the subject here: if it cannot run, no row
    # below can report anything, which is the intended shape of its absence.
    driver_binary = args.driver_binary or root / ".lake/build/bin/singular-driver"
    assert Path(driver_binary).exists(), (
        f"model driver binary missing: {driver_binary} — R01 is unimplemented, "
        "so no scenario, observation or translation row below can be established"
    )
    driver_corpus = json.loads(subprocess.check_output([str(driver_binary)]))
    assert driver_corpus["schema"] == DRIVER_SCHEMA, (
        f"driver corpus schema {driver_corpus['schema']!r} != {DRIVER_SCHEMA!r}"
    )
    # The driver's extent is the generic one plus its own producer: a change to
    # either moves the driver corpus identity.
    driver_sources = dict(sources)
    driver_sources["lean/DriverMain.lean"] = digest(
        (root / "lean/DriverMain.lean").read_bytes()
    )
    corpus_envelope(
        driver_corpus,
        driver_sources,
        generic_manifest_path,
        "statementsSha256",
        "lean/Singular/Statements.lean",
        "lean/Singular/Model.lean",
        "lean/DriverMain.lean",
    )
    statement_digests = {r["name"]: r["statementSha256"] for r in generic_records}
    accepted, refused, total = check_driver_scenarios(
        driver_corpus,
        generic_names,
        statement_digests,
        model_refusal_vocabulary(root),
        model_exits(root),
        model_retraction(root),
    )
    leaf_bytes, deltas = model_constants(root)
    transitions = model_transitions(root)
    derived = check_derived(driver_corpus, leaf_bytes, deltas, transitions)
    refusals = model_batch_refusals(root)
    unpaid = model_unpaid_reasons(root)
    settlement = model_reject_settlement(root)

    def run_batches(corpus):
        return check_batch_rows(
            corpus,
            generic_names,
            statement_digests,
            refusals,
            unpaid,
            transitions,
            deltas,
            leaf_bytes,
            settlement,
        )

    batch_rows, batch_derived = run_batches(driver_corpus)
    batch_fired = batch_controls(driver_corpus, refusals, run_batches, settlement)
    check_or_compare(
        root / "lean/driver-corpus.json",
        json.dumps(driver_corpus, indent=2, sort_keys=True) + "\n",
        args.export,
        "driver corpus",
    )
    mapped, unobservable, identities = check_translation(root, driver_corpus["surface"])
    print(
        f"driver: {total} scenarios ({accepted} accepted, {refused} refused) over "
        f"{len(driver_corpus['surface']['operations'])} declared operations and "
        f"{len(driver_corpus['surface']['observations'])} declared observations"
    )
    print(
        f"derived: {derived} observations re-derived from the model rather than trusted "
        f"(roots, leaves and R2 mints)"
    )
    print(
        f"batches: {batch_rows} batch rows over "
        f"{len(driver_corpus['surface']['batchQuestions'])} declared questions, "
        f"{batch_derived} answers re-derived, {batch_fired} mutant controls refused"
    )
    print(
        f"translation: {mapped} declarations realized in the constitution, "
        f"{identities} identity rules, {unobservable} named unobservable fields"
    )

    # X2 — the theorem page must equal the generic manifest exactly: every
    # declaration present, no phantoms, and the stated total derived from the
    # manifest rather than asserted. This is the check whose absence let a
    # three-row gap survive a release.
    page = (root / "docs/theorems.md").read_text()
    listed = set(re.findall(r"`(Singular\.[A-Za-z0-9_.]+)`", page))
    assert listed == generic_names, (
        f"theorems page != manifest; page-only: {sorted(listed - generic_names)}; "
        f"manifest-only: {sorted(generic_names - listed)}"
    )
    m = re.search(r"All (\d+) declarations", page)
    assert m, "theorems page states no declaration total"
    assert int(m.group(1)) == len(generic_names), (
        f"theorems page total {m.group(1)} != manifest {len(generic_names)}"
    )
    print(
        f"X2: theorems page == generic manifest ({len(generic_names)} declarations, "
        f"total derived)"
    )

    # X3 — the README states the same counts in prose, so it drifts whenever a
    # manifest grows unless it is held to the manifests the way the theorem page
    # is. It stated 42 as 24 + 7 + 6 + 5 while the manifests held 63.
    readme = (root / "README.md").read_text()
    m = re.search(
        r"\*\*(\d+)\*\* proved declarations — (\d+) for the registry, (\d+) for the "
        r"naming instance, (\d+) for its lifecycle and (\d+) for its wire encoding",
        readme,
    )
    assert m, "README states no declaration counts in the checked form"
    stated = tuple(int(g) for g in m.groups())
    expected = (
        len(generic_names) + len(naming_names) + len(lifecycle_names) + len(wire_names),
        len(generic_names),
        len(naming_names),
        len(lifecycle_names),
        len(wire_names),
    )
    assert stated == expected, (
        f"README declaration counts {stated} != manifests {expected}"
    )
    print(f"X3: README declaration counts == manifests {expected}")

    print(
        f"model-check: {len(ids)} executable corpus rows; {len(naming_ids)} naming rows; "
        f"{len(lifecycle_ids)} lifecycle rows; "
        f"model {corpus['modelSha256'][:12]}"
    )


if __name__ == "__main__":
    main()
