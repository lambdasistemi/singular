const fs=require('fs'),cp=require('child_process'),crypto=require('crypto');
const root=fs.mkdtempSync('/tmp/singular-expected-debt-green-');
const repo='/code/singular-e18-cg';
const git=(args,opts={})=>cp.execFileSync('git',args,{encoding:'utf8',...opts});
const provider=git(['-C',repo,'rev-parse','HEAD']).trim();
const subject='1d98d51afa168a2bc0fd0e15ab33993a706eee31';
const source=git(['-C',repo,'show',provider+':.github/workflows/conformance.yml']);
fs.writeFileSync(root+'/workflow.yml',source);
let suffix=source.slice(source.indexOf('          # --- expected-debt assertion'),source.indexOf('      # Issue #69:'));
suffix=suffix.split('\n').map(s=>s.startsWith('          ')?s.slice(10):s).join('\n');
if(!suffix.includes('head_sha=')||!suffix.includes('GREEN ='))throw Error('Unexpected suffix');
fs.writeFileSync(root+'/suffix-original.sh',suffix);
const body=suffix.replaceAll('nix run --quiet nixpkgs#jq --','/run/current-system/sw/bin/jq').replaceAll('/tmp/generic-rows.log',root+'/run.log').replaceAll('/tmp/expected-rows.txt',root+'/expected-rows.txt').replaceAll('/tmp/receipt-rows.txt',root+'/receipt-rows.txt');
fs.writeFileSync(root+'/suffix-executed.sh','set -e\n'+body);
git(['clone','--quiet','--shared','--no-checkout',repo,root+'/subject']);
git(['-C',root+'/subject','checkout','--quiet','--detach',subject]);
const receipts='/tmp/projects/singular/milestone-1/handoffs/t70b-fresh-receipts-1d98d51/receipts';
fs.cpSync(receipts,root+'/subject/conformance-receipts',{recursive:true});
fs.copyFileSync('/tmp/projects/singular/milestone-1/handoffs/t70b-fresh-receipts-1d98d51/run.log',root+'/run.log');
const original=fs.readFileSync(receipts+'/receipt-CL01.json');
const results=[];
for(const [name,rc,unknown] of [['genuine-positive',1,false],['original-exit127-counterexample',127,false],['original-unknown-CL01-counterexample',1,true]]){
 const target=root+'/subject/conformance-receipts/receipt-CL01.json';
 fs.writeFileSync(target,original);
 if(unknown){const j=JSON.parse(original);j.verdict='could-not-execute';fs.writeFileSync(target,JSON.stringify(j));}
 fs.copyFileSync(target,root+'/'+name+'-CL01.json');
 const r=cp.spawnSync('bash',[root+'/suffix-executed.sh'],{cwd:root+'/subject',env:{...process.env,run_rc:String(rc)},encoding:'utf8'});
 fs.writeFileSync(root+'/'+name+'.stdout',r.stdout);fs.writeFileSync(root+'/'+name+'.stderr',r.stderr);
 results.push({name,run_rc:rc,exit:r.status,stdout:r.stdout});
}
const result={scope:'Independent execution of repaired CI adjudication suffix, using retained real ledger receipts/log from clean subject1d98d51; provider is newer CI-only repair. No new devnet or whole workflow run. Only jq launcher and private temp paths substituted.',provider,subject,sourceSha256:crypto.createHash('sha256').update(source).digest('hex'),results};
fs.writeFileSync(root+'/result.json',JSON.stringify(result,null,2));fs.copyFileSync(__filename,root+'/verify.cjs');
fs.writeFileSync('/tmp/projects/singular/milestone-1/handoffs/expected-debt-green-path.txt',root+'\n');
console.log(JSON.stringify({root,...result},null,2));
if(results[0].exit!==0||results[1].exit!==1||results[2].exit!==1)process.exitCode=1;
