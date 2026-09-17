// The simulator gate. It answers one question: does this transcription do what
// the frozen Lean model does, on every row the model exported?
//
// A denominator is reported for everything it executes, because a replay that
// silently skipped rows would pass just as quietly as one that ran them.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import vm from 'node:vm';
import {step,foldBatch,equal,initial,trieGet,witnesses,decodeState,encodeState,
        delta,deltaSame,rootOf,readAt,EDGES,KINDS,STATES} from './core.mjs';
import {approved,read,mismatched,otherPolicy,request} from './actions.mjs';
import {theoremReport,checks} from './properties.mjs';
import {checkNamingCorpus,overWitnessJourney,NAMING_SECTIONS} from './naming.mjs';
import {checkLifecycleCorpus,LIFECYCLE_SECTIONS} from './lifecycle.mjs';

const root=new URL('./',import.meta.url);
const read_=p=>readFileSync(new URL(p,root),'utf8');
const json=p=>JSON.parse(read_(p));
const hash=s=>createHash('sha256').update(s).digest('hex');

const identity=json('identity.json');
const corpus=json('corpus.json');
const stories=json('stories.json');
const theorems=json('formal/theorem-debt.json');
const namingCorpus=json('../lean/naming-corpus.json');
const namingTheorems=json('../lean/naming-theorem-debt.json');
const lifecycleCorpus=json('../lean/lifecycle-corpus.json');
const selftest=process.argv.includes('--selftest');

// ---- 1. identity: the frozen inputs are the ones this page was built from ----
for(const [p,expected] of Object.entries(identity.files))
  assert.equal(hash(read_(p)),expected,'identity/'+p);
assert.equal(hash(read_('page-template.html')),identity.templateSha256,'template identity');
assert.equal(theorems.length,identity.theorems,'theorem denominator');
assert.equal(namingTheorems.length,identity.namingTheorems,'naming theorem denominator');
assert.equal(corpus.cases.length,identity.corpusCases,'corpus denominator');

// the simulator's copy of the corpus must BE the Lean corpus, not a cousin
assert.equal(hash(read_('corpus.json')),hash(readFileSync(new URL('../lean/corpus.json',root),'utf8')),
  'simulator corpus is not the Lean corpus');

// ---- 2. the transcription reproduces the model on every exported row --------
let discovered=0,executed=0;
for(const row of corpus.cases){
  discovered++;
  const r=step(row.before,row.action);
  const got=r.accepted?'accept':r.reason;
  const want=row.expectedAccept?'accept':row.expectedReason;
  assert.equal(got,want,`corpus verdict/${row.id}`);
  if(r.accepted)assert.ok(equal(r.value.state,row.result.state),`corpus state/${row.id}`);
  executed++;
}
assert.equal(executed,discovered,'case denominator');
assert.ok(executed>0,'zero corpus');

// codec rows, both directions, including bytes that must not decode
let codecRun=0;
for(const row of corpus.codec){
  const decodes=decodeState(row.bytes??[])!==null;
  assert.equal(decodes,row.expectedDecodes,`codec/${row.id}`);
  codecRun++;
}
assert.equal(codecRun,corpus.codec.length,'codec denominator');
for(const s of STATES)assert.equal(decodeState(encodeState(s)),s,`codec roundtrip/${s}`);

// the deposit goes to the address the insert named (R-ADA)
let adaRun=0;
for(const row of corpus.ada){
  const s={...initial(),trie:[{key:5,leaf:'absent'}],custody:[{key:5,refundAddress:91,value:100}]};
  s.config={...s.config,root:rootOf(s.trie)};
  const edge=row.id.includes('update-active')?'updateActive':'deleteAbsent';
  const r=step(s,approved(edge,5,{owner:91,output:99,refundAddress:91}));
  assert.ok(r.accepted,`ada/${row.id}`);
  assert.deepEqual(r.value.paid.map(p=>p.destination),row.paidTo,`ada destination/${row.id}`);
  adaRun++;
}
assert.equal(adaRun,corpus.ada.length,'ada denominator');

// ---- 3. every refusal the model names, refused BY NAME ---------------------
const REQUIRED_REFUSALS=['read-unknown','read-absent','read-active','key-exists','key-unknown',
  'already-booked','not-booked','not-active','terminal-immutable','no-approval',
  'approval-mismatch','custody-missing','token-missing','empty-fold','net-mint-mismatch'];
const seen=new Set();
for(const row of corpus.cases)if(!row.expectedAccept)seen.add(row.expectedReason);
for(const row of corpus.folds)if(!row.ok)seen.add(row.reason);
seen.add(step(initial(),mismatched('insertActive',42,{owner:42,output:555})).reason);
for(const why of REQUIRED_REFUSALS)assert.ok(seen.has(why),`refusal never exercised: ${why}`);

// every (edge, leaf) pair outside the edge table is refused — the complement
let pairs=0,refusedPairs=0;
for(const edge of EDGES)for(const leaf of [null,...STATES]){
  const key=7;let s=initial();
  const trie=leaf===null?[]:[{key,leaf}];
  s={...s,trie,config:{...s.config,root:rootOf(trie)},
     custody:leaf==='absent'?[{key,refundAddress:91,value:200}]:[],
     held:leaf==='active'?[{key,kind:'active',output:555}]:[]};
  const r=step(s,approved(edge,key,{owner:42,output:555,refundAddress:91,deposit:200}));
  pairs++;
  const inTable=({insertAbsent:'unknown',insertActive:'unknown',updateActive:'absent',
    updateTerminal:'active',deleteAbsent:'absent',deleteActive:'active',
    witnessTerminal:'terminal'})[edge]===(leaf===null?'unknown':leaf);
  if(inTable)assert.ok(r.accepted,`edge table row refused: ${edge}/${leaf}`);
  else{assert.ok(!r.accepted,`outside the table but admitted: ${edge}/${leaf}`);
       assert.ok(r.reason.length>0,'refusal without a reason');refusedPairs++;}
}
assert.equal(pairs,EDGES.length*4,'complement denominator');
assert.equal(refusedPairs,pairs-EDGES.length,'every edge has exactly one admitting leaf');

// ---- 4. the fold: atomicity, the empty batch, the mint check ---------------
assert.equal(foldBatch(initial(),[]).reason,'empty-fold','empty batch');
{
 const a=approved('insertActive',1,{owner:42,output:555,claimed:[{kind:'active',quantity:1}]});
 const b=approved('insertActive',2,{owner:42,output:555,claimed:[{kind:'active',quantity:1}]});
 assert.ok(foldBatch(initial(),[a,b]).accepted,'two-request batch');
 const wrong={...b,claimed:[{kind:'active',quantity:5}]};
 assert.equal(foldBatch(initial(),[a,wrong]).reason,'net-mint-mismatch','mint check');
 const bad=approved('updateTerminal',9,{owner:42,output:555});
 const r=foldBatch(initial(),[a,bad]);
 assert.ok(!r.accepted,'a refusal refuses the whole batch');
}

// ---- 5. stories: every step and fork agrees with the engine ----------------
let storyDiscovered=0,storyExecuted=0;
for(const story of stories){
  assert.ok(story.steps.length>0,`empty story ${story.id}`);
  let s=initial();const prefix=[s];
  const run=e=>{storyDiscovered++;const r=step(s,e.request);
    assert.equal(r.accepted?'accept':r.reason,e.expect,`story/${story.id}/${e.what}`);
    if(r.accepted)s=r.value.state;storyExecuted++;};
  for(const e of story.steps){run(e);prefix.push(s);}
  for(const f of story.forks||[]){s=prefix[f.at];for(const e of f.steps)run(e);}
}
assert.equal(storyExecuted,storyDiscovered,'story denominator');
assert.ok(storyExecuted>0,'zero stories');

// ---- 6. the laws, checked on every accepted row ----------------------------
const report=theoremReport(theorems,corpus);
assert.equal(report.length,theorems.length,'theorem report denominator');
let checked=0;
for(const row of report)if(row.coverage==='controlled-check'){
  assert.ok(row.exhibited>0,`law never exhibited: ${row.name}`);
  assert.equal(row.held,row.exhibited,`law violated on a corpus row: ${row.name}`);
  checked++;
}
assert.ok(checked>=7,`too few controlled laws: ${checked}`);

// ---- 7. naming ------------------------------------------------------------
const namingReceipt=checkNamingCorpus(namingCorpus);
assert.equal(namingReceipt.sections,NAMING_SECTIONS.length,'naming sections');
{
 const j=overWitnessJourney();
 assert.ok(j.steps.every(s=>s.accepted),'the Over witness journey must complete');
 assert.equal(j.steps[2].witnesses.terminal,1,'a folded read mints one Over witness');
 assert.equal(j.steps[3].witnesses.terminal,2,'the terminal witness is plural');
 assert.equal(j.steps[4].witnesses.terminal,0,'the witnesses burn');
 assert.equal(j.steps[4].leaf,'terminal','burning changes no leaf');
}

// ---- 7b. the naming lifecycle ---------------------------------------------
const lifecycleReceipt=checkLifecycleCorpus(lifecycleCorpus);
assert.equal(lifecycleReceipt.sections,LIFECYCLE_SECTIONS.length,'lifecycle sections');
// The two rows the amended retirement rule turns on must be present BY ID: a
// corpus that quietly dropped them would still replay, and would still pass a
// check that only counted rows.
for(const id of ['LT03-insufficient-quorum-refused','LT08-control-key-alone-refused',
                 'LT02-quorum-retirement-accepts','LR11-root-equal-after-recovery'])
  assert.ok(lifecycleReceipt.rows.some(r=>r.id===id),`lifecycle row missing: ${id}`);
// and they must refuse for retirement's own reason, not for naming's no-delete
for(const id of ['LT03-insufficient-quorum-refused','LT08-control-key-alone-refused'])
  assert.equal(lifecycleReceipt.rows.find(r=>r.id===id).detail,'naming-retirement-uncertified',
    `${id} must carry retirement's own refusal reason`);

// ---- 8. boundary: the engine refuses what is not a state -------------------
let boundary=0;
for(const bad of [{...initial(),trie:[{key:-1,leaf:null}]},
                  {...initial(),trie:[{key:1.5,leaf:null}]},
                  {...initial(),held:[{key:1,kind:'nonsense',output:0}]},
                  {...initial(),extra:1}]){
  const r=step(bad,approved('insertActive',1,{owner:42,output:555}));
  assert.ok(!r.accepted&&/^invalid-/.test(r.reason),'boundary refusal');
  boundary++;
}
assert.equal(boundary,4,'boundary denominator');

// ---- 9. the built page carries this exact engine ---------------------------
{
 const page=read_('index.html');
 const script=page.match(/<script>\n([\s\S]*)\n<\/script>/)[1];
 new vm.Script(script);                       // it parses
 assert.ok(script.includes('const STORIES='),'page carries the stories');
 assert.ok(script.includes(`"modelSha256": "${corpus.modelSha256}"`)||script.includes(corpus.modelSha256),
   'page carries this corpus');
}

// ---- selftest: the gate can fail ------------------------------------------
if(selftest){
  const mustThrow=(what,f)=>{let threw=false;try{f()}catch{threw=true}
    assert.ok(threw,`SELFTEST: ${what} did not fail`);};
  mustThrow('a corrupted corpus verdict',()=>{
    const row={...corpus.cases.find(c=>c.expectedAccept),expectedReason:'nonsense',expectedAccept:false};
    const r=step(row.before,row.action);
    assert.equal(r.accepted?'accept':r.reason,row.expectedReason);});
  mustThrow('a law violated',()=>{
    const s={...initial(),held:[{key:1,kind:'active',output:1},{key:1,kind:'active',output:2}]};
    assert.ok(checks.active_witness_unique(s,{key:1},s));});
  mustThrow('an admitted triple outside the table',()=>{
    const s={...initial(),trie:[{key:7,leaf:'terminal'}]};
    assert.ok(step(s,approved('deleteActive',7,{owner:42,output:555})).accepted);});
  mustThrow('a story whose expectation is wrong',()=>{
    assert.equal(step(initial(),read(42,700)).reason,'read-active');});
  mustThrow('a lifecycle corpus section emptied',()=>{
    checkLifecycleCorpus({...lifecycleCorpus,retirement:[]});});
  mustThrow('a lifecycle row that did not hold',()=>{
    checkLifecycleCorpus({...lifecycleCorpus,
      wire:lifecycleCorpus.wire.map(r=>({...r,ok:false}))});});
  console.log('PASS selftest: the gate fails when it should');
}

console.log(JSON.stringify({
  corpusCases:executed,codec:codecRun,ada:adaRun,
  complementPairs:pairs,refusedPairs,
  storySteps:storyExecuted,controlledLaws:checked,
  namingRows:namingReceipt.executed,lifecycleRows:lifecycleReceipt.executed,boundary,
  model:corpus.modelSha256.slice(0,12)},null,1));
console.log('PASS simulator: the transcription reproduces the model on every exported row');
