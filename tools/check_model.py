#!/usr/bin/env python3
"""Execute Lean's finite oracles and enforce the exact source-derived theorem manifests.

The source inventory establishes declaration identities and proof status. The compiled
axiom report, produced by `Singular.Audit` and `Singular.NamingAudit`, is cross-checked
against both manifests so that a declaration reported PROVED is one Lean elaborated from
the standard axioms alone.

Two corpora are enforced. The generic corpus is frozen: it must reproduce byte-for-byte
from the generic binary over the generic source extent, where `lean/Singular.lean` counts
in its base form — the current file may differ from that base only by `import
Singular.Naming*` lines (the naming layer hangs off the generic library by imports and
nothing else). The naming corpus is checked the same way over the full current Lean
extent, so every naming module is hash-bound to the exported evidence.
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
    parser.add_argument('--axioms-report', type=Path, help='saved output of `lake env lean tools/axioms.lean`')
    parser.add_argument('--export', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()

    audit_sources(root)
    generic_records = statement_inventory(root / 'lean/Singular/Statements.lean', 'Singular.Statements.')
    naming_records = statement_inventory(root / 'lean/Singular/NamingStatements.lean', 'Singular.NamingStatements.')
    generic_names = {r['name'] for r in generic_records}
    naming_names = {r['name'] for r in naming_records}
    assert not generic_names & naming_names, 'naming declarations collide with the generic inventory'

    generic_manifest_path = root / 'lean/theorem-debt.json'
    naming_manifest_path = root / 'lean/naming-theorem-debt.json'
    if args.export:
        generic_manifest_path.write_text(json.dumps(generic_records, indent=2) + '\n')
        naming_manifest_path.write_text(json.dumps(naming_records, indent=2) + '\n')
    generic_manifest = json.loads(generic_manifest_path.read_text())
    naming_manifest = json.loads(naming_manifest_path.read_text())
    assert generic_records == generic_manifest, 'exact named theorem/debt manifest mismatch'
    assert naming_records == naming_manifest, 'exact named naming theorem/debt manifest mismatch'

    report = axiom_report(root, args.axioms_report)
    assert set(report) == generic_names | naming_names, 'compiled report names differ from the manifests'
    check_records(generic_records, report, 'model-check')
    check_records(naming_records, report, 'naming-check')

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

    print(f'model-check: {len(ids)} executable corpus rows; {len(naming_ids)} naming rows; '
          f'model {corpus["modelSha256"][:12]}')


if __name__ == '__main__':
    main()
