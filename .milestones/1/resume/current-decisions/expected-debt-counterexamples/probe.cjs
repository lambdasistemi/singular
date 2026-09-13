const fs = require('fs'), cp = require('child_process'), crypto = require('crypto');
const root = fs.mkdtempSync('/tmp/singular-expected-debt-control-');
const repo = '/code/singular-e18-cg';
const git = (...args) => cp.execFileSync('git', ['-C', repo, ...args], {encoding:'utf8'});
const source = git('show', 'HEAD:.github/workflows/conformance.yml');
fs.writeFileSync(root+'/workflow.yml', source);
let raw = source.slice(source.indexOf('          # --- expected-debt assertion'), source.indexOf('      # Issue #69:'));
raw = raw.split('\n').map(l => l.startsWith('          ') ? l.slice(10) : l).join('\n');
if (!raw.includes('run_rc') || !raw.includes('GREEN =')) throw Error('suffix not found');
fs.writeFileSync(root+'/suffix-original.sh', raw);
const body = raw.replaceAll('nix run --quiet nixpkgs#jq --','/run/current-system/sw/bin/jq').replaceAll('/tmp/expected-rows.txt',root+'/expected-rows.txt').replaceAll('/tmp/receipt-rows.txt',root+'/receipt-rows.txt').replaceAll('/tmp/generic-rows.log',root+'/generic-rows.log');
fs.writeFileSync(root+'/suffix-executed.sh','set -e\n'+body);
fs.mkdirSync(root+'/conformance-receipts');
const rows = 'CG02 CG03 CG04 CG05 CG07 CG09 CG10 CG11 CG12 CG13 CG17 CG19 CG20 CL01'.split(' ');
for (const row of rows) fs.writeFileSync(root+'/conformance-receipts/receipt-'+row+'.json',JSON.stringify({row,verdict:['CG11','CG12','CG19'].includes(row)?'held-q002':row==='CG13'?'resolved-by-ruling':'agrees-with-model'}));
fs.writeFileSync(root+'/generic-rows.log','- Held (held-q002): CG11 CG12 CG19\n- Failing (accepted): none\n');
const results = [];
for (const [name,run_rc,cleanup] of [['intended',1,'agrees-with-model'],['crash127',127,'agrees-with-model'],['cleanup-failed',1,'could-not-execute']]) {
  fs.writeFileSync(root+'/conformance-receipts/receipt-CL01.json',JSON.stringify({row:'CL01',verdict:cleanup}));
  fs.copyFileSync(root+'/conformance-receipts/receipt-CL01.json',root+'/'+name+'-CL01.json');
  const r = cp.spawnSync('bash',[root+'/suffix-executed.sh'],{cwd:root,env:{...process.env,run_rc:String(run_rc)},encoding:'utf8'});
  fs.writeFileSync(root+'/'+name+'.stdout',r.stdout); fs.writeFileSync(root+'/'+name+'.stderr',r.stderr);
  results.push({name,run_rc,cleanup,exit:r.status,stdout:r.stdout});
}
const record = {scope:'Exact CI expected-debt adjudication suffix ONLY; fabricated fixture; no node, no whole workflow. Substitutions solely jq launcher and private temp paths.',sourceCommit:git('rev-parse','HEAD').trim(),sourceSha256:crypto.createHash('sha256').update(source).digest('hex'),results};
fs.writeFileSync(root+'/result.json',JSON.stringify(record,null,2));
fs.copyFileSync(__filename,root+'/probe.cjs');
fs.writeFileSync('/tmp/projects/singular/milestone-1/handoffs/expected-debt-control-path.txt',root+'\n');
console.log(JSON.stringify({root,...record},null,2));
