#!/usr/bin/env python3
"""Execute Lean's finite oracle and enforce exact source-derived statement debt.
The source inventory establishes identities and intentional holes, not proof truth.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


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
        declarations = list(re.finditer(r'(?m)^theorem ([A-Za-z0-9_]+)\b(.*?) := by sorry\s*', clean, re.S))
        assert len(declarations) == len(re.findall(r'\btheorem\b', clean)), f'unrecognized theorem grammar: {path}'
        assert len(declarations) == len(re.findall(r'\bsorry\b', clean)), f'unlisted proof hole: {path}'
        for match in declarations:
            assert path.name == 'Statements.lean', f'theorem outside frozen module: {path}'
            name = 'Singular.Statements.' + match[1]
            records.append({'name': name, 'status': 'STATED', 'debt': 'sorryAx',
                            'statementSha256': digest((match[1] + match[2]).encode())})
    assert records and len({r['name'] for r in records}) == len(records)
    return records


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path.cwd())
    parser.add_argument('--binary', type=Path)
    parser.add_argument('--export', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    records = inventory(root)
    manifest = json.loads((root / 'lean/theorem-debt.json').read_text())
    assert records == manifest, 'exact named theorem/debt manifest mismatch'
    binary = args.binary or root / '.lake/build/bin/singular-corpus'
    corpus = json.loads(subprocess.check_output([str(binary)]))
    sources = {str(p.relative_to(root)): digest(p.read_bytes()) for p in sorted((root / 'lean').rglob('*.lean'))}
    corpus['sourceHashes'] = sources
    corpus['modelSha256'] = sources['lean/Singular/Model.lean']
    corpus['statementsSha256'] = sources['lean/Singular/Statements.lean']
    corpus['corpusSourceSha256'] = sources['lean/Main.lean']
    corpus['theoremManifestSha256'] = digest((root / 'lean/theorem-debt.json').read_bytes())
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
    print(f'model-check: {len(records)} exact STATED/sorryAx identities; {len(ids)} executable corpus rows; model {corpus["modelSha256"]}')

if __name__ == '__main__':
    main()
