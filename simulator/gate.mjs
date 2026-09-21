// The simulator gate. It answers one question: does this transcription do what
// the frozen Lean model does, on every row the model exported?
//
// A denominator is reported for everything it executes, because a replay that
// silently skipped rows would pass just as quietly as one that ran them.
// Checks are organized by the boundary they observe:
//   behavior  — the engine runs the transition and every modeled observable
//               (verdict, state, mint, refunds) is compared;
//   evidence  — the row is a verdict the Lean computed; it is inspected
//               against the transcription's own predicates, never executed;
// and the report names which class each exported corpus section got, so a
// section nobody classifies fails here instead of passing invisibly.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
import vm from 'node:vm';
import {step,foldBatch,equal,initial,trieGet,witnesses,decodeState,encodeState,
        delta,deltaSame,assetSame,rootOf,readAt,EDGES,KINDS,STATES} from './core.mjs';
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
// The modeled observable result of an admitted transition is the whole Result
// (Model.applyEdge): the new state, the mint the R2 delta names, and the
// refund the custody datum requires (R-ADA: the entry's own value to its own
// refund address). A verdict plus state alone would pass a transcription that
// dropped the mint or zeroed every refund.
const expectedPaid=(before,action)=>{
  const entry=before.custody.find(c=>c.key===action.key);
  return (action.edge==='updateActive'||action.edge==='deleteAbsent')&&entry
    ?[{destination:entry.refundAddress,value:entry.value}]:[];};
const assertObservableResult=(row,r)=>{
  assert.ok(equal(r.value.state,row.result.state),`corpus state/${row.id}`);
  assert.deepEqual(r.value.mint,delta(row.action.edge),`corpus mint/${row.id}`);
  assert.deepEqual(r.value.paid,expectedPaid(row.before,row.action),`corpus refund/${row.id}`);};
let discovered=0,executed=0,refundsObserved=0;
for(const row of corpus.cases){
  discovered++;
  const r=step(row.before,row.action);
  const got=r.accepted?'accept':r.reason;
  const want=row.expectedAccept?'accept':row.expectedReason;
  assert.equal(got,want,`corpus verdict/${row.id}`);
  if(r.accepted){assertObservableResult(row,r);
    if(r.value.paid.length>0)refundsObserved++;}
  executed++;
}
assert.equal(executed,discovered,'case denominator');
assert.ok(executed>0,'zero corpus');
assert.ok(refundsObserved>0,'no corpus case observes a refund at all');

// the deposit goes to the address the insert named, in the amount it deposited
let adaRun=0;
for(const row of corpus.ada){
  const s={...initial(),trie:[{key:5,leaf:'absent'}],custody:[{key:5,refundAddress:91,value:100}]};
  s.config={...s.config,root:rootOf(s.trie)};
  const edge=row.id.includes('update-active')?'updateActive':'deleteAbsent';
  const r=step(s,approved(edge,5,{owner:91,output:99,refundAddress:91}));
  assert.ok(r.accepted,`ada/${row.id}`);
  assert.deepEqual(r.value.paid,[{destination:row.paidTo[0],value:100}],`ada refund/${row.id}`);
  adaRun++;
}
assert.equal(adaRun,corpus.ada.length,'ada denominator');

// codec rows, both directions, including bytes that must not decode
let codecRun=0;
for(const row of corpus.codec){
  const decodes=decodeState(row.bytes??[])!==null;
  assert.equal(decodes,row.expectedDecodes,`codec/${row.id}`);
  codecRun++;
}
assert.equal(codecRun,corpus.codec.length,'codec denominator');
for(const s of STATES)assert.equal(decodeState(encodeState(s)),s,`codec roundtrip/${s}`);

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
 const two=foldBatch(initial(),[a,b]);
 assert.ok(two.accepted,'two-request batch');
 // the fold's own observable result: the mint it reports is the batch's R2
 // delta summed per (kind, key), and no request in it pays a refund. A fold
 // that accepted while losing the mint would otherwise pass silently.
 assert.deepEqual(two.value.mint,[{kind:'active',quantity:2}],'fold mint/two booked keys');
 assert.deepEqual(two.value.paid,[],'fold paid/two booked keys');
 const wrong={...b,claimed:[{kind:'active',quantity:5}]};
 assert.equal(foldBatch(initial(),[a,wrong]).reason,'net-mint-mismatch','mint check');
 // The keyed control. Two booking requests at two distinct keys whose per-kind
 // totals agree exactly — active +2 claimed, active +2 actual — and whose keyed
 // sums do not: key 17 claims both tokens, key 99 claims none. A per-kind guard
 // accepts this batch; the model's (kind, key) guard refuses it. This is the
 // production boundary, not a unit: it goes through foldBatch itself.
 const k17=approved('insertActive',17,{owner:42,output:555,
   claimed:[{kind:'active',quantity:2}]});
 const k99=approved('insertActive',99,{owner:42,output:555,claimed:[]});
 // The control is only meaningful while the per-kind totals really do agree: if
 // they ever diverge, the coarse guard would refuse this batch too and the
 // assertion below would pass without testing the keyed one.
 const activeTotal=rs=>rs.reduce((n,r)=>n+(r.claimed||[])
   .reduce((m,d)=>d.kind==='active'?m+d.quantity:m,0),0);
 assert.equal(activeTotal([k17,k99]),2,'claimed active total');
 assert.equal([k17,k99].length,2,'actual active total is one per insertActive');
 assert.equal(foldBatch(initial(),[k17,k99]).reason,'net-mint-mismatch',
   'equal per kind, wrong key: the fold must key its mint by (kind, key)');
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

// ---- 6. the laws, checked on their applicable rows -------------------------
// `applies` is the Lean statement's own hypothesis, nothing more. The
// unconditional laws (W1, W2, W4, S3) apply to every accepted row, so a
// missing witness can never demote a violated law to an inactive hypothesis;
// and a law left with no applicable example at all fails here rather than
// being reported as exercised on the strength of vacuous passes.
const report=theoremReport(theorems,corpus);
assert.equal(report.length,theorems.length,'theorem report denominator');
let checked=0;
for(const row of report)if(row.coverage==='controlled-check'){
  assert.ok(row.applicable>0,`law with no applicable example: ${row.name}`);
  assert.equal(row.held,row.applicable,`law violated on a corpus row: ${row.name}`);
  assert.ok(row.exercised,`law not exercised: ${row.name}`);
  checked++;
}
assert.ok(checked>=7,`too few controlled laws: ${checked}`);

// ---- 6b. the evidence boundary: what each exported section is ---------------
// The report classifies every array section the corpus exports: behavior (the
// engine executed it above), evidence (inspected below, never executed), or
// uncovered (exported and deliberately not consumed). A section the Lean adds
// and nobody classifies fails here instead of passing invisibly.
const SECTION_CLASS={
  cases:'behavior',codec:'behavior',ada:'behavior',
  folds:'evidence',keyedMintRows:'evidence',transactions:'evidence'};
const classifySections=c=>{
  const exported=Object.keys(c).filter(k=>Array.isArray(c[k]));
  const unclassified=exported.filter(k=>!(k in SECTION_CLASS));
  assert.ok(unclassified.length===0,
    `unclassified exported corpus sections: ${unclassified.join(', ')}`);
  return exported.map(k=>({section:k,rows:c[k].length,class:SECTION_CLASS[k]}));};
const sections=classifySections(corpus);

// Evidence inspection. These rows are verdicts the Lean computed; nothing
// here executes them. Each is checked against the transcription's own
// predicates, so corrupted evidence fails instead of decorating the report.
for(const row of corpus.folds){
  assert.equal(typeof row.ok,'boolean',`fold evidence/${row.id} has no verdict`);
  if(row.ok)assert.equal(row.reason,'',`fold evidence/${row.id} claims acceptance with a reason`);
  else assert.ok(REQUIRED_REFUSALS.includes(row.reason),
    `fold evidence/${row.id} refuses by an unnamed reason`);
}
for(const row of corpus.keyedMintRows){
  // The keyed-mint law decides the verdict: keyed agreement accepts, keyed
  // disagreement refuses — while the per-kind totals agree, or the row would
  // not be a keyed control at all.
  const byKind=ds=>ds.reduce((a,d)=>Object.assign(a,{[d.kind]:(a[d.kind]||0)+d.quantity}),{});
  const kc=byKind(row.claimed),ac=byKind(row.actual);
  const perKindAgree=Object.keys({...kc,...ac}).every(k=>(kc[k]||0)===(ac[k]||0));
  assert.equal(perKindAgree,row.perKindTotalsAgree,
    `keyed mint evidence/${row.id}: per-kind agreement flag`);
  assert.equal(assetSame(row.claimed,row.actual),row.accepted,
    `keyed mint evidence/${row.id}: keyed agreement must decide the verdict`);
  if(row.accepted)assert.equal(row.reason,'',`keyed mint evidence/${row.id}`);
  else assert.ok(REQUIRED_REFUSALS.includes(row.reason),
    `keyed mint evidence/${row.id} refuses by an unnamed reason`);
}
for(const row of corpus.transactions){
  assert.equal(typeof row.accepted,'boolean',`transaction evidence/${row.profile} has no verdict`);
  assert.ok(row.accepted,`transaction evidence/${row.profile} not accepted`);
  assert.deepEqual(row.transaction.mint,row.claimed,
    `transaction evidence/${row.profile} mints exactly what it claims`);
  if(row.secondInsert){
    assert.ok(!row.secondInsert.accepted
      &&REQUIRED_REFUSALS.includes(row.secondInsert.reason),
      `transaction evidence/${row.profile} replay must refuse by name`);
  }
  for(const rf of row.refusals||[])
    assert.ok(!rf.accepted&&REQUIRED_REFUSALS.includes(rf.reason),
      `transaction evidence/${row.profile} refused row by an unnamed reason`);
}

// ---- 7. naming: the corpus is evidence, the journey is behavior ------------
const namingReceipt=checkNamingCorpus(namingCorpus);
assert.equal(namingReceipt.sections,NAMING_SECTIONS.length,'naming sections');
assert.equal(namingReceipt.executed,0,
  'naming corpus rows are inspected Lean evidence, not executed behavior');
{
 const j=overWitnessJourney();
 assert.ok(j.steps.every(s=>s.accepted),'the Over witness journey must complete');
 assert.equal(j.steps[2].witnesses.terminal,1,'a folded read mints one Over witness');
 assert.equal(j.steps[3].witnesses.terminal,2,'the terminal witness is plural');
 assert.equal(j.steps[4].witnesses.terminal,0,'the witnesses burn');
 assert.equal(j.steps[4].leaf,'terminal','burning changes no leaf');
}

// ---- 7b. the naming lifecycle: inspected evidence, never executed ----------
const lifecycleReceipt=checkLifecycleCorpus(lifecycleCorpus);
assert.equal(lifecycleReceipt.sections,LIFECYCLE_SECTIONS.length,'lifecycle sections');
assert.equal(lifecycleReceipt.executed,0,
  'lifecycle rows are inspected Lean evidence, not executed behavior');
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
    const c=checks.active_witness_unique;
    assert.ok(c.applies(s,{key:1},s),'the violating state must be an applicable example');
    assert.ok(c.law(s,{key:1},s));});
  { // a positive control, live: strip every row whose hypotheses occupancy
    // needs, and require the report to stop calling the law exercised.
    const stripped={...corpus,cases:corpus.cases.filter(r=>!r.expectedAccept
      ||!['insertActive','updateActive'].includes(r.action.edge))};
    const rep=theoremReport(theorems,stripped);
    const occupancy=rep.find(r=>r.name.endsWith('.occupancy'));
    assert.ok(occupancy.applicable===0&&!occupancy.exercised,
      'a law without applicable examples must not be reported as exercised');
    console.log('PASS selftest: a law without applicable examples is not reported as exercised');
  }
  mustThrow('an admitted result that dropped the mint',()=>{
    const row=corpus.cases.find(c=>c.expectedAccept);
    const good=step(row.before,row.action);
    assertObservableResult(row,{accepted:true,value:{state:good.value.state,mint:[],paid:good.value.paid}});});
  mustThrow('an admitted result that zeroed a refund',()=>{
    const row=corpus.cases.find(c=>c.expectedAccept
      &&(c.action.edge==='updateActive'||c.action.edge==='deleteAbsent')
      &&c.before.custody.some(x=>x.key===c.action.key));
    const good=step(row.before,row.action);
    assertObservableResult(row,{accepted:true,value:{state:good.value.state,mint:good.value.mint,
      paid:good.value.paid.map(p=>({...p,value:0}))}});});
  mustThrow('a corpus section nobody classifies',()=>{
    classifySections({...corpus,futureSection:[]});});
  mustThrow('a fabricated id-only naming row',()=>{
    checkNamingCorpus({...namingCorpus,
      queues:[...namingCorpus.queues,{id:'invented-queues'}]});});
  mustThrow('a naming resolve row that contradicts the supply sync',()=>{
    checkNamingCorpus({...namingCorpus,
      resolves:namingCorpus.resolves.map(r=>
        r.id==='NRP03-resolve-active'?{...r,leaf:'unknown'}:r)});});
  mustThrow('a naming resolve row that hides witnesses under a terminal leaf',()=>{
    checkNamingCorpus({...namingCorpus,
      resolves:namingCorpus.resolves.map(r=>
        r.id==='NRP03-resolve-active'
          ?{...r,leaf:{known:{s:'terminal'}},active:2}:r)});});
  { // positive control: plural terminal witnesses stay allowed where the leaf
    // is terminal (W3), so strengthening the biconditional outlawed nothing.
    checkNamingCorpus({...namingCorpus,
      resolves:namingCorpus.resolves.map(r=>
        r.id==='NRP05-resolve-attested'?{...r,terminal:2}:r)});
    console.log('PASS selftest: plural terminal witnesses stay allowed on a terminal leaf');
  }
  { // positive control: the supply law is unconditional over reachable states
    // (S3 assumes only reachability). A state whose leaf says active while no
    // witness exists must stay an applicable example and must read as a
    // violated law — not vanish into the vacuous column.
    const s={...initial(),trie:[{key:1,leaf:'active'}],held:[]};
    const c=checks.biconditional_supply_sync;
    assert.ok(c.applies(s,{key:1},s),
      'the supply law applies to every reachable state; absence is not a hypothesis');
    assert.ok(!c.law(s,{key:1},s),
      'a witnessless active leaf violates the supply law');
    console.log('PASS selftest: a witnessless supply violation stays applicable and reads as violated');
  }
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
  corpusCases:executed,corpusRefunds:refundsObserved,codec:codecRun,ada:adaRun,
  complementPairs:pairs,refusedPairs,
  storySteps:storyExecuted,controlledLaws:checked,
  sections,
  namingInspected:namingReceipt.inspected,
  lifecycleInspected:lifecycleReceipt.inspected,boundary,
  model:corpus.modelSha256.slice(0,12)},null,1));
console.log('PASS simulator: the transcription reproduces the model on every exported row');
