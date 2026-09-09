#!/usr/bin/env python3
"""Execute Lean's finite oracle and enforce the exact source-derived theorem manifest.

The source inventory establishes declaration identities and proof status. The compiled
axiom report, produced by `Singular.Audit`, is cross-checked against it so that a
declaration reported PROVED is one Lean elaborated from the standard axioms alone.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

STANDARD = {'propext', 'Classical.choice', 'Quot.sound'}


def digest(data):
    return hashlib.sha256(data).hexdigest()


def inventory(root):
    records = []
    for path in sorted((root / 'lean').rglob('*.lean')):
        source = path.read_text()
        # This bounded source grammar disallows nested block comments and escape hatches.
        clean = re.sub(r'/\-.*?\-/', '', source, flags=re.S)
        clean = re.sub(r'--[^\n]*', '', clean)
        clean = re.sub(r'"(?:\\.|[^"\\])*"', '""', clean)
        assert not re.search(r'\b(axiom|admit|unsafe|implemented_by|extern)\b', clean), path
        if path.name != 'Statements.lean':
            assert not re.search(r'\bsorry\b', clean), f'proof hole outside the frozen module: {path}'
            continue
        declarations = list(re.finditer(
            r'(?ms)^theorem ([A-Za-z0-9_]+)\b(.*?) := by\b(.*?)(?=^(?:set_option[^\n]*\bin\n)?theorem |^end )',
            clean))
        assert len(declarations) == len(re.findall(r'\btheorem\b', clean)), f'unrecognized theorem grammar: {path}'
        holes = 0
        for match in declarations:
            name = 'Singular.Statements.' + match[1]
            admitted = re.search(r'\bsorry\b', match[3]) is not None
            holes += admitted
            records.append({'name': name, 'status': 'STATED' if admitted else 'PROVED',
                            'debt': 'sorryAx' if admitted else 'none',
                            'statementSha256': digest((match[1] + match[2]).encode())})
        assert holes == len(re.findall(r'\bsorry\b', clean)), f'unlisted proof hole: {path}'
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--axioms-report', type=Path, help='saved output of `lake env lean tools/axioms.lean`')
    parser.add_argument('--export', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    records = inventory(root)
    manifest_path = root / 'lean/theorem-debt.json'
    if args.export:
        manifest_path.write_text(json.dumps(records, indent=2) + '\n')
    manifest = json.loads(manifest_path.read_text())
    assert records == manifest, 'exact named theorem/debt manifest mismatch'
    report = axiom_report(root, args.axioms_report)
    assert set(report) == {r['name'] for r in records}, 'compiled report names differ from the manifest'
    for record in records:
        axioms = report[record['name']]
        if record['status'] == 'PROVED':
            assert axioms <= STANDARD, f'{record["name"]} depends on {sorted(axioms - STANDARD)}'
        else:
            assert 'sorryAx' in axioms, f'{record["name"]} is admitted in source but not in the compiled report'
    binary = args.binary or root / '.lake/build/bin/singular-corpus'
    corpus = json.loads(subprocess.check_output([str(binary)]))
    sources = {str(p.relative_to(root)): digest(p.read_bytes()) for p in sorted((root / 'lean').rglob('*.lean'))}
    corpus['sourceHashes'] = sources
    corpus['modelSha256'] = sources['lean/Singular/Model.lean']
    corpus['statementsSha256'] = sources['lean/Singular/Statements.lean']
    corpus['corpusSourceSha256'] = sources['lean/Main.lean']
    corpus['theoremManifestSha256'] = digest(manifest_path.read_bytes())
    corpus['payloadSha256'] = digest(json.dumps({k:v for k,v in corpus.items() if k != 'payloadSha256'}, sort_keys=True, separators=(',', ':')).encode())
    ids = [c['case']['id'] for c in corpus['cases']] + [c['id'] for c in corpus['resolutions']]
    assert len(set(ids)) == len(ids)
    assert {f'S{i:02}' for i in range(1, 22)} <= {i[:3] for i in ids}
    assert {f'N{i:02}' for i in range(1, 8)} <= {i[:3] for i in ids}
    target = root / 'lean/corpus.json'
    encoded = json.dumps(corpus, indent=2, sort_keys=True) + '\n'
    if args.export:
        target.write_text(encoded)
    else:
        assert target.read_text() == encoded, 'Lean corpus/source identity drift'
    proved = sum(r['status'] == 'PROVED' for r in records)
    print(f'model-check: {proved}/{len(records)} exact identities PROVED from {sorted(STANDARD)}; '
          f'{len(ids)} executable corpus rows; model {corpus["modelSha256"]}')

if __name__ == '__main__':
    main()
