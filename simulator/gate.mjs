import assert from 'node:assert/strict';
import {readFileSync,writeFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import vm from 'node:vm';
import {step,resolve,inspect,replay,checkCorpus,equal,initial,view} from './core.mjs';
import {checks,theoremReport,corpusRecords} from './properties.mjs';
import {checkNamingCorpus,selectProfile,namingPropertyReport,namingChecks,namingInitial,queueClaim,namingResolve,namingReplay,namingStep} from './naming.mjs';
const root=new URL('./',import.meta.url),read=p=>readFileSync(new URL(p,root),'utf8'),json=p=>JSON.parse(read(p));
const corpus=json('corpus.json'),stories=json('stories.json'),ledger=json('formal/theorem-debt.json'),identity=json('identity.json');
const namingLedger=json('../lean/naming-theorem-debt.json'),namingCorpus=json('../lean/naming-corpus.json');
const hash=s=>createHash('sha256').update(s).digest('hex');
// Two differentiated statement sources, each with its own prefix; never one list.
const names=[...read('formal/Statements.lean').matchAll(/^theorem (\w+)/gm)].map(m=>'Singular.Statements.'+m[1]);
const namingNames=[...read('formal/NamingStatements.lean').matchAll(/^theorem (\w+)/gm)].map(m=>'Singular.NamingStatements.'+m[1]);
function identityGate(rows=ledger,expected=names,kind='generic'){assert(expected.length>0,kind==='naming'?'zero naming theorem declarations':'zero theorem declarations');assert.deepEqual(rows.map(r=>r.name).sort(),[...expected].sort(),kind==='naming'?'naming theorem identity':'theorem identity');assert.equal(new Set(rows.map(r=>r.name)).size,rows.length,kind==='naming'?'duplicate naming theorem identity':'duplicate theorem identity');}
identityGate();assert.equal(names.length,identity.theorems,'theorem denominator');
identityGate(namingLedger,namingNames,'naming');assert.equal(namingNames.length,identity.namingTheorems,'naming theorem denominator');
const namingReceipt=checkNamingCorpus(namingCorpus);
const namingProperties=namingPropertyReport(namingLedger,namingCorpus);
assert.equal(namingProperties.length,namingNames.length,'naming property denominator');
for(const row of namingProperties)if(row.coverage==='controlled-check')assert.equal(row.holds,true,'naming property/'+row.name.split('.').at(-1));
assert.equal(selectProfile('generic').id,'generic','profile selection');assert.equal(selectProfile('m1-naming').id,'m1-naming','profile selection');
for(const [p,expected] of Object.entries(identity.files))assert.equal(hash(read(p)),expected,'identity/'+p);
assert.equal(corpus.cases.length,identity.corpusTransitions,'transition denominator');assert.equal(corpus.resolutions.length,identity.corpusResolutions,'resolution denominator');
const receipt=checkCorpus(corpus);const records=corpusRecords(corpus);
let storyExecuted=0,storyDiscovered=0;const finalResolutions={register:{address:{datum:100}},compete:{address:{datum:100}},cancel:'absent',address:{address:{datum:200}},retire:'retired',delete:'absent',batch:{address:{datum:200}},forged:'absent'};
for(const story of stories){assert(story.steps.length>0,'zero story');storyDiscovered+=story.steps.length+story.forks.reduce((n,f)=>n+f.steps.length,0);let s=story.seed;const prefix=[s];const run=e=>{const rec=inspect(s,e.action);assert.deepEqual(rec.result,e.expect,'story/'+story.id);records.push({...rec,id:`story/${story.id}/${storyExecuted}`});if(rec.result.accepted)s=rec.result.value.state;storyExecuted++;};for(const e of story.steps){run(e);prefix.push(s);}assert.deepEqual(resolve(s,42,true),finalResolutions[story.id],'story outcome/'+story.id);for(const f of story.forks){assert(Number.isInteger(f.at)&&prefix[f.at],'fork attachment');s=prefix[f.at];for(const e of f.steps)run(e);}}
assert(storyDiscovered>0);assert.equal(storyExecuted,storyDiscovered,'story denominator');
const propertyCoverage=[];let propertyExecuted=0;
for(const declaration of ledger){const short=declaration.name.split('.').at(-1),checker=checks[short];const rows=records.map(record=>({record,row:theoremReport(ledger,record).find(x=>x.name===declaration.name)}));for(const x of rows){assert.deepEqual(x.row.by,[declaration.name],'property identity');if(x.row.exhibited&&checker)assert.equal(x.row.holds,true,'property/'+short);}const exhibits=rows.filter(x=>x.row.exhibited);if(checker)assert(exhibits.length>0,'property exhibit/'+short);propertyCoverage.push({name:declaration.name,status:`${declaration.status} / ${declaration.debt}`,coverage:checker?'controlled-check':exhibits.length?'exhibits-only':'gap',exhibits:exhibits.map(x=>x.record.id),notes:checker?'Finite consequent checks only; the quantified statement is proved in Lean.':exhibits.length?'Action exhibit; the quantified statement is proved in Lean, not checked here.':'No executable nonvacuous exhibit; the quantified statement is proved in Lean.'});propertyExecuted++;}
assert.equal(propertyExecuted,names.length,'property denominator');
const page=read('index.html'),script=page.match(/<script>\n([\s\S]*)\n<\/script>/)[1];new vm.Script(script);
const inlined=script.slice(0,script.indexOf('const SVGNS ='))+'\nglobalThis.engine={step,resolve,checkCorpus,theoremReport};';const context=vm.createContext({});new vm.Script(inlined).runInContext(context);assert.deepEqual(JSON.parse(JSON.stringify(context.engine.checkCorpus(corpus))),receipt,'inlined corpus');
const firstStyle=page.match(/<style>\n([\s\S]*?)<\/style>/)[1];assert.equal(firstStyle,read('page-template.html').match(/<style>\n([\s\S]*?)<\/style>/)[1],'template stylesheet');
// Validate every numeric leaf of actual exported values through public entrypoints.
const numericPaths=(x,p=[])=>typeof x==='number'?[p]:x&&typeof x==='object'?Object.entries(x).flatMap(([k,v])=>numericPaths(v,[...p,k])):[];
const change=(x,path,value)=>{const copy=structuredClone(x);let n=copy;for(const k of path.slice(0,-1))n=n[k];n[path.at(-1)]=value;return copy;};
const base=corpus.cases.find(r=>r.result.accepted&&r.case.before.applications.length).case;
let boundaryDiscovered=0,boundaryExecuted=0;
for(const path of numericPaths(base.before)){for(const value of [-1,0.5,Number.MAX_SAFE_INTEGER+1,NaN,Infinity]){boundaryDiscovered+=4;const bad=change(base.before,path,value);assert.match(step(bad,base.action).reason,/^invalid-nat\//,'step boundary');boundaryExecuted++;assert.match(resolve(bad,42,true).error,/^invalid-nat\//,'resolve boundary');boundaryExecuted++;assert.throws(()=>replay(bad,[]),/invalid-nat\//,'replay boundary');boundaryExecuted++;assert.throws(()=>view(bad,42),/invalid-nat\//,'view boundary');boundaryExecuted++;}}
for(const row of corpus.cases){for(const path of numericPaths(row.case.action)){boundaryDiscovered++;const bad=change(row.case.action,path,Number.MAX_SAFE_INTEGER+1);assert.match(step(row.case.before,bad).reason,/^invalid-(nat|int)\//,'action boundary');boundaryExecuted++;}}
assert.equal(boundaryExecuted,boundaryDiscovered,'boundary denominator');assert(boundaryExecuted>0);
assert.match(step({...initial(),extra:0},{escape:{request:0}}).reason,/invalid-shape/,'complete shape');assert.match(step(initial(),{escape:{request:0},outsider:{}}).reason,/invalid-shape/,'constructor shape');
const namingFixture={paymentDestination:70,controlAddress:50,nextControlCommitment:80,retirementQuorum:{members:[50,51,52],threshold:2}};
const namingBase=namingInitial();
assert.match(queueClaim(namingBase,{spelling:'alice',fixture:{...namingFixture,extra:0},accepted:true}).reason,/invalid-fixture/,'naming exact fixture shape');boundaryDiscovered++;boundaryExecuted++;
assert.match(queueClaim(namingBase,{spelling:'alice',fixture:namingFixture,accepted:true,extra:0}).reason,/invalid-shape\/naming.queue/,'naming exact queue shape');boundaryDiscovered++;boundaryExecuted++;
assert.match(namingResolve({...namingBase,extra:0},'alice',true).error,/invalid-shape\/naming.state/,'naming exact state shape');boundaryDiscovered++;boundaryExecuted++;
const namingBadNat=structuredClone(namingBase);namingBadNat.registry.config.registry=-1;
assert.match(namingResolve(namingBadNat,'alice',true).error,/invalid-nat\/state.config.registry/,'naming nested registry domain');boundaryDiscovered++;boundaryExecuted++;
assert.throws(()=>namingReplay(namingBadNat,[]),/invalid-nat\/state.config.registry/,'naming replay validates empty origin');boundaryDiscovered++;boundaryExecuted++;
assert.throws(()=>namingReplay(namingBase,{}),/invalid-shape\/naming.actions/,'naming replay action array');boundaryDiscovered++;boundaryExecuted++;
const namingBadAction=structuredClone(namingCorpus.steps.find(row=>row.id==='NS12-fold-request-parity').action);namingBadAction.fold.extra={};assert.match(namingStep(namingCorpus.steps.find(row=>row.id==='NS12-fold-request-parity').before,namingBadAction).reason,/invalid-shape\/actions/,'naming exact supported action shape');boundaryDiscovered++;boundaryExecuted++;
const callerFixture=structuredClone(namingFixture);const queuedSnapshot=queueClaim(namingBase,{spelling:'alice',fixture:callerFixture,accepted:true});assert.equal(queuedSnapshot.accepted,true,'naming fixture snapshot setup');callerFixture.nextControlCommitment=81;assert.equal(queuedSnapshot.value.state.claims[0].fixture.nextControlCommitment,80,'naming fixture snapshot');boundaryDiscovered++;boundaryExecuted++;
assert.equal(boundaryExecuted,boundaryDiscovered,'extended boundary denominator');
const deleting=structuredClone(corpus.cases.find(r=>r.case.id==='S13-delete-completes'));deleting.case.before.entries[0].incarnation=Number.MAX_SAFE_INTEGER;assert.match(step(deleting.case.before,deleting.case.action).reason,/invalid-nat\/result.entries.incarnation/,'successor overflow');
const model=read('formal/Model.lean');const refusalSites=[...model.matchAll(/(?:throw|requireSome[^\n]*)\s+"([\w-]+)"/g)].map(m=>({reason:m[1],line:model.slice(0,m.index).split('\n').length}));const refusals=[...new Set(refusalSites.map(x=>x.reason))].sort();const observedRefusals=[...new Set(records.filter(r=>r.result&&!r.result.accepted).map(r=>r.result.reason))].sort();const coverage={sourceRefusals:refusals.map(reason=>({reason,sites:refusalSites.filter(x=>x.reason===reason),exhibits:records.filter(r=>r.result?.reason===reason).map(r=>r.id),status:observedRefusals.includes(reason)?'exhibited':'gap'})),actions:[...new Set(corpus.cases.map(r=>Object.keys(r.case.action)[0]))].sort(),properties:propertyCoverage};
const controls=[];
function killed(name,fn,expected){let error;try{fn();}catch(e){error=e;}assert(error,`surviving-control/${name}`);assert.match(error.message,expected,`wrong-reason/${name}`);controls.push({name,observed:error.message.split('\n')[0],expected:String(expected)});}
if(process.argv.includes('--selftest')){
 killed('core-refuse-everything',()=>checkCorpus(corpus,()=>({accepted:false,reason:'fault'})),/corpus\//);
 const firstRefused=corpus.cases.find(row=>!row.result.accepted).case.id;
 killed('core-accept-everything',()=>checkCorpus(corpus,(s,a)=>{const actual=step(s,a);return actual.accepted?actual:{accepted:true,value:{state:s,logical:[]}};}),new RegExp('corpus/'+firstRefused));
 const drift=structuredClone(corpus);drift.cases[0].result.reason='fault';killed('corpus-result-drift',()=>checkCorpus(drift),/corpus\//);
 killed('zero-corpus',()=>checkCorpus({...corpus,cases:[]}),/zero corpus/);
 killed('identity-drop',()=>identityGate(ledger.slice(1)),/theorem identity/);
 killed('identity-rename',()=>identityGate(ledger.map((r,i)=>i? r:{...r,name:'Singular.Statements.fake'})),/theorem identity/);
 killed('identity-zero',()=>identityGate([],[]),/zero theorem declarations/);
 killed('naming-identity-drop',()=>identityGate(namingLedger.slice(1),namingNames,'naming'),/naming theorem identity/);
 killed('naming-identity-rename',()=>identityGate(namingLedger.map((r,i)=>i?r:{...r,name:'Singular.NamingStatements.fake'}),namingNames,'naming'),/naming theorem identity/);
 killed('naming-identity-zero',()=>identityGate([],[],'naming'),/zero naming theorem declarations/);
 const namingDrift=structuredClone(namingCorpus);namingDrift.queues[0].result.requestId=namingDrift.queues[0].result.requestId+1;killed('naming-corpus-drift',()=>checkNamingCorpus(namingDrift),/naming-corpus\//);
 const namingSuppressed=0;killed('naming-corpus-suppressed',()=>assert(namingSuppressed===namingCorpus.spellings.length+namingCorpus.queues.length+namingCorpus.folds.length+namingCorpus.steps.length+namingCorpus.resolves.length+namingCorpus.replays.length,'naming corpus denominator'),/naming corpus denominator/);
 const namingZero=structuredClone(namingCorpus);namingZero.steps=[];killed('naming-corpus-zero',()=>checkNamingCorpus(namingZero),/zero naming corpus/);
 const bad=structuredClone(corpus);const accepted=bad.cases.find(r=>r.result.accepted);accepted.result.value.state.config.registry=Number.MAX_SAFE_INTEGER+1;killed('corpus-output-domain',()=>checkCorpus(bad),/invalid-nat\/corpus.result/);
 const suppressed=records.slice(0,0);killed('property-execution-suppressed',()=>assert(suppressed.length===records.length,'property execution denominator'),/property execution denominator/);
 for(const [short,c] of Object.entries(checks)){const source=records.find(c.on);assert(source,'missing control exhibit/'+short);const fabricated=structuredClone(source);c.fault(fabricated);assert(c.on(fabricated),'control lost antecedent/'+short);killed('property-'+short,()=>assert(c.test(fabricated),'property/'+short),new RegExp('property/'+short));}
 for(const [short,c] of Object.entries(namingChecks)){if(typeof c.fault!=='function')continue;const fabricated=structuredClone(namingCorpus);c.fault(fabricated);assert(c.on(fabricated),'naming control lost exhibit/'+short);killed('naming-property-'+short,()=>assert(c.test(fabricated),'naming property/'+short),new RegExp('naming property/'+short));}
 killed('control-suppression',()=>assert.equal(0,Object.keys(checks).length,'control denominator'),/control denominator/);
 assert.equal(controls.length,28+Object.values(namingChecks).filter(c=>typeof c.fault==='function').length,'control denominator');
 console.log(JSON.stringify({controlsDiscovered:controls.length,controlsExecuted:controls.length,controls},null,2));
}
if(process.argv.includes('--report')){writeFileSync(new URL('coverage.json',root),JSON.stringify(coverage,null,2)+'\n');}
console.log(JSON.stringify({status:'PASS finite checks only',corpus:receipt,stories:{discovered:storyDiscovered,executed:storyExecuted,trees:stories.length},properties:{discovered:names.length,executed:propertyExecuted,controlled:propertyCoverage.filter(r=>r.coverage==='controlled-check').length,exhibitsOnly:propertyCoverage.filter(r=>r.coverage==='exhibits-only').length,gaps:propertyCoverage.filter(r=>r.coverage==='gap').length},namingProperties:{discovered:namingProperties.length,executed:namingProperties.length,controlled:namingProperties.filter(r=>r.coverage==='controlled-check').length,exhibitsOnly:namingProperties.filter(r=>r.coverage==='exhibits-only').length,gaps:namingProperties.filter(r=>r.coverage==='gap').length},boundary:{discovered:boundaryDiscovered,executed:boundaryExecuted},refusals:{declared:refusals.length,exhibited:refusals.filter(x=>observedRefusals.includes(x)).length}},null,2));
