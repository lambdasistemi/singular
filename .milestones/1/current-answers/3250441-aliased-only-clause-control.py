import copy
import json
import sys
from dataclasses import asdict

sys.path.insert(0, '/tmp/singular-root-3250441-review.RohRVo/conformance/coverage')
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
    assert d.mapping_debt and d.layer_debt, "aliased-only clause must leave both debts"
    unaliased = copy.deepcopy(record)
    unaliased['checks'][2]['executionIdentity'] = 'exec-A1'
    unaliased['checks'][3]['executionIdentity'] = 'exec-A2'
    positive = c.greeter(unaliased)
    assert not positive.mapping_debt and not positive.layer_debt and not positive.execution_findings
    print(json.dumps({'candidate': '3250441c7c157f2cad1203114aa5c58e17332eab',
                      'independentClauses': clauses[:-1],
                      'aliasedOnlyClauses': clauses[-1:],
                      'positive_mapping_debt': positive.mapping_debt,
                      'positive_layer_debt': positive.layer_debt,
                      'positive_findings': [asdict(f) for f in positive.execution_findings],
                      'mapping_debt': d.mapping_debt, 'layer_debt': d.layer_debt,
                      'findings': [asdict(f) for f in d.execution_findings]}, indent=2))
finally:
    c.tearDown()
