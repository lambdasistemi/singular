#!/usr/bin/env python3
"""Falsify the custody definition in isolated Lean builds; retain raw receipts.

Run from the repository's Nix development shell with an evidence directory.
Only temporary copies are mutated. One full elaboration per mutant; the corpus
binary is built first so its behavioral refusal remains observable even when
the proof correctly prevents the library from building.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
MODEL = Path('lean/Singular/Model.lean')
STATEMENTS = Path('lean/Singular/Statements.lean')
MUTANTS = {
    'datum-key': ('custodyDatum := some [r.refundAddress]',
                  'custodyDatum := some [r.key, r.refundAddress]'),
    'two-assets': ('assets := assets\n        , custodyDatum',
                   'assets := assets ++ [((.absent, r.key + 1), 1)]\n        , custodyDatum'),
    'zero-assets': ('assets := assets\n        , custodyDatum',
                    'assets := []\n        , custodyDatum'),
}


def run(command, cwd, log):
    with log.open('w') as out:
        result = subprocess.run(command, cwd=cwd, stdout=out, stderr=subprocess.STDOUT)
    return result.returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('evidence', type=Path)
    args = parser.parse_args()
    evidence = args.evidence.resolve()
    evidence.mkdir(parents=True, exist_ok=True)
    original = (ROOT / MODEL).read_text()
    statements = (ROOT / STATEMENTS).read_text()
    start = statements.index('theorem insert_absent_transaction_row')
    end = statements.index('/-- **#173 T1**', start)
    first_line = statements[:start].count('\n') + 1
    last_line = statements[:end].count('\n')
    receipts = []
    for name, (before, after) in {'baseline': ('', ''), **MUTANTS}.items():
        with tempfile.TemporaryDirectory(prefix='singular-absent-') as tmp:
            tree = Path(tmp)
            shutil.copytree(ROOT / 'lean', tree / 'lean')
            for filename in ('lakefile.toml', 'lean-toolchain', 'lake-manifest.json'):
                shutil.copy2(ROOT / filename, tree / filename)
            mutated = original
            if name != 'baseline':
                assert original.count(before) == 1, (name, 'mutation site changed')
                mutated = original.replace(before, after)
                (tree / MODEL).write_text(mutated)
            (evidence / f'{name}-Model.lean').write_text(mutated)
            binary_status = run(['lake', 'build', 'singular-corpus'], tree,
                                evidence / f'{name}-binary-build.log')
            assert binary_status == 0, f'{name}: setup/binary compilation failure'
            row_status = run([str(tree / '.lake/build/bin/singular-corpus')], tree,
                             evidence / f'{name}-row.log')
            proof_status = run(['lake', 'build'], tree, evidence / f'{name}-proof.log')
            row_text = (evidence / f'{name}-row.log').read_text()
            proof_text = (evidence / f'{name}-proof.log').read_text()
            if name == 'baseline':
                assert row_status == proof_status == 0, 'baseline failed'
                rows = json.loads(row_text)['transactions']
                assert len([r for r in rows if r['profile'] == 'insertAbsent' and r['accepted']]) == 1
            else:
                assert row_status != 0 and 'insertAbsent constructed transaction violates refund-only custody row' in row_text
                errors = [int(n) for n in re.findall(r'error: lean/Singular/Statements.lean:(\d+):', proof_text)]
                assert proof_status != 0 and any(first_line <= n <= last_line for n in errors), (name, 'new row proof did not fail')
            receipt = {'mutation': name, 'before': before, 'after': after,
                       'binaryBuildExit': binary_status, 'rowExit': row_status,
                       'proofExit': proof_status,
                       'modelSha256': hashlib.sha256(mutated.encode()).hexdigest(),
                       'statementsSha256': hashlib.sha256(statements.encode()).hexdigest()}
            receipts.append(receipt)
            print(json.dumps(receipt), flush=True)
    (evidence / 'receipts.json').write_text(json.dumps(receipts, indent=2) + '\n')


if __name__ == '__main__':
    main()
