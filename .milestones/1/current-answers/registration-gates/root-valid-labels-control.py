#!/usr/bin/env node
// NEGATIVE CONTROL ONLY: fabricate reports, execute no build, script or ledger.
const fs=require('fs'),cp=require('child_process'),p=require('path');
const out=process.argv[2];
const names=['producer-state','producer-request','producer-application','producer-applied-representative','registry-adapter','checkpoint-policy','lifecycle-observer'];
const ids=['E0-register-valid-cek','E0-register-valid-ledger','E1-missing-inception-cek','E1-missing-inception-ledger','E4-wrong-allocation-cek','E4-wrong-allocation-ledger','register-omitted-adapter','register-swapped-adapter','register-extra-checkpoint-mint','register-wrong-aid-name','register-delete','register-surplus-action'];
const controls=['always-refuse','always-accept','remove-inception-observer-check','remove-allocation-check','remove-unaccounted-checkpoint-check','remove-mandatory-adapter-invocation','inventory-remove-one'];
const write=(name,data)=>fs.writeFileSync(p.join(out,name),JSON.stringify(data,null,2)+'\n');
write('identity.json',{schema:'singular-consumer-registration-identity-v1',candidate_commit:cp.execFileSync('git',['rev-parse','HEAD'],{cwd:__dirname,encoding:'utf8'}).trim(),tree_clean:true,consumer_source_commit:'14a64a4681d3e429fab5877062b5c476c2a4bfe2',compiler:{aiken_actual:'NO COMPILER EXECUTED'},plutus_version:'v3',protocol_major:10,builtin_semantics_variant:'defaultFunSemanticsVariantC',artifacts:names.map(name=>({name,source_digest:'0'.repeat(64),compiled_digest:'0'.repeat(64),script_hash:'0'.repeat(56)}))});
write('results.json',{schema:'singular-consumer-registration-results-v1',rows:ids.map(id=>({id,expected:id.startsWith('E0-')?'ESTABLISHED':'REFUTED',observed:id.startsWith('E0-')?'ESTABLISHED':'REFUTED',stage:id.endsWith('-ledger')?'submitted-ledger':'compiled-cek',purpose:id.startsWith('E1-')?'lifecycle withdrawal':id.startsWith('E4-')?'adapter withdrawal':'producer state spend',evidence:['does-not-exist.log']}))});
write('controls.json',{schema:'singular-consumer-registration-controls-v1',controls:controls.map(id=>({id,verdict:'REFUTED',clean_restored:true,source_rebuilt:true,compiled_bytes_changed:true,inventory_changed:true,evidence:['also-does-not-exist.log']}))});
console.log('CONTROL: wrote claims only; no Aiken, CEK, cardano-cli, node, or mutation execution.');
