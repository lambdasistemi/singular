import copy
import json
import sys
from dataclasses import asdict

sys.path.insert(0, '/tmp/singular-root-69730c9-review/conformance/coverage')
from tests.test_ratchet_controls import ClauseAccountingControls

c = ClauseAccountingControls()
c.setUp()
try:
    record = c.base_record()
    clauses = list(record['mappings'][0]['clauses'])
    assert len(clauses) >= 2
    p, s = record['checks']
    pa, sa = copy.deepcopy(p), copy.deepcopy(s)
    p['executionIdentity'], s['executionIdentity'] = 'exec-P', 'exec-S'
    p['coveredClauses'] = s['coveredClauses'] = clauses[:-1]
    pa['checkId'], sa['checkId'] = 'c-prop-alias', 'c-story-alias'
    pa['executionIdentity'] = sa['executionIdentity'] = 'exec-A'
    pa['coveredClauses'] = sa['coveredClauses'] = clauses[-1:]
    record['checks'] = [p, s, pa, sa]
    d = c.greeter(record)
    print(json.dumps({'candidate': '69730c96859cf3ab7067f2384e846736f634ab39',
                      'independentClauses': clauses[:-1],
                      'aliasedOnlyClauses': clauses[-1:],
                      'mapping_debt': d.mapping_debt, 'layer_debt': d.layer_debt,
                      'findings': [asdict(f) for f in d.execution_findings]}, indent=2))
finally:
    c.tearDown()
