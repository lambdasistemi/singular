import sys, copy; sys.path.insert(0,'.')
from tests.test_ratchet_controls import PermutationInvarianceControls as P
class Probe(P):
    def runTest(self): pass
t=Probe(); t.setUp(); base=t.base_record()
def mk(proto,cid,ident,cl):
    d=dict(proto); d["checkId"]=cid; d["executionIdentity"]=ident; d["coveredClauses"]=cl; return d
def run(name, checks):
    r=copy.deepcopy(base); r["checks"]=checks
    md,ld,_,find=t.debts_for(r)
    print(f"{name}: mapping_debt={md} layer_debt={ld} findings={[f[0] for f in find]}")
# CONTROL: same shape, alias REMOVED (distinct identities) -> must pay
run("no-alias (control)", [
 mk(base["checks"][0],"c-p","exec-P",["given","when"]),
 mk(base["checks"][1],"c-s","exec-S",["given","when"]),
 mk(base["checks"][0],"c-ap","exec-A1",["then"]),
 mk(base["checks"][1],"c-as","exec-A2",["then"]),
])
# CASE: aliased across families -> must NOT pay
run("aliased        ", [
 mk(base["checks"][0],"c-p","exec-P",["given","when"]),
 mk(base["checks"][1],"c-s","exec-S",["given","when"]),
 mk(base["checks"][0],"c-ap","exec-A",["then"]),
 mk(base["checks"][1],"c-as","exec-A",["then"]),
])
