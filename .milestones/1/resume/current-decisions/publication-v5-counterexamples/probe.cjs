const fs=require('fs'),cp=require('child_process'),crypto=require('crypto');
const root=fs.mkdtempSync('/tmp/singular-publication-v5-');
const path='/code/singular-e18-cov2/conformance/coverage/publication-boundary-check.sh';
const source=fs.readFileSync(path,'utf8');
fs.writeFileSync(root+'/source.sh',source);
fs.writeFileSync(root+'/gh-calls.log','');
const tail=source.slice(source.indexOf('# Mutation B (final invocation removed)'));
const final=tail.slice(tail.indexOf('if grep -q "GHCALL: release upload"'),tail.indexOf('# --- post-hoc closure audit'));
const guardStart=source.indexOf('if grep -q "onchain" "$MUTOUT"');
const guard=source.slice(guardStart,source.indexOf('# Mutation B (final invocation removed)',guardStart));
if(!final.includes('composition proven')||!guard.includes('harness blind'))throw Error('source layout changed');
fs.writeFileSync(root+'/guard-output.log','unrelated onchain tool setup failed\n');
const results=[];
for(const [name,body,MUTRC] of [['final-missing-command',final,127],['guard-timeout-with-keyword',guard,124]]) {
 const script='set -u\nFAIL=0\nlog(){ echo "$*"; }\nfaillog(){ echo "CASE-FAIL: $*"; FAIL=1; }\n'+body+'\nexit "$FAIL"\n';
 fs.writeFileSync(root+'/'+name+'.sh',script);
 const r=cp.spawnSync('bash',[root+'/'+name+'.sh'],{env:{...process.env,OUTDIR:root,MUTOUT:root+'/guard-output.log',MUTRC:String(MUTRC)},encoding:'utf8'});
 fs.writeFileSync(root+'/'+name+'.stdout',r.stdout);fs.writeFileSync(root+'/'+name+'.stderr',r.stderr);
 results.push({name,simulatedPublisherExit:MUTRC,adjudicationExit:r.status,stdout:r.stdout});
}
const test='/nix/store/y8ia31jh4jfd9zg0gasmlzs0d0h1p4rm-publish-docs/bin/publish-docs';
const prod='/nix/store/61gb0wxcw4nmxmfk5af7zjjgdy51n41s-publish-docs/bin/publish-docs';
for(const [label,p] of [['test',test],['production',prod]]){
 const r=cp.spawnSync('nix',['path-info','-r',p],{encoding:'utf8'});
 fs.writeFileSync(root+'/'+label+'-closure.stdout',r.stdout);fs.writeFileSync(root+'/'+label+'-closure.stderr',r.stderr);
 results.push({name:label+'-closure',path:p,exit:r.status,recorder:r.stdout.split('\n').filter(s=>s.includes('upload-recorder')),gh:r.stdout.split('\n').filter(s=>/-gh-[^/]+$/.test(s))});
}
for(const p of ['run.log','case-positive.log','case-no-final.log','case-guard-removed.log'])fs.copyFileSync('/tmp/pub-harness/'+p,root+'/'+p);
const record={scope:'Exact mutation-adjudication suffixes with simulated failed commands ONLY, not whole publisher rerun. Closure lookup commands were real. Retained continuous positive is worker evidence.',sourceSha256:crypto.createHash('sha256').update(source).digest('hex'),results};
fs.writeFileSync(root+'/result.json',JSON.stringify(record,null,2));fs.copyFileSync(__filename,root+'/probe.cjs');
fs.writeFileSync('/tmp/projects/singular/milestone-1/handoffs/publication-v5-probe-path.txt',root+'\n');
console.log(JSON.stringify({root,...record},null,2));
