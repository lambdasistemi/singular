import sys, copy; sys.path.insert(0,'.')
from tests.test_ratchet_controls import PermutationInvarianceControls as P
class Probe(P):
    def runTest(self): pass
t=Probe(); t.setUp()
base=t.base_record()
k=[x for x in base["checks"][0] if "id" in x.lower()]
print("id field(s):", k)
def mk(proto, cid, ident, clauses):
    d=dict(proto); d[k[0]]=cid; d["executionIdentity"]=ident; d["coveredClauses"]=clauses; return d
r=copy.deepcopy(base)
r["checks"]=[
 mk(base["checks"][0],"c-p","exec-P",["given","when"]),
 mk(base["checks"][1],"c-s","exec-S",["given","when"]),
 mk(base["checks"][0],"c-ap","exec-A",["then"]),
 mk(base["checks"][1],"c-as","exec-A",["then"]),
]
md,ld,layers,find=t.debts_for(r)
print("mapping_debt:",md,"| layer_debt:",ld,"| layers:",layers)
print("findings:",[f[0] for f in find])
