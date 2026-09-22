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
import hashlib
import json
from pathlib import Path
import re
import subprocess

STANDARD = {'propext', 'Classical.choice', 'Quot.sound'}

# The frozen generic corpus source extent, in rglob order. Naming modules join the
# naming corpus's extent instead; they must never widen this one.
GENERIC_SOURCES = [
    'lean/Main.lean',
    'lean/Singular.lean',
    'lean/Singular/Audit.lean',
    'lean/Singular/Driver.lean',
    'lean/Singular/Lemmas.lean',
    'lean/Singular/Model.lean',
    'lean/Singular/Statements.lean',
]

NAMING_IMPORT = re.compile(r'^import Singular\.Naming\w*\n?', re.M)

LIFECYCLE_IDS = {
    'LM01-maintenance-accepts', 'LM02-maintenance-unauthorized-refused',
    'LM03-maintenance-field-tamper-refused', 'LM04-root-equal-after-maintenance',
    'LR01-recovery-accepts', 'LR02-wrong-reveal-refused',
    'LR03-missing-recovery-signer-refused',
    'LR05-old-controller-dead-after-recovery',
    'LR06-forged-public-digest-refused', 'LR11-root-equal-after-recovery',
    'LT02-quorum-retirement-accepts', 'LT03-insufficient-quorum-refused',
    'LT04-retirement-completes', 'LT08-control-key-alone-refused',
    'LI01-canonical-initialization-accepts', 'LI02-alternate-seed-refused',
    'LI05-substituted-active-policy-refused',
    'LI06-substituted-terminal-policy-refused',
    'LI07-substituted-registry-refused',
    'WD01-fixture-datum-roundtrip', 'WD02-two-destinations-refused',
}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def audit_sources(root):
    """Keyword and proof-hole audit over every Lean source, generic and naming."""
    for path in sorted((root / 'lean').rglob('*.lean')):
        source = path.read_text()
        # This bounded source grammar disallows nested block comments and escape hatches.
        clean = re.sub(r'/\-.*?\-/', '', source, flags=re.S)
        clean = re.sub(r'--[^\n]*', '', clean)
        clean = re.sub(r'"(?:\\.|[^"\\])*"', '""', clean)
        assert not re.search(r'\b(axiom|admit|unsafe|implemented_by|extern)\b', clean), path
        if path.name != 'Statements.lean':
            assert not re.search(r'\bsorry\b', clean), f'proof hole outside the frozen module: {path}'


def statement_inventory(path, prefix):
    """Parse one statements module into exact declaration identities."""
    source = path.read_text()
    clean = re.sub(r'/\-.*?\-/', '', source, flags=re.S)
    clean = re.sub(r'--[^\n]*', '', clean)
    clean = re.sub(r'"(?:\\.|[^"\\])*"', '""', clean)
    declarations = list(re.finditer(
        r'(?ms)^theorem ([A-Za-z0-9_]+)\b(.*?) := by\b(.*?)(?=^(?:set_option[^\n]*\bin\n)?theorem |^end )',
        clean))
    assert len(declarations) == len(re.findall(r'\btheorem\b', clean)), f'unrecognized theorem grammar: {path}'
    records = []
    for match in declarations:
        name = prefix + match[1]
        admitted = re.search(r'\bsorry\b', match[3]) is not None
        records.append({'name': name, 'status': 'STATED' if admitted else 'PROVED',
                        'debt': 'sorryAx' if admitted else 'none',
                        'statementSha256': digest((match[1] + match[2]).encode())})
    assert records and len({r['name'] for r in records}) == len(records)
    return records


def axiom_report(root, path):
    text = path.read_text() if path else subprocess.check_output(
        ['lake', 'env', 'lean', 'tools/axioms.lean'], cwd=root, text=True)
    report = {}
    for line in text.splitlines():
        if line.startswith('AXIOMS '):
            _, name, axioms = line.split(' ', 2)
            report[name] = set(re.findall(r'[A-Za-z_][A-Za-z0-9_.]*', axioms))
    assert report, 'empty compiled axiom report'
    return report


def check_records(records, report, label):
    for record in records:
        axioms = report[record['name']]
        if record['status'] == 'PROVED':
            assert axioms <= STANDARD, f'{record["name"]} depends on {sorted(axioms - STANDARD)}'
        else:
            assert 'sorryAx' in axioms, f'{record["name"]} is admitted in source but not in the compiled report'
    print(f'{label}: {sum(r["status"] == "PROVED" for r in records)}/{len(records)} '
          f'exact identities PROVED from {sorted(STANDARD)}')


def corpus_envelope(corpus, sources, manifest_path, statements_key, statements_source,
                    model_source, corpus_source):
    corpus['sourceHashes'] = sources
    corpus['modelSha256'] = sources[model_source]
    corpus[statements_key] = sources[statements_source]
    corpus['corpusSourceSha256'] = sources[corpus_source]
    corpus['theoremManifestSha256'] = digest(manifest_path.read_bytes())
    corpus['payloadSha256'] = digest(json.dumps({k: v for k, v in corpus.items() if k != 'payloadSha256'}, sort_keys=True, separators=(',', ':')).encode())
    return corpus


def check_or_compare(target, encoded, export, label):
    if export:
        target.write_text(encoded)
        print(f'{label}: exported')
    else:
        assert target.read_text() == encoded, f'{label} identity drift'


def unreachable_modules(root):
    """Modules on disk that `lake build` will never build.

    The library root is the only entry point lake follows, so a module nobody
    imports is never compiled — and a stale `.olean` from an earlier build makes
    that invisible to every local check, including one that elaborates a file
    importing it. `Singular.NamingAudit` sat unreachable this way: the naming
    axiom gate was in the tree, passing locally, and absent from a clean build.
    The extent is read off the directory, never listed here.
    """
    seen, pending = set(), ['Singular']
    while pending:
        module = pending.pop()
        if module in seen:
            continue
        seen.add(module)
        source = root / 'lean' / (module.replace('.', '/') + '.lean')
        if not source.exists():
            continue
        for line in source.read_text(encoding='utf-8').splitlines():
            if line.startswith('import Singular'):
                pending.append(line.split()[1])
    on_disk = {'Singular.' + f.stem for f in sorted((root / 'lean/Singular').glob('*.lean'))}
    assert on_disk, 'EMPTY EXTENT: no modules discovered under lean/Singular'
    return sorted(on_disk - seen)




# ---------------------------------------------------------------------------
# The generic model driver (#209 S01, R01-R04).
#
# The driver is one executable over the model's own law: given a scenario it
# runs `Singular.step` and reports the declared boundary observations of what
# the law actually did. These checks exist so that the four ways of faking that
# are detected rather than reported as conformance.
# ---------------------------------------------------------------------------

REFUSAL_LITERAL = re.compile(r'"([a-z]+(?:-[a-z]+)+)"')


def model_refusal_vocabulary(root):
    """Every refusal reason `Singular.refusal` can produce, read off the model.

    The expected value is obtained from the producer rather than typed here, so
    a reason the model cannot say — an infrastructure error dressed up as a
    ledger refusal — has nowhere to hide. The subject of the assertion is the
    driver's executed output; this only supplies the vocabulary it is held to.
    """
    source = (root / 'lean/Singular/Model.lean').read_text(encoding='utf-8')
    body = source.split('\ndef refusal ', 1)[1].split('\n/--', 1)[0]
    vocabulary = set(REFUSAL_LITERAL.findall(body))
    assert vocabulary, 'EMPTY EXTENT: no refusal reasons discovered in Singular.refusal'
    return vocabulary

DRIVER_SCHEMA = 'singular-driver-corpus-v1'

# The outcome classes a scenario may land in. `accepted` and `refused` are the
# model speaking; `unsupported` is the driver saying it cannot reach the case.
# A crashed driver produces none of these, which is the point: an execution
# failure can never be read as a domain refusal.
DRIVER_OUTCOMES = {'accepted', 'refused', 'unsupported'}


def driver_surface(corpus):
    """The declared boundary: what the driver says it can do and see."""
    surface = corpus['surface']
    for field in ('declaration', 'definitionDigest', 'protocolVersion',
                  'operations', 'observations', 'unobservable'):
        assert field in surface, f'driver surface omits {field} (D01)'
    assert surface['operations'], 'EMPTY EXTENT: driver declares no operations'
    assert surface['observations'], 'EMPTY EXTENT: driver declares no observations'
    return surface


def check_driver_scenarios(corpus, generic_names, statement_digests, vocabulary):
    """R01-R03 over every scenario the driver executed.

    R01 is the one that needs saying out loud: a scenario's observations must
    cover the WHOLE declared boundary. A per-theorem projection — a row that
    reports only the two fields its own theorem happens to talk about — is
    exactly the substitution the requirement forbids, and it is caught here by
    comparing each accepted row's observation keys against the declared set
    rather than against the theorem's interest.
    """
    surface = driver_surface(corpus)
    declared = set(surface['observations'])
    scenarios = corpus['scenarios']
    assert scenarios, 'EMPTY EXTENT: driver corpus carries no scenarios'

    ids = [s['id'] for s in scenarios]
    assert len(set(ids)) == len(ids), 'duplicate driver scenario identity'

    seen_outcomes = set()
    accepted = refused = 0
    for s in scenarios:
        sid = s['id']
        outcome = s['outcome']
        assert outcome in DRIVER_OUTCOMES, f'{sid}: unknown outcome class {outcome!r}'
        seen_outcomes.add(outcome)

        # R02 — the scenario is bound to a theorem that exists, at the digest
        # the manifest records. A stale binding names a real theorem whose
        # statement has since changed; comparing digests is what catches it.
        assert s['operation'] in surface['operations'], \
            f'{sid}: operation {s["operation"]!r} is not a declared operation (D01)'
        theorem = s['theorem']
        assert theorem in generic_names, f'{sid}: unknown theorem binding {theorem}'
        assert s['statementSha256'] == statement_digests[theorem], \
            f'{sid}: stale theorem binding — {theorem} statement digest moved'

        # R02 — a setup trace is a trace of accepted transitions. A scenario
        # that needs a non-empty starting state must have REACHED it by running
        # the law, not by being handed a constructed state.
        for i, stp in enumerate(s['setup']):
            assert stp['accepted'] is True, \
                f'{sid}: setup step {i} was not an accepted transition ' \
                f'({stp.get("reason")!r}); a refused setup cannot establish a starting state'
        if s['requiresReachableState']:
            assert s['setup'], \
                f'{sid}: claims a reachable non-initial starting state with an empty setup trace'

        if outcome == 'accepted':
            accepted += 1
            # R03 — a checked law premise precedes an accepted observation.
            premise = s['premise']
            assert premise['checked'] is True, \
                f'{sid}: accepted without checking its law premise'
            assert premise['declaration'].startswith('Singular.'), \
                f'{sid}: premise {premise["declaration"]!r} is not a model declaration'
            # R01 — the complete declared boundary, not a projection of it.
            observed = set(s['observations'])
            assert observed == declared, (
                f'{sid}: observations are a projection of the declared boundary; '
                f'missing {sorted(declared - observed)}, undeclared {sorted(observed - declared)}')
            assert s['reason'] is None, f'{sid}: accepted rows carry no refusal reason'
        elif outcome == 'refused':
            refused += 1
            # R03 — a refusal is the model's, with the model's own words.
            assert s['reason'], f'{sid}: refused with no reason'
            assert s['reason'] in vocabulary, (
                f'{sid}: refusal reason {s["reason"]!r} is not one the model can produce; '
                f'a transport or process failure is an execution failure, never a ledger refusal')
            assert s['observations'] is None, \
                f'{sid}: refused rows observe nothing — there was no transition to observe'
            # A refusal is the LAW saying no, which means the law ran, which
            # means its premise held on the state it ran against. A refusal
            # reported without a checked premise is the driver failing to reach
            # the case, and that is `unsupported`, not a ledger refusal.
            assert s['premise']['checked'] is True, \
                f'{sid}: refused without establishing the premise the law was applied under'
        else:
            # `unsupported` carries no premise constraint on purpose: it covers
            # a setup that would not run and a premise that does not hold (both
            # unestablished) as well as a transaction the model cannot build
            # from an accepted step (established). What makes it distinct is
            # that it observes nothing and says what it could not reach.
            assert s['reason'], f'{sid}: unsupported rows must name what is unsupported'
            assert s['observations'] is None, f'{sid}: unsupported rows observe nothing'

    # Each class must actually occur, or the classification is untested.
    assert accepted, 'driver corpus contains no accepted transition'
    assert refused, 'driver corpus contains no domain refusal'
    assert {'accepted', 'refused'} <= seen_outcomes, \
        f'driver outcome classes exercised: {sorted(seen_outcomes)}'

    # R02 — a mutant is only a mutant relative to the witness it perturbs.
    witnesses = {s['id'] for s in scenarios if s['kind'] == 'witness'}
    for s in scenarios:
        if s['kind'] == 'mutant':
            assert s['mutates'] in witnesses, \
                f'{s["id"]}: mutant of unknown witness {s["mutates"]!r}'
            assert s['mutates'] != s['id'], f'{s["id"]}: mutant of itself'
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

STATE_BYTE_ARM = re.compile(r'\| \.(\w+) => (0x[0-9A-Fa-f]+)')
UNKNOWN_BYTE = re.compile(r'\| \.unknown => (0x[0-9A-Fa-f]+)')
DELTA_ARM = re.compile(r'^\s*\| \.(\w+) => \[(.*)\]$', re.M)
TRANSITION_ARM = re.compile(
    r'^\s*\| \.(\w+), (\.unknown|\.known \.\w+) => some (\(\.known \.\w+\)|\.unknown)$', re.M)


def leaf_name(spelling):
    """A Lean leaf spelling as the corpus writes it: `null` for an unbound key."""
    spelling = spelling.strip('()')
    return None if spelling == '.unknown' else spelling.split('.')[-1]
DELTA_CELL = re.compile(r'\(\.(\w+), (-?\d+)\)')


def model_constants(root):
    """The leaf byte table and the R2 delta table, read off the model."""
    source = (root / 'lean/Singular/Model.lean').read_text(encoding='utf-8')
    state_body = source.split('\ndef stateByte ', 1)[1].split('\n/--', 1)[0]
    leaf_bytes = {name: int(value, 16) for name, value in STATE_BYTE_ARM.findall(state_body)}
    assert leaf_bytes, 'EMPTY EXTENT: no state bytes discovered in Singular.stateByte'
    leaf_body = source.split('\ndef leafByte ', 1)[1].split('\n/--', 1)[0]
    unknown = UNKNOWN_BYTE.search(leaf_body)
    assert unknown, 'Singular.leafByte states no byte for an unbound key'
    leaf_bytes[None] = int(unknown.group(1), 16)

    delta_body = source.split('\ndef delta (e : Edge)', 1)[1].split('\n/--', 1)[0]
    deltas = {edge: [(kind, int(qty)) for kind, qty in DELTA_CELL.findall(cells)]
              for edge, cells in DELTA_ARM.findall(delta_body)}
    assert deltas, 'EMPTY EXTENT: no delta rows discovered in Singular.delta'
    return leaf_bytes, deltas


def model_transitions(root):
    """The R2 from-to column, read off `Singular.transition`.

    This is the law's core, and re-deriving the expected after-leaf from it is
    what separates a transition that happened from a driver reporting a state.
    An internally consistent row that simply echoes its starting state passes
    every other check here and fails this one.
    """
    source = (root / 'lean/Singular/Model.lean').read_text(encoding='utf-8')
    body = source.split('\ndef transition (e : Edge) (before : Leaf)', 1)[1].split('\n/--', 1)[0]
    table = {(edge, leaf_name(before)): leaf_name(after)
             for edge, before, after in TRANSITION_ARM.findall(body)}
    assert table, 'EMPTY EXTENT: no transitions discovered in Singular.transition'
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
    for entry in sorted(trie, key=lambda e: e['key']):
        key = entry['key'] & 0xFF
        data += u64bytes(fnv1a([key])) + [key, leaf_bytes[entry['leaf']]]
    return u64bytes(fnv1a(data))


def check_derived(corpus, leaf_bytes, deltas, transitions):
    """Re-derive what the law must have produced, for every row.

    Every state the driver reports — each setup step's, and an accepted row's
    result — must carry the root the model's commitment function gives for its
    own trie. That binds the whole trace to real execution, including a refused
    row, whose starting state had to be reached by running the law.
    """
    derived = 0
    for s in corpus['scenarios']:
        sid = s['id']
        states = [('start', s['start'])]
        states += [(f'setup step {i}', stp['state']) for i, stp in enumerate(s['setup'])
                   if stp['accepted']]
        if s['observations'] is not None:
            states.append(('result', s['observations']['state']))
        for where, state in states:
            expected = root_of(state['trie'], leaf_bytes)
            assert state['config']['root'] == expected, (
                f'{sid}: {where} reports a root the model does not commit to for its own '
                f'trie — the state was not produced by executing the law')
            derived += 1
        if s['observations'] is None:
            continue

        obs = s['observations']
        assert obs['root'] == obs['config']['root'], \
            f'{sid}: the reported root and the config root disagree'
        key = s['request']['key']
        leaf = next((e['leaf'] for e in obs['state']['trie'] if e['key'] == key), None)
        assert obs['leaf'] == leaf, (
            f'{sid}: reports leaf {obs["leaf"]!r} while its own produced trie holds '
            f'{leaf!r} at key {key}')

        # The transition itself, derived from the model's R2 table rather than
        # read back off the row: the state the law was applied to decides what
        # the leaf must now be. A row that echoes its own starting state is
        # internally consistent and fails here.
        before = s['setup'][-1]['state'] if s['setup'] else s['start']
        before_leaf = next((e['leaf'] for e in before['trie'] if e['key'] == key), None)
        assert (s['operation'], before_leaf) in transitions, (
            f'{sid}: accepted {s["operation"]} on a {before_leaf!r} leaf, which the R2 '
            f'table refuses')
        expected_leaf = transitions[(s['operation'], before_leaf)]
        assert obs['leaf'] == expected_leaf, (
            f'{sid}: {s["operation"]} on a {before_leaf!r} leaf must produce '
            f'{expected_leaf!r}; the row reports {obs["leaf"]!r}')
        derived += 1

        # The mint is the edge's R2 row, keyed by the request's key, named by
        # the registry's pinned policy for the kind.
        policies = {'active': obs['config']['activePolicy'],
                    'absent': obs['config']['absentPolicy'],
                    'terminal': obs['config']['terminalPolicy']}
        expected_mint = [{'kind': kind, 'key': key, 'quantity': qty,
                          'policy': policies[kind], 'assetName': key}
                         for kind, qty in deltas[s['operation']]]
        actual_mint = [{k: m[k] for k in ('kind', 'key', 'quantity', 'policy', 'assetName')}
                       for m in obs['mint']]
        assert actual_mint == expected_mint, (
            f'{sid}: mint {actual_mint} is not the R2 delta of {s["operation"]} at key '
            f'{key}, which is {expected_mint}')
        assert obs['tx']['mint'] == obs['mint'], \
            f'{sid}: the transaction mints something other than the executed step did'
        derived += 3
    assert derived, 'EMPTY EXTENT: nothing was independently derived'
    return derived

TRANSLATION_HEADING = '## The model driver translation'
TRANSLATION_ROW = re.compile(r'^\| `?([^|`]+?)`? \| (realization|identity|unobservable) \| (.+?) \|$', re.M)


def check_translation(root, surface):
    """R04 — the constitution states the concrete realization of every declared
    law and observation, the identity rules, and the named unobservable fields.

    Mechanical reconciliation only, in both directions: a declared name with no
    row fails, and a row naming something the driver does not declare fails.
    Whether a stated realization is TRUE is a semantic review, not this check,
    and this check must never be read as establishing it.
    """
    text = (root / '.specify/memory/constitution.md').read_text(encoding='utf-8')
    assert TRANSLATION_HEADING in text, \
        f'the constitution states no model driver translation ({TRANSLATION_HEADING!r} absent) — R04'
    section = text.split(TRANSLATION_HEADING, 1)[1]
    rows = {}
    for name, kind, body in TRANSLATION_ROW.findall(section):
        assert body.strip(), f'translation row {name} states nothing'
        rows.setdefault(kind, {})[name] = body.strip()

    declared = set(surface['operations']) | set(surface['observations'])
    stated = set(rows.get('realization', {}))
    assert stated == declared, (
        'constitutional translation does not reconcile with the declared surface; '
        f'undeclared rows: {sorted(stated - declared)}; '
        f'unmapped declarations: {sorted(declared - stated)}')

    named_unobservable = set(rows.get('unobservable', {}))
    assert named_unobservable == set(surface['unobservable']), (
        'named unobservable fields differ between the driver surface and the constitution; '
        f'constitution-only: {sorted(named_unobservable - set(surface["unobservable"]))}; '
        f'driver-only: {sorted(set(surface["unobservable"]) - named_unobservable)}')
    assert rows.get('identity'), 'the translation states no identity rules (D05, R04)'
    return len(declared), len(named_unobservable), len(rows['identity'])

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--naming-binary', type=Path)
    parser.add_argument('--lifecycle-binary', type=Path)
    parser.add_argument('--driver-binary', type=Path)
    parser.add_argument('--axioms-report', type=Path, help='saved output of `lake env lean tools/axioms.lean`')
    parser.add_argument('--export', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()

    # Name the source that actually ran, so a receipt cites the checker it
    # was produced by rather than the one someone assumed.
    print(f'provenance: check_model.py sha256={digest(Path(__file__).read_bytes())}')

    audit_sources(root)
    generic_records = statement_inventory(root / 'lean/Singular/Statements.lean', 'Singular.Statements.')
    naming_records = statement_inventory(root / 'lean/Singular/NamingStatements.lean', 'Singular.NamingStatements.')
    lifecycle_records = statement_inventory(root / 'lean/Singular/NamingLifecycleStatements.lean',
                                            'Singular.NamingLifecycleStatements.')
    wire_records = statement_inventory(root / 'lean/Singular/NamingWireStatements.lean',
                                       'Singular.NamingWireStatements.')
    generic_names = {r['name'] for r in generic_records}
    naming_names = {r['name'] for r in naming_records}
    lifecycle_names = {r['name'] for r in lifecycle_records}
    wire_names = {r['name'] for r in wire_records}
    assert not generic_names & naming_names and not generic_names & lifecycle_names \
        and not naming_names & lifecycle_names and not wire_names & (generic_names | naming_names | lifecycle_names), \
        'theorem declaration inventories collide'

    generic_manifest_path = root / 'lean/theorem-debt.json'
    naming_manifest_path = root / 'lean/naming-theorem-debt.json'
    lifecycle_manifest_path = root / 'lean/lifecycle-theorem-debt.json'
    wire_manifest_path = root / 'lean/wire-theorem-debt.json'
    if args.export:
        generic_manifest_path.write_text(json.dumps(generic_records, indent=2) + '\n')
        naming_manifest_path.write_text(json.dumps(naming_records, indent=2) + '\n')
        lifecycle_manifest_path.write_text(json.dumps(lifecycle_records, indent=2) + '\n')
        wire_manifest_path.write_text(json.dumps(wire_records, indent=2) + '\n')
    generic_manifest = json.loads(generic_manifest_path.read_text())
    naming_manifest = json.loads(naming_manifest_path.read_text())
    lifecycle_manifest = json.loads(lifecycle_manifest_path.read_text())
    wire_manifest = json.loads(wire_manifest_path.read_text())
    assert generic_records == generic_manifest, 'exact named theorem/debt manifest mismatch'
    assert naming_records == naming_manifest, 'exact named naming theorem/debt manifest mismatch'
    assert lifecycle_records == lifecycle_manifest, 'exact named lifecycle theorem/debt manifest mismatch'
    assert wire_records == wire_manifest, 'exact named wire theorem/debt manifest mismatch'

    report = axiom_report(root, args.axioms_report)
    assert set(report) == generic_names | naming_names | lifecycle_names | wire_names, 'compiled report names differ from the manifests'
    check_records(generic_records, report, 'model-check')
    check_records(naming_records, report, 'naming-check')
    check_records(lifecycle_records, report, 'lifecycle-check')
    check_records(wire_records, report, 'wire-check')

    orphans = unreachable_modules(root)
    assert not orphans, f'modules lake will never build: {orphans}'
    print(f'reachability: every module under lean/Singular is reachable from the library root')

    binary = args.binary or root / '.lake/build/bin/singular-corpus'
    corpus = json.loads(subprocess.check_output([str(binary)]))
    sources = {}
    for rel in GENERIC_SOURCES:
        data = (root / rel).read_bytes()
        if rel == 'lean/Singular.lean':
            # The generic library may differ from its base only by `import
            # Singular.Naming*` lines; hash the base form so the frozen generic
            # corpus stays byte-reproducible. Any other edit drifts.
            data = NAMING_IMPORT.sub('', data.decode()).encode()
        sources[rel] = digest(data)
    corpus_envelope(corpus, sources, generic_manifest_path,
                    'statementsSha256', 'lean/Singular/Statements.lean',
                    'lean/Singular/Model.lean', 'lean/Main.lean')
    ids = [c['id'] for c in corpus['cases']]
    assert len(set(ids)) == len(ids)
    families = {i[:2] for i in ids}
    assert {'GA', 'GR', 'GD', 'GC'} <= families, f'generic corpus families: {families}'
    for section in ('folds', 'ada', 'codec'):
        assert corpus[section], f'empty generic corpus section: {section}'
    assert corpus['configRoundtrip'] is True
    check_or_compare(root / 'lean/corpus.json', json.dumps(corpus, indent=2, sort_keys=True) + '\n',
                     args.export, 'Lean corpus')

    naming_binary = args.naming_binary or root / '.lake/build/bin/naming-corpus'
    naming_corpus = json.loads(subprocess.check_output([str(naming_binary)]))
    all_sources = {str(p.relative_to(root)): digest(p.read_bytes())
                   for p in sorted((root / 'lean').rglob('*.lean'))}
    corpus_envelope(naming_corpus, all_sources, naming_manifest_path,
                    'namingStatementsSha256', 'lean/Singular/NamingStatements.lean',
                    'lean/Singular/Model.lean', 'lean/NamingMain.lean')
    naming_ids = [row['id'] for section in ('spellings', 'queues', 'folds', 'steps', 'resolves', 'replays')
                  for row in naming_corpus[section]]
    assert len(set(naming_ids)) == len(naming_ids), 'duplicate naming corpus identity'
    for section in ('spellings', 'queues', 'folds', 'steps', 'resolves', 'replays'):
        assert naming_corpus[section], f'empty naming corpus section: {section}'
    assert {'NQ', 'NF', 'NS', 'NRP'} <= {re.match(r'[A-Z]+', i).group(0) for i in naming_ids}
    check_or_compare(root / 'lean/naming-corpus.json', json.dumps(naming_corpus, indent=2, sort_keys=True) + '\n',
                     args.export, 'naming corpus')

    lifecycle_binary = args.lifecycle_binary or root / '.lake/build/bin/lifecycle-corpus'
    lifecycle_corpus = json.loads(subprocess.check_output([str(lifecycle_binary)]))
    assert lifecycle_corpus['schema'] == 'singular-naming-lifecycle-corpus-v2'
    lifecycle_corpus['wireTheoremManifestSha256'] = digest(wire_manifest_path.read_bytes())
    corpus_envelope(lifecycle_corpus, all_sources, lifecycle_manifest_path,
                    'lifecycleStatementsSha256', 'lean/Singular/NamingLifecycleStatements.lean',
                    'lean/Singular/NamingLifecycle.lean', 'lean/LifecycleMain.lean')
    lifecycle_sections = ('steps', 'recovery', 'retirement', 'initializations', 'wire')
    lifecycle_ids = [row['id'] for section in lifecycle_sections
                     for row in lifecycle_corpus[section]]
    assert len(lifecycle_ids) == len(set(lifecycle_ids)), 'duplicate lifecycle corpus identity'
    assert set(lifecycle_ids) == LIFECYCLE_IDS, 'exact lifecycle corpus identities differ'
    check_or_compare(root / 'lean/lifecycle-corpus.json',
                     json.dumps(lifecycle_corpus, indent=2, sort_keys=True) + '\n',
                     args.export, 'lifecycle corpus')

    # --- the generic model driver (#209 S01) ---------------------------------
    # Run the driver over the same source extent as the generic corpus, compare
    # its output byte-for-byte with the committed scenarios, then check what the
    # scenarios claim. The driver is the subject here: if it cannot run, no row
    # below can report anything, which is the intended shape of its absence.
    driver_binary = args.driver_binary or root / '.lake/build/bin/singular-driver'
    assert Path(driver_binary).exists(), (
        f'model driver binary missing: {driver_binary} — R01 is unimplemented, '
        'so no scenario, observation or translation row below can be established')
    driver_corpus = json.loads(subprocess.check_output([str(driver_binary)]))
    assert driver_corpus['schema'] == DRIVER_SCHEMA, \
        f'driver corpus schema {driver_corpus["schema"]!r} != {DRIVER_SCHEMA!r}'
    # The driver's extent is the generic one plus its own producer: a change to
    # either moves the driver corpus identity.
    driver_sources = dict(sources)
    driver_sources['lean/DriverMain.lean'] = digest((root / 'lean/DriverMain.lean').read_bytes())
    corpus_envelope(driver_corpus, driver_sources, generic_manifest_path,
                    'statementsSha256', 'lean/Singular/Statements.lean',
                    'lean/Singular/Model.lean', 'lean/DriverMain.lean')
    statement_digests = {r['name']: r['statementSha256'] for r in generic_records}
    accepted, refused, total = check_driver_scenarios(
        driver_corpus, generic_names, statement_digests, model_refusal_vocabulary(root))
    leaf_bytes, deltas = model_constants(root)
    derived = check_derived(driver_corpus, leaf_bytes, deltas, model_transitions(root))
    check_or_compare(root / 'lean/driver-corpus.json',
                     json.dumps(driver_corpus, indent=2, sort_keys=True) + '\n',
                     args.export, 'driver corpus')
    mapped, unobservable, identities = check_translation(root, driver_corpus['surface'])
    print(f'driver: {total} scenarios ({accepted} accepted, {refused} refused) over '
          f'{len(driver_corpus["surface"]["operations"])} declared operations and '
          f'{len(driver_corpus["surface"]["observations"])} declared observations')
    print(f'derived: {derived} observations re-derived from the model rather than trusted '
          f'(roots, leaves and R2 mints)')
    print(f'translation: {mapped} declarations realized in the constitution, '
          f'{identities} identity rules, {unobservable} named unobservable fields')

    # X2 — the theorem page must equal the generic manifest exactly: every
    # declaration present, no phantoms, and the stated total derived from the
    # manifest rather than asserted. This is the check whose absence let a
    # three-row gap survive a release.
    page = (root / 'docs/theorems.md').read_text()
    listed = set(re.findall(r'`(Singular\.[A-Za-z0-9_.]+)`', page))
    assert listed == generic_names, (
        f'theorems page != manifest; page-only: {sorted(listed - generic_names)}; '
        f'manifest-only: {sorted(generic_names - listed)}')
    m = re.search(r'All (\d+) declarations', page)
    assert m, 'theorems page states no declaration total'
    assert int(m.group(1)) == len(generic_names), (
        f'theorems page total {m.group(1)} != manifest {len(generic_names)}')
    print(f'X2: theorems page == generic manifest ({len(generic_names)} declarations, '
          f'total derived)')

    print(f'model-check: {len(ids)} executable corpus rows; {len(naming_ids)} naming rows; '
          f'{len(lifecycle_ids)} lifecycle rows; '
          f'model {corpus["modelSha256"][:12]}')


if __name__ == '__main__':
    main()
