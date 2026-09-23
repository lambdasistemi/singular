// Transcription of Singular.Model, registry mode. Extra boundary refusals are
// runtime limits of this engine, not model behaviour.
//
// This file is written from the frozen Lean interface. Where it and the Lean
// disagree, the Lean is right and this is a defect: the corpus replay in
// gate.mjs exists to find exactly that disagreement.
export const canonical=x=>JSON.stringify(x,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.entries(v).sort(([a],[b])=>a.localeCompare(b))):v);
export const equal=(a,b)=>canonical(a)===canonical(b);
const fail=reason=>{throw new Error(reason)};
const N='nat',I='int',B='bool';

// ---- the alphabet (R1) ------------------------------------------------------
export const STATES=['absent','active','terminal'];
export const EDGES=['insertAbsent','insertActive','updateActive','updateTerminal',
  'deleteAbsent','deleteActive','witnessTerminal'];
export const KINDS=['active','absent','terminal'];
const leaf={$option:{$enum:STATES}};            // null is Unknown, else Known s

// ---- schemas ---------------------------------------------------------------
const approval={policy:N,edge:{$enum:EDGES},key:N,owner:N,destination:N,assetName:N,
  signatures:[[N]]};
const configSchema={root:[N],maxFee:N,processTime:N,retractTime:N,applicationPolicy:N,
  activePolicy:N,absentPolicy:N,terminalPolicy:N};
const custody={key:N,refundAddress:N,value:N};
const holding={key:N,kind:{$enum:KINDS},output:N};
const stateSchema={config:configSchema,trie:[{key:N,leaf}],custody:[custody],held:[holding]};
const requestSchema={edge:{$enum:EDGES},key:N,owner:N,refundAddress:N,deposit:N,output:N,
  approval:{$option:approval},claimed:[{kind:{$enum:KINDS},quantity:I}]};

function validate(x,s,p){
 if(s===N||s===I){if(!Number.isSafeInteger(x)||(s===N&&x<0))fail(`invalid-${s}/${p}`);return;}
 if(s===B){if(typeof x!=='boolean')fail(`invalid-shape/${p}`);return;}
 if(s.$option){if(x!==null)validate(x,s.$option,p);return;}
 if(s.$enum){if(!s.$enum.includes(x))fail(`invalid-shape/${p}`);return;}
 if(Array.isArray(s)){if(!Array.isArray(x))fail(`invalid-shape/${p}`);x.forEach((v,i)=>validate(v,s[0],`${p}.${i}`));return;}
 if(!x||typeof x!=='object'||Array.isArray(x))fail(`invalid-shape/${p}`);
 if(!equal(Object.keys(x).sort(),Object.keys(s).sort()))fail(`invalid-shape/${p}`);
 for(const k of Object.keys(s))validate(x[k],s[k],`${p}.${k}`);
}

// ---- the commitment function ----------------------------------------------
const MASK=(1n<<64n)-1n;
export const fnv1a=bs=>bs.reduce((h,b)=>((h^BigInt(b))*16777619n)&MASK,14695981039346656037n);
export const u64bytes=n=>[56n,48n,40n,32n,24n,16n,8n,0n].map(s=>Number((n>>s)&0xffn));
const u8=n=>Number(BigInt(n)&0xffn);
export const stateByte=s=>({absent:0x00,active:0x01,terminal:0x02})[s];
const leafByte=l=>l===null?0xFF:stateByte(l);
export const rootOf=trie=>{
 const sorted=[...trie].sort((a,b)=>a.key-b.key);
 const bytes=sorted.flatMap(p=>[...u64bytes(fnv1a([u8(p.key)])),u8(p.key),leafByte(p.leaf)]);
 return u64bytes(fnv1a(bytes));
};

// ---- the leaf codec (D-CODEC) ----------------------------------------------
export const encodeState=s=>[stateByte(s)];
export const decodeState=bytes=>{
 if(!Array.isArray(bytes)||bytes.length!==1)return null;
 const i=[0x00,0x01,0x02].indexOf(bytes[0]);
 return i<0?null:STATES[i];
};

// ---- trie ------------------------------------------------------------------
export const trieGet=(t,k)=>{const e=t.find(p=>p.key===k);return e===undefined?null:e.leaf;};
const trieSet=(t,k,l)=>[{key:k,leaf:l},...t.filter(p=>p.key!==k)];

// ---- deltas (R2) -----------------------------------------------------------
const DELTA={insertAbsent:[['absent',1]],insertActive:[['active',1]],
 updateActive:[['absent',-1],['active',1]],updateTerminal:[['active',-1]],
 deleteAbsent:[['absent',-1]],deleteActive:[['active',-1]],
 witnessTerminal:[['terminal',1]]};
export const delta=e=>DELTA[e].map(([kind,quantity])=>({kind,quantity}));
export const deltaKind=(ds,k)=>ds.reduce((n,d)=>d.kind===k?n+d.quantity:n,0);
export const deltaSame=(a,b)=>[...a,...b].every(d=>deltaKind(a,d.kind)===deltaKind(b,d.kind));
const deltaPlus=(a,b)=>[...new Set([...a,...b].map(d=>d.kind))]
  .map(kind=>({kind,quantity:deltaKind(a,kind)+deltaKind(b,kind)}));

// The fold's mint accounting is keyed by (kind, key), matching the Lean model's
// assetDelta/requestClaim/assetSame. A per-kind sum accepts a batch that claims
// one key's token twice and another's not at all; the keyed one refuses it.
export const assetDelta=r=>delta(r.edge).map(d=>({kind:d.kind,key:r.key,quantity:d.quantity}));
export const requestClaim=r=>(r.claimed||[]).map(d=>({kind:d.kind,key:r.key,quantity:d.quantity}));
export const assetKind=(ds,kind,key)=>
  ds.reduce((n,d)=>d.kind===kind&&d.key===key?n+d.quantity:n,0);
export const assetPlus=(a,b)=>[...new Map([...a,...b]
  .map(d=>[`${d.kind}@${d.key}`,{kind:d.kind,key:d.key}])).values()]
  .map(x=>({kind:x.kind,key:x.key,quantity:assetKind(a,x.kind,x.key)+assetKind(b,x.kind,x.key)}));
export const assetSame=(a,b)=>[...a,...b]
  .every(d=>assetKind(a,d.kind,d.key)===assetKind(b,d.kind,d.key));

// ---- the R2 from→to column -------------------------------------------------
export const transition=(e,before)=>{
 const k=`${e}/${before===null?'unknown':before}`;
 return ({'insertAbsent/unknown':'absent','insertActive/unknown':'active',
  'updateActive/absent':'active','updateTerminal/active':'terminal',
  'deleteAbsent/absent':null,'deleteActive/active':null,
  'witnessTerminal/terminal':'terminal'})[k] ?? (k in
  {'deleteAbsent/absent':0,'deleteActive/active':0} ? null : undefined);
};

// ---- admission (R4, D-APPROVAL, D-SELF) ------------------------------------
const EDGE_ORDINAL=Object.fromEntries(EDGES.map((e,i)=>[e,i]));
// masked to 32 bits, as the model is: a JSON number cannot carry 64 bits, and
// every consumer must agree on this value exactly
export const approvalAssetName=(e,key,owner,destination)=>
  Number(fnv1a([EDGE_ORDINAL[e],u8(key),u8(owner),u8(destination)])&0xFFFFFFFFn);
export const requestDestination=r=>r.edge==='insertAbsent'?0:r.output;
export const admitsFor=(config,r,ap)=>{
 if(r.edge==='witnessTerminal')return true;
 if(ap===null||ap===undefined)return false;
 return ap.policy===config.applicationPolicy&&ap.edge===r.edge&&ap.key===r.key&&
   ap.owner===r.owner&&ap.destination===requestDestination(r)&&
   ap.assetName===approvalAssetName(ap.edge,ap.key,ap.owner,ap.destination);
};

// ---- the read (R5) ---------------------------------------------------------
export const readAt=(s,_position,key,value)=>
  equal(s.config.root,rootOf(s.trie))&&trieGet(s.trie,key)===value&&value==='terminal';

// ---- refusal: the complement of the R2 table (R3) --------------------------
export function refusal(s,a){
 const before=trieGet(s.trie,a.key);
 if(a.edge==='witnessTerminal')
  return readAt(s,0,a.key,'terminal')?null:
    ({null:'read-unknown',absent:'read-absent',active:'read-active',terminal:'read-invalid'})[String(before)];
 const ap=a.approval;
 if(ap===null||ap===undefined)return 'no-approval';
 if(ap.policy!==s.config.applicationPolicy)return 'no-approval';
 if(!admitsFor(s.config,a,ap))return 'approval-mismatch';
 const custodyPresent=s.custody.some(c=>c.key===a.key);
 const activePresent=s.held.some(h=>h.key===a.key&&h.kind==='active');
 const at=`${a.edge}/${before===null?'unknown':before}`;
 switch(at){
  case 'insertAbsent/unknown': case 'insertActive/unknown': return null;
  case 'insertAbsent/absent': case 'insertAbsent/active': case 'insertAbsent/terminal':
  case 'insertActive/absent': case 'insertActive/active': case 'insertActive/terminal':
   return 'key-exists';
  case 'updateActive/absent': return custodyPresent?null:'custody-missing';
  case 'updateActive/unknown': return 'key-unknown';
  case 'updateActive/active': return 'already-booked';
  case 'updateActive/terminal': return 'terminal-immutable';
  case 'updateTerminal/active': return activePresent?null:'token-missing';
  case 'updateTerminal/unknown': return 'key-unknown';
  case 'updateTerminal/absent': return 'not-booked';
  case 'updateTerminal/terminal': return 'terminal-immutable';
  case 'deleteAbsent/absent': return custodyPresent?null:'custody-missing';
  case 'deleteAbsent/unknown': return 'key-unknown';
  case 'deleteAbsent/active': return 'not-absent';
  case 'deleteAbsent/terminal': return 'terminal-immutable';
  case 'deleteActive/active': return activePresent?null:'token-missing';
  case 'deleteActive/unknown': return 'key-unknown';
  case 'deleteActive/absent': return 'not-active';
  case 'deleteActive/terminal': return 'terminal-immutable';
  default: return 'read-invalid';
 }
}

// ---- applying an admitted edge (R2, R6, R-ADA) ------------------------------
export function applyEdge(s,a){
 const entry=s.custody.find(c=>c.key===a.key);
 const withTrie=(l)=>{const trie=trieSet(s.trie,a.key,l);
   return {trie,config:{...s.config,root:rootOf(trie)}};};
 switch(a.edge){
  case 'insertAbsent':{const t=withTrie('absent');
   return {state:{...s,...t,custody:[{key:a.key,refundAddress:a.refundAddress,value:a.deposit},...s.custody]},
     mint:delta(a.edge),paid:[]};}
  case 'insertActive':{const t=withTrie('active');
   return {state:{...s,...t,held:[{key:a.key,kind:'active',output:a.output},...s.held]},
     mint:delta(a.edge),paid:[]};}
  case 'updateActive':{const t=withTrie('active');
   return {state:{...s,...t,custody:s.custody.filter(c=>c.key!==a.key),
     held:[{key:a.key,kind:'active',output:a.output},...s.held]},
     mint:delta(a.edge),paid:entry?[{destination:entry.refundAddress,value:entry.value}]:[]};}
  case 'updateTerminal':{const t=withTrie('terminal');
   return {state:{...s,...t,held:s.held.filter(h=>!(h.key===a.key&&h.kind==='active'))},
     mint:delta(a.edge),paid:[]};}
  case 'deleteAbsent':{const trie=s.trie.filter(p=>p.key!==a.key),t={trie,config:{...s.config,root:rootOf(trie)}};
   return {state:{...s,...t,custody:s.custody.filter(c=>c.key!==a.key)},
     mint:delta(a.edge),paid:entry?[{destination:entry.refundAddress,value:entry.value}]:[]};}
  case 'deleteActive':{const trie=s.trie.filter(p=>p.key!==a.key),t={trie,config:{...s.config,root:rootOf(trie)}};
   return {state:{...s,...t,held:s.held.filter(h=>!(h.key===a.key&&h.kind==='active'))},
     mint:delta(a.edge),paid:[]};}
  case 'witnessTerminal':
   return {state:{...s,held:[{key:a.key,kind:'terminal',output:a.output},...s.held]},
     mint:delta(a.edge),paid:[]};
 }
}

// ---- step and the fold ------------------------------------------------------
export function step(s,a){
 try{
  validate(s,stateSchema,'state');validate(a,requestSchema,'request');
  const why=refusal(s,a);
  if(why!==null)return {accepted:false,reason:why};
  const value=applyEdge(s,a);
  validate(value.state,stateSchema,'result.state');
  return {accepted:true,value};
 }catch(e){return {accepted:false,reason:e.message};}
}

export function foldActions(s,batch){
 let state=s,mint=[],paid=[];
 for(const b of batch){
  const r=step(state,b);
  if(!r.accepted)return r;
  state=r.value.state;mint=deltaPlus(mint,r.value.mint);paid=[...paid,...r.value.paid];
 }
 return {accepted:true,value:{state,mint,paid}};
}

export function foldBatch(s,batch){
 try{
  validate(s,stateSchema,'state');validate(batch,[requestSchema],'batch');
  if(batch.length===0)return {accepted:false,reason:'empty-fold'};
  const r=foldActions(s,batch);
  if(!r.accepted)return r;
  const claimed=batch.reduce((acc,b)=>assetPlus(acc,requestClaim(b)),[]);
  const actual=batch.reduce((acc,b)=>assetPlus(acc,assetDelta(b)),[]);
  if(!assetSame(claimed,actual))return {accepted:false,reason:'net-mint-mismatch'};
  return r;
 }catch(e){return {accepted:false,reason:e.message};}
}

// ---- the consumer's view (interface §7): tokens, never the root -------------
export const witnesses=(s,key)=>({
 active:s.held.filter(h=>h.key===key&&h.kind==='active').length,
 absent:s.custody.filter(c=>c.key===key).length,
 terminal:s.held.filter(h=>h.key===key&&h.kind==='terminal').length});

export function view(s,key){
 validate(s,stateSchema,'state');validate(key,N,'key');
 return {leaf:trieGet(s.trie,key),witnesses:witnesses(s,key),root:s.config.root};
}

export const initial=(config)=>({config:{root:rootOf([]),maxFee:1,processTime:2,
 retractTime:3,applicationPolicy:7,activePolicy:8,absentPolicy:9,terminalPolicy:10,...config},
 trie:[],custody:[],held:[]});

export function inspect(s,a){
 const verdict=step(s,a);
 return {before:s,action:a,result:verdict,committed:verdict.accepted};
}

export function replay(s,actions){
 validate(s,stateSchema,'state');validate(actions,[requestSchema],'actions');
 return actions.reduce((acc,a)=>{const r=inspect(acc.state,a);
  return {state:r.result.accepted?r.result.value.state:acc.state,records:[...acc.records,r]};},
  {state:s,records:[]});
}
