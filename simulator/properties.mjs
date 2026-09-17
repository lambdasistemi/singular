// What the corpus exhibits, per statement. This is a coverage report, not a
// proof: a finite row can exhibit a theorem's consequent, never its quantifier.
// The proofs live in Lean; this says which of them a reader can watch happen.
import {step,witnesses,trieGet} from './core.mjs';

/** Checks that must HOLD on every accepted row. Each is a consequence of a
 * named law, evaluated on the row's own result — so a row that violated it
 * would turn this red rather than merely look odd. */
export const checks={
  active_witness_unique:(before,action,after)=>
    witnesses(after,action.key).active<=1,
  absent_witness_unique:(before,action,after)=>
    witnesses(after,action.key).absent<=1,
  witness_kinds_exclude:(before,action,after)=>{
    const w=witnesses(after,action.key);
    return [w.active>0,w.absent>0,w.terminal>0].filter(Boolean).length<=1;},
  biconditional_supply_sync:(before,action,after)=>{
    const leaf=trieGet(after.trie,action.key),w=witnesses(after,action.key);
    return (w.active===1)===(leaf==='active')&&(w.absent===1)===(leaf==='absent');},
  terminal_attestation_sound:(before,action,after)=>
    after.held.filter(h=>h.kind==='terminal')
      .every(h=>trieGet(after.trie,h.key)==='terminal'),
  termination:(before,action,after)=>
    trieGet(before.trie,action.key)!=='terminal'||
    trieGet(after.trie,action.key)==='terminal',
  occupancy:(before,action,after)=>{
    if(!['insertActive','updateActive'].includes(action.edge))return true;
    const was=trieGet(before.trie,action.key);
    return was!=='active'&&was!=='terminal'&&trieGet(after.trie,action.key)==='active';},
};

/** One row per statement: whether the corpus exhibits it, and whether the
 * consequent held everywhere it was exhibited. */
export function theoremReport(manifest,corpus){
  const rows=[];
  for(const decl of manifest){
    const short=decl.name.split('.').at(-1);
    const checker=checks[short];
    let exhibited=0,held=0;
    if(checker)for(const row of corpus.cases){
      if(!row.expectedAccept)continue;
      const r=step(row.before,row.action);
      if(!r.accepted)continue;
      exhibited++;
      if(checker(row.before,row.action,r.value.state))held++;
    }
    rows.push({name:decl.name,status:`${decl.status} / ${decl.debt}`,
      coverage:checker?'controlled-check':'proved-only',
      exhibited,held,
      note:checker
        ?'Finite consequent checks over the corpus; the quantified statement is proved in Lean.'
        :'No executable exhibit here; the quantified statement is proved in Lean.'});
  }
  return rows;
}
