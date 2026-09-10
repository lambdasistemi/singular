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
    'lean/Singular/Lemmas.lean',
    'lean/Singular/Model.lean',
    'lean/Singular/Statements.lean',
]

NAMING_IMPORT = re.compile(r'^import Singular\.Naming\w*\n?', re.M)

LIFECYCLE_IDS = {
    'LC01-cancellation-stored-refund-accepts', 'LC02-cancellation-redirect-refused',
    'LC03-insert-attestation-cancellation-refused',
    'LC04-folded-claim-cancellation-refused', 'LC06-cancellation-replay-refused',
    'LI01-canonical-initialization-accepts', 'LI02-alternate-seed-refused',
    'LI03-second-seed-rival-registry-refused', 'LI04-substituted-registry-refused',
    'LI05-substituted-policy-refused', 'LI06-repeated-canonical-seed-refused',
    'LI07-substituted-representative-policy-refused',
    'LI08-substituted-validator-script-refused',
    'LM01-maintenance-accepts', 'LM02-maintenance-unauthorized-refused',
    'LM03-maintenance-field-tamper-refused', 'LM04-maintenance-quorum-alteration-refused',
    'LO01-retirement-pending-visible',
    'LO02-retirement-over-visible', 'LR01-recovery-accepts',
    'LR02-wrong-reveal-refused', 'LR03-missing-recovery-signer-refused',
    'LR04-recovery-replay-refused', 'LR05-old-controller-refused',
    'LR06-forged-public-digest-refused', 'LR07-wrong-payment-key-signer-refused',
    'LR08-missing-fresh-commitment-refused', 'LR09-representative-tamper-refused',
    'LR10-registry-tamper-refused', 'LR11-quorum-tamper-refused',
    'LT01-controller-retirement-accepts',
    'LT02-quorum-retirement-accepts', 'LT03-insufficient-quorum-refused',
    'LT04-retirement-completes', 'LX01-re-registration-after-over-refused',
    'LT05-quorum-control-takeover-refused',
    'LT06-quorum-payment-redirection-refused', 'LT07-retirement-withdrawal-refused',
    'LT08-wrong-retirement-custody-refused', 'LT09-retirement-replay-refused',
    'WD01-four-field-roundtrip', 'WD02-datum-hash-refused',
    'WD03-two-destinations-refused', 'WR01-insert-request-refund-roundtrip',
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--naming-binary', type=Path)
    parser.add_argument('--lifecycle-binary', type=Path)
    parser.add_argument('--axioms-report', type=Path, help='saved output of `lake env lean tools/axioms.lean`')
    parser.add_argument('--export', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()

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
    ids = [c['case']['id'] for c in corpus['cases']] + [c['id'] for c in corpus['resolutions']]
    assert len(set(ids)) == len(ids)
    assert {f'S{i:02}' for i in range(1, 22)} <= {i[:3] for i in ids}
    assert {f'N{i:02}' for i in range(1, 8)} <= {i[:3] for i in ids}
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
    assert {'SP', 'NQ', 'NF', 'NS', 'NR', 'NRP'} <= {re.match(r'[A-Z]+', i).group(0) for i in naming_ids}
    check_or_compare(root / 'lean/naming-corpus.json', json.dumps(naming_corpus, indent=2, sort_keys=True) + '\n',
                     args.export, 'naming corpus')

    lifecycle_binary = args.lifecycle_binary or root / '.lake/build/bin/lifecycle-corpus'
    lifecycle_corpus = json.loads(subprocess.check_output([str(lifecycle_binary)]))
    assert lifecycle_corpus['schema'] == 'singular-naming-lifecycle-corpus-v1'
    lifecycle_corpus['wireTheoremManifestSha256'] = digest(wire_manifest_path.read_bytes())
    corpus_envelope(lifecycle_corpus, all_sources, lifecycle_manifest_path,
                    'lifecycleStatementsSha256', 'lean/Singular/NamingLifecycleStatements.lean',
                    'lean/Singular/NamingLifecycle.lean', 'lean/LifecycleMain.lean')
    lifecycle_ids = [row['id'] for section in ('steps', 'resolutions', 'initializations', 'registrations', 'wire')
                     for row in lifecycle_corpus[section]]
    assert len(lifecycle_ids) == len(set(lifecycle_ids)), 'duplicate lifecycle corpus identity'
    assert set(lifecycle_ids) == LIFECYCLE_IDS, 'exact lifecycle corpus identities differ'
    check_or_compare(root / 'lean/lifecycle-corpus.json',
                     json.dumps(lifecycle_corpus, indent=2, sort_keys=True) + '\n',
                     args.export, 'lifecycle corpus')

    print(f'model-check: {len(ids)} executable corpus rows; {len(naming_ids)} naming rows; '
          f'{len(lifecycle_ids)} lifecycle rows; '
          f'model {corpus["modelSha256"][:12]}')


if __name__ == '__main__':
    main()
