import json
from dataclasses import replace
from pathlib import Path
from singular_classification.schema import load_classification
from singular_classification.check import check
from singular_classification.clauses import split_signature

root = Path(__file__).parent
original = load_classification(root / 'conformance/coverage/classification/classification.json')
results = {}
def record(name, value):
    results[name] = {'findings': [str(x) for x in value.findings], 'open': list(value.open_rows), 'complete': value.complete}

record('baseline', check(root, original))
rows = list(original.rows)
idx = next(i for i,r in enumerate(rows) if r.name == 'Singular.requireSome_none')
sig = 'theorem requireSome_none {α} (reason : String) : True :='
_, _, binders, conclusion, statement = split_signature(sig)
rows[idx] = replace(rows[idx], signature=sig, clauses=dict(statement=statement, binders=binders, conclusion=conclusion))
record('coherent_false_signature_original_digest', check(root, replace(original, rows=tuple(rows))))
(root / 'forged-row.json').write_text(json.dumps({'original': original.rows[idx].__dict__, 'mutant': rows[idx].__dict__}, indent=2))

source = root / 'lean/Singular/NamingLemmas.lean'
old = source.read_text()
needle = 'Except.error "naming-no-delete"'
assert old.count(needle) == 1
source.write_text(old.replace(needle, 'Except.error "naming-xx-delete"'))
record('changed_literal_unchanged_classification', check(root, original))

print(json.dumps(results, indent=2))
(root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
assert not results['baseline']['findings']
assert not results['coherent_false_signature_original_digest']['findings']
assert not results['changed_literal_unchanged_classification']['findings']
