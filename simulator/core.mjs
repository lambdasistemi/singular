// Exact transcription of Singular.Model. Extra boundary refusals are runtime limits.
export const canonical=x=>JSON.stringify(x,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.entries(v).sort(([a],[b])=>a.localeCompare(b))):v);
export const equal=(a,b)=>canonical(a)===canonical(b);
const fail=reason=>{throw new Error(reason)};
const N='nat',I='int',B='bool';
const rep={registry:N,key:N,policy:N,assetScope:N},out={representative:rep,quantity:N,destination:N,datum:N,value:N};
const proposal={registry:N,key:N,applicationPolicy:N,refundAddress:N,initial:out,scope:[N]},refund={destination:N,value:N};
const asset={policy:N,name:{$union:{insert:{proposal},withdraw:{registry:N,request:N,refund}}}};
const approval={asset,accepted:B,conforms:B};
const req={id:N,operation:{$enum:['insert','update','delete']},proposal,token:{$option:asset},held:{$option:rep},destination:N,authenticatedOrigin:B};
const utxo={id:N,key:N,output:out},w={applicationMint:B,applicationSpend:B,nativeSpend:B,representativeMint:B,consumerWithdraw:B};
const item={request:N,outputId:N,output:{$option:out}},delta={asset:rep,quantity:I},actionDelta={asset,quantity:I};
const entrySchema={key:N,value:{$option:{$enum:['active','over']}},incarnation:N};
const stateSchema={config:{registry:N,applicationPolicy:N,requestAddress:N,representativePolicy:N,consumerPin:N,reuseIdentity:B},entries:[entrySchema],applications:[utxo],requests:[req],approvals:[approval],used:[N]};
const actionSchema={$union:{createInsert:{request:req,approval,witness:w},mintWithdraw:{approval,witness:w},release:{source:N,request:req,evidence:{source:N,request:req,accepted:B,conforms:B},witness:w},evolve:{source:N,successor:utxo,evidence:{source:N,successor:utxo,accepted:B,conforms:B},witness:w},outsider:{request:req},withdraw:{request:N,asset,refund,witness:w},fold:{items:[item],mint:[delta],actionNet:[actionDelta],witness:w},moveAction:{asset,net:I,witness:w},escape:{request:N}}};
function validate(x,s,p){
 if(s===N||s===I){if(!Number.isSafeInteger(x)||(s===N&&x<0))fail(`invalid-${s}/${p}`);return;}
 if(s===B){if(typeof x!=='boolean')fail(`invalid-shape/${p}`);return;}
 if(s.$option){if(x!==null)validate(x,s.$option,p);return;}
 if(s.$enum){if(!s.$enum.includes(x))fail(`invalid-shape/${p}`);return;}
 if(Array.isArray(s)){if(!Array.isArray(x))fail(`invalid-shape/${p}`);x.forEach((v,i)=>validate(v,s[0],`${p}.${i}`));return;}
 if(!x||typeof x!=='object'||Array.isArray(x))fail(`invalid-shape/${p}`);
 if(s.$union){const ks=Object.keys(x);if(ks.length!==1||!s.$union[ks[0]])fail(`invalid-shape/${p}`);validate(x[ks[0]],s.$union[ks[0]],`${p}.${ks[0]}`);return;}
 if(!equal(Object.keys(x).sort(),Object.keys(s).sort()))fail(`invalid-shape/${p}`);
 for(const k of Object.keys(s))validate(x[k],s[k],`${p}.${k}`);
}
export const initial=()=>({config:{registry:1,applicationPolicy:7,requestAddress:90,representativePolicy:8,consumerPin:9,reuseIdentity:true},entries:[],applications:[],requests:[],approvals:[],used:[]});
const entry=(s,k)=>s.entries.find(e=>e.key===k)??{key:k,value:null,incarnation:0};
const representative=(s,k)=>({registry:s.config.registry,key:k,policy:s.config.representativePolicy,assetScope:s.config.reuseIdentity?0:entry(s,k).incarnation});
const fresh=(s,id)=>!s.used.includes(id);
const consume=(s,id)=>({...s,requests:s.requests.filter(r=>r.id!==id),applications:s.applications.filter(u=>u.id!==id)});
const setEntry=(s,e)=>({...s,entries:[e,...s.entries.filter(x=>x.key!==e.key)]});
const insertAsset=p=>({policy:p.applicationPolicy,name:{insert:{proposal:p}}});
const proposalNative=(s,p)=>p.registry===s.config.registry&&p.applicationPolicy===s.config.applicationPolicy&&p.initial.representative.registry===p.registry&&p.initial.representative.key===p.key&&p.initial.representative.policy===s.config.representativePolicy&&p.initial.quantity===1;
const insertNative=(s,r)=>r.operation==='insert'&&proposalNative(s,r.proposal)&&r.held===null&&r.destination===s.config.requestAddress&&equal(r.token,insertAsset(r.proposal));
const releaseNative=(s,r)=>r.operation!=='insert'&&r.proposal.registry===s.config.registry&&r.destination===s.config.requestAddress&&r.held!==null&&r.held.registry===s.config.registry&&r.held.key===r.proposal.key&&r.held.policy===s.config.representativePolicy;
const recognized=(s,a)=>a.policy===s.config.applicationPolicy&&s.approvals.some(e=>equal(e.asset,a)&&e.accepted);
const approved=(s,a,w)=>w.applicationMint&&a.accepted&&a.asset.policy===s.config.applicationPolicy;
const result=(state,logical=[])=>({state,logical});
function foldOne(s,i){
 const r=s.requests.find(r=>r.id===i.request);if(!r)fail('request-unavailable');
 if(!r.authenticatedOrigin)fail('unauthenticated-request');const e=entry(s,r.proposal.key);
 if(r.operation==='insert'){
  if(!insertNative(s,r)||!(r.token&&recognized(s,r.token)))fail('insert-binding');
  if(e.value!==null)fail('occupied-key');if(!r.proposal.scope.includes(e.incarnation))fail('approval-scope');
  if(!equal(r.proposal.initial.representative,representative(s,e.key)))fail('representative-identity');
  if(!equal(i.output,r.proposal.initial)||!fresh(s,i.outputId))fail('certified-output');
  const t=setEntry(consume(s,r.id),{...e,value:'active'});
  return result({...t,applications:[{id:i.outputId,key:e.key,output:r.proposal.initial},...t.applications],used:[i.outputId,...t.used]},[{asset:representative(s,e.key),quantity:1}]);
 }
 if(!releaseNative(s,r)||!equal(r.held,representative(s,r.proposal.key)))fail('terminal-binding');
 if(e.value!=='active')fail('not-active');if(i.output!==null)fail('terminal-output');
 const incarnation=r.operation==='delete'?e.incarnation+1:e.incarnation;validate(incarnation,N,'result.entries.incarnation');
 return result(setEntry(consume(s,r.id),{...e,value:r.operation==='update'?'over':null,incarnation}),[{asset:representative(s,e.key),quantity:-1}]);
}
const quantity=(ds,a)=>ds.filter(d=>equal(d.asset,a)).reduce((n,d)=>n+BigInt(d.quantity),0n);
const sameNet=(a,b)=>[...a,...b].every(d=>quantity(a,d.asset)===quantity(b,d.asset));
const nonzero=ds=>ds.some(d=>quantity(ds,d.asset)!==0n);
function foldItems(s,items,trajectory=[]){let acc=result(s);for(const i of items){const before=acc.state;const r=foldOne(before,i);trajectory.push({before,item:i,result:r});acc=result(r.state,[...acc.logical,...r.logical]);}return acc;}
function transition(s,a,trajectory){const kind=Object.keys(a)[0],d=a[kind],w=d.witness,r=d.request,cert=d.approval;
 switch(kind){
 case 'createInsert':if(!insertNative(s,r)||!r.authenticatedOrigin||!equal(cert.asset,insertAsset(r.proposal)))fail('insert-binding');if(!approved(s,cert,w))fail('application-approval');if(!fresh(s,r.id))fail('utxo-id-reuse');return result({...s,requests:[r,...s.requests],approvals:[cert,...s.approvals],used:[r.id,...s.used]});
 case 'mintWithdraw':if(!approved(s,cert,w))fail('application-approval');if(cert.asset.name.insert)fail('withdraw-tag');if(cert.asset.name.withdraw.registry!==s.config.registry)fail('registry-binding');return result({...s,approvals:[cert,...s.approvals]});
 case 'release':{const u=s.applications.find(u=>u.id===d.source);if(!u)fail('application-unavailable');const e=d.evidence;if(!w.applicationSpend||!e.accepted||e.source!==d.source||!equal(e.request,r))fail('exact-release-authorization');if(!releaseNative(s,r)||!r.authenticatedOrigin||!equal(r.held,u.output.representative)||u.key!==r.proposal.key)fail('terminal-binding');if(!fresh(s,r.id))fail('utxo-id-reuse');const t=consume(s,d.source);return result({...t,requests:[r,...t.requests],used:[r.id,...t.used]});}
 case 'evolve':{const u=s.applications.find(u=>u.id===d.source);if(!u)fail('application-unavailable');const e=d.evidence,n=d.successor;if(!w.applicationSpend||!e.accepted||e.source!==d.source||!equal(e.successor,n))fail('application-evolution-authorization');if(!equal(n.output.representative,u.output.representative)||n.output.quantity!==1||n.key!==u.key)fail('evolution-representative');if(!fresh(s,n.id))fail('utxo-id-reuse');const t=consume(s,d.source);return result({...t,applications:[n,...t.applications],used:[n.id,...t.used]});}
 case 'outsider':if(!fresh(s,r.id))fail('utxo-id-reuse');if(r.held!==null)fail('outsider-cannot-create-representative');return result({...s,requests:[{...r,authenticatedOrigin:false},...s.requests],used:[r.id,...s.used]});
 case 'withdraw':{const pending=s.requests.find(x=>x.id===r);if(!pending)fail('request-unavailable');if(!w.nativeSpend)fail('native-witness');if(!pending.authenticatedOrigin||!insertNative(s,pending))fail('withdraw-insert-only');if(d.refund.destination!==pending.proposal.refundAddress)fail('withdraw-refund-address');if(!recognized(s,d.asset)||!equal(d.asset.name,{withdraw:{registry:s.config.registry,request:r,refund:d.refund}}))fail('withdraw-binding');return result(consume(s,r));}
 case 'fold':{if(!w.nativeSpend)fail('native-witness');if(d.items.length===0)fail('empty-fold');if(!w.consumerWithdraw)fail('consumer-witness');const t=foldItems(s,d.items,trajectory);if(!sameNet(t.logical,d.mint))fail('net-mint-mismatch');if(nonzero(d.mint)&&!w.representativeMint)fail('representative-witness');if(nonzero(d.actionNet)&&!w.applicationMint)fail('application-mint-witness');return t;}
 case 'moveAction':if(!recognized(s,d.asset))fail('unrecognized-action');if(d.net!==0)fail('movement-net-not-zero');return result(s);
 case 'escape':fail('completion-only-custody');
 }
}
export function step(s,a){try{validate(s,stateSchema,'state');validate(a,actionSchema,'action');const value=transition(s,a,[]);validate(value,{state:stateSchema,logical:[delta]},'result');return {accepted:true,value};}catch(e){return {accepted:false,reason:e.message};}}
export function inspect(s,a){const trajectory=[];const verdict=step(s,a);try{validate(s,stateSchema,'state');validate(a,actionSchema,'action');transition(s,a,trajectory);}catch{}return {before:s,action:a,result:verdict,trajectory,committed:verdict.accepted};}
export function resolve(s,key,authenticated){try{validate(s,stateSchema,'state');validate(key,N,'key');validate(authenticated,B,'authenticated');if(!authenticated)return 'unauthenticated';const e=entry(s,key);if(e.value===null)return 'absent';if(e.value==='over')return 'retired';const u=s.applications.find(u=>u.key===key&&equal(u.output.representative,representative(s,key))&&u.output.quantity===1);return u?{address:{datum:u.output.datum}}:'pending';}catch(e){return {error:e.message};}}
export function replay(s,actions){validate(s,stateSchema,'state');validate(actions,[actionSchema],'actions');return actions.reduce((acc,a)=>{const r=inspect(acc.state,a);return {state:r.result.accepted?r.result.value.state:acc.state,records:[...acc.records,r]};},{state:s,records:[]});}
export function checkCorpus(c,engine=step,resolver=resolve){if(!Array.isArray(c.cases)||!c.cases.length||!Array.isArray(c.resolutions)||!c.resolutions.length)fail('zero corpus');let executed=0;for(const row of c.cases){validate(row.case.before,stateSchema,'corpus.before');validate(row.case.action,actionSchema,'corpus.action');if(row.result.accepted)validate(row.result.value,{state:stateSchema,logical:[delta]},'corpus.result');if(!equal(engine(row.case.before,row.case.action),row.result))fail(`corpus/${row.case.id}`);executed++;}for(const row of c.resolutions){validate(row.before,stateSchema,'corpus.resolution.before');validate(row.key,N,'corpus.key');validate(row.authenticated,B,'corpus.authenticated');if(typeof row.expected==='object')validate(row.expected,{$union:{address:{datum:N}}},'corpus.expected');else if(!['absent','retired','pending','unauthenticated'].includes(row.expected))fail('invalid-resolution');if(!equal(resolver(row.before,row.key,row.authenticated),row.expected))fail(`resolution/${row.id}`);executed++;}if(executed!==c.cases.length+c.resolutions.length)fail('corpus denominator');return {discovered:executed,executed};}
export function view(s,key){validate(s,stateSchema,'state');validate(key,N,'key');return {entry:entry(s,key),representative:representative(s,key),resolution:resolve(s,key,true)};}
