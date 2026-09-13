import copy
import json
import sys
from pathlib import Path

sys.path.insert(0, '/tmp/singular-root-fb9724d-review/conformance/coverage')
from tests.test_ratchet_controls import ClauseAccountingControls

case = ClauseAccountingControls()
case.setUp()
results = []
try:
    base = case.base_record()
    keys = list(base['mappings'][0]['clauses'])
    assert len(keys) >= 2
    def inspect(name, record):
        d = case.greeter(record)
        results.append({'case': name, 'mapping_debt': d.mapping_debt,
                        'layer_debt': d.layer_debt,
                        'findings': [{'code': f.code, 'message': f.message}
                                     for f in d.execution_findings]})
    inspect('ordinary two distinct complete layers', base)
    split = copy.deepcopy(base)
    p, s = split['checks']
    p['coveredClauses'] = keys[:1]
    p2 = copy.deepcopy(p)
    p2['checkId'] = 'c-prop-second-independent'
    p2['executionIdentity'] = 'exec-3'
    p2['coveredClauses'] = keys[1:]
    split['checks'] = [p, p2, s]
    inspect('two independent property checks jointly complete one family', split)
    alias = copy.deepcopy(split)
    alias['checks'][1]['executionIdentity'] = 'exec-2'
    inspect('second property check aliases story execution', alias)
    alias['checks'] = [alias['checks'][1], alias['checks'][0], alias['checks'][2]]
    inspect('same aliased checks only reordered', alias)
    assert not results[0]['mapping_debt'] and not results[0]['layer_debt']
    assert results[1]['findings'], 'The reviewed source is expected to falsely flag valid multiple checks'
    assert not results[2]['layer_debt'] and results[3]['layer_debt'], 'Expected order-dependent alias accounting'
    print(json.dumps({'candidate': 'fb9724dabac09d603c66ebdf94daf7b3b9dcfb',
                      'actual_candidate': 'fb9724dabac09d60303c66ebdf94daf7b3b9dcfb',
                      'results': results}, indent=2))
finally:
    case.tearDown()
