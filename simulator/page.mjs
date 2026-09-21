// The page. Every verdict shown here comes from the transcribed engine running
// in the reader's browser — nothing is pre-rendered, so what you see is what the
// model does, or a defect in this transcription.

const PROFILE={generic:'generic-profile',naming:'naming-profile'};
let state=initial(),story=null,cursor=0,prefix=[];

const witnessShape={active:'biconditional',absent:'biconditional',terminal:'implicational'};

function showWhere(){
  const key=Number($('key-input').value||42);
  const leaf=trieGet(state.trie,key),w=witnesses(state,key);
  $('where').textContent=`key ${key} · leaf ${leafName(leaf)} · active ${w.active} · absent ${w.absent} · terminal ${w.terminal}`;
  rows($('witnesses'),KINDS.map(k=>({k,n:w[k]})),d=>[d.k,d.n,witnessShape[d.k]]);
  $('root').textContent='root '+state.config.root.join(' ');
}

function renderRefusals(){
  const key=999,data=[];
  for(const edge of EDGES)for(const leaf of [null,'absent','active','terminal']){
    let s=initial();
    s={...s,trie:leaf===null?[]:[{key,leaf}],config:{...s.config,root:rootOf(leaf===null?[]:[{key,leaf}])}};
    if(leaf==='absent')s={...s,custody:[{key,refundAddress:91,value:200}]};
    if(leaf==='active')s={...s,held:[{key,kind:'active',output:555}]};
    const r=step(s,approved(edge,key,{owner:42,output:555,refundAddress:91,deposit:200}));
    data.push({edge,leaf:leafName(leaf),reason:r.accepted?'— admitted —':r.reason});
  }
  rows($('refusals'),data,d=>[d.edge,d.leaf,d.reason]);
}

function narrate(text){$('narration').textContent=text;}

function loadStory(id){
  story=STORIES.find(s=>s.id===id)||STORIES[0];
  $('story-picker').value=story.id;
  $('story-blurb').textContent=story.blurb;
  cursor=0;replayTo(0);
}

function replayTo(n){
  state=initial();prefix=[state];
  for(let i=0;i<n&&i<story.steps.length;i++){
    const r=step(state,story.steps[i].request);
    if(r.accepted)state=r.value.state;
    prefix.push(state);
  }
  cursor=n;
  const e=n===0?null:story.steps[n-1];
  narrate(e?`${e.what} → ${e.expect==='accept'?'admitted':'refused: '+e.expect}`
           :`${story.title}. Press ▶ to fold the first request.`);
  renderBranches();showWhere();
}

function renderBranches(){
  const forks=(story.forks||[]).filter(f=>f.at===cursor);
  $('branches').innerHTML=forks.map((f,i)=>button(f.steps[0].what,`data-fork="${i}"`)).join('');
  $('branches').querySelectorAll('button').forEach((b,i)=>b.onclick=()=>{
    const f=forks[i];let s=state;
    for(const e of f.steps){const r=step(s,e.request);
      narrate(`${e.what} → ${r.accepted?'admitted':'refused: '+r.reason}`);
      if(r.accepted)s=r.value.state;}
    state=s;showWhere();
  });
}

function buildEdgeButtons(){
  $('edges').innerHTML=EDGES.map(e=>button(e,`id="edge-${e}"`)).join('');
  for(const edge of EDGES)$('edge-'+edge).onclick=()=>{
    const key=Number($('key-input').value||42),owner=Number($('owner-input').value||42);
    const output=Number($('output-input').value||555),deposit=Number($('deposit-input').value||0);
    const kind=$('approval-picker').value;
    const opts={owner,output,deposit,refundAddress:owner};
    const req=edge==='witnessTerminal'?read(key,output)
      :kind==='matching'?approved(edge,key,opts)
      :kind==='mismatched'?mismatched(edge,key,opts)
      :kind==='other'?otherPolicy(edge,key,opts)
      :request(edge,key,opts);
    const r=step(state,req);
    $('edge-result').textContent=`${edge} → ${r.accepted?'admitted':'refused: '+r.reason}`;
    if(r.accepted)state=r.value.state;
    showWhere();
  };
}

function renderCorpusAndTheorems(){
  let agree=0;
  for(const row of CORPUS.cases){
    const r=step(row.before,row.action);
    const got=r.accepted?'accept':r.reason;
    const want=row.expectedAccept?'accept':row.expectedReason;
    if(got===want)agree++;
  }
  $('corpus-status').textContent=
    `${agree}/${CORPUS.cases.length} Lean corpus rows reproduced in your browser · model ${CORPUS.modelSha256.slice(0,12)}`;
  const report=theoremReport(THEOREMS,CORPUS);
  rows($('theorems'),report,d=>[d.name.split('.').at(-1),d.coverage,d.applicable,d.vacuous,d.held,
    d.exercised?'exercised':'not exercised']);
}

function renderNaming(){
  const j=overWitnessJourney();
  rows($('naming-journey'),j.steps,d=>[d.what,d.edge,d.accepted?'admitted':'refused: '+d.reason,
    leafName(d.leaf),d.witnesses.active,d.witnesses.absent,d.witnesses.terminal]);
  const c=checkNamingCorpus(NAMINGCORPUS);
  $('naming-status').textContent=
    `${c.inspected}/${c.discovered} naming rows across ${c.sections} sections inspected · Lean evidence, not replayed`;
  const l=checkLifecycleCorpus(LIFECYCLECORPUS);
  rows($('lifecycle'),l.rows,d=>[LIFECYCLE_TITLES[d.section],d.id,lifecycleReason(d)]);
  $('lifecycle-status').textContent=
    `${l.inspected}/${l.discovered} lifecycle rows across ${l.sections} sections inspected · Lean evidence, not replayed`;
}

function boot(){
  $('story-picker').innerHTML=STORIES.map(s=>`<option value="${s.id}">${s.title}</option>`).join('');
  loadStory(STORIES[0].id);
  $('story-picker').onchange=e=>loadStory(e.target.value);
  $('hist-first').onclick=()=>replayTo(0);
  $('hist-prev').onclick=()=>replayTo(Math.max(0,cursor-1));
  $('hist-next').onclick=()=>replayTo(Math.min(story.steps.length,cursor+1));
  $('hist-last').onclick=()=>replayTo(story.steps.length);
  $('btn-reset').onclick=()=>{state=initial();narrate('Reset to genesis.');showWhere();};
  $('btn-theme').onclick=()=>document.documentElement.classList.toggle('dark');
  $('profile-picker').onchange=e=>{
    for(const [k,id] of Object.entries(PROFILE))$(id).hidden=(k!==e.target.value);};
  $('key-input').onchange=showWhere;
  $('identity').textContent=`${IDENTITY.theorems} statements · ${IDENTITY.corpusCases} corpus rows`;
  buildEdgeButtons();renderRefusals();renderCorpusAndTheorems();renderNaming();showWhere();
}
boot();
