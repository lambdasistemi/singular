// What the corpus exhibits, per statement. This is a coverage report, not a
// proof: a finite row can exhibit a theorem's consequent, never its quantifier.
// The proofs live in Lean; this says which of them a reader can watch happen.
import {step,witnesses,trieGet} from './core.mjs';

/** Checks transcribed from the exact bound declarations of their Lean
 * statements. `applies` is the statement's own hypothesis and nothing else:
 * a law whose declaration assumes nothing beyond reachability (W1, W2, W4,
 * S3) applies to EVERY accepted row, because the replayed after-state is
 * reachable by construction and output witness presence is a consequence of
 * these laws, never their hypothesis — gating `applies` on witnesses would
 * let an absence or wrong-multiplicity defect demote a violated law to an
 * inactive hypothesis. `law` is the full consequent, both biconditional
 * halves included. Only the statements with real hypotheses (termination's
 * terminal leaf, occupancy's booking edges, S1's existing attestation) leave
 * rows outside `applies`; those count as vacuous, never as exhibited. */
export const checks={
  active_witness_unique:{
    applies:()=>true,
    law:(before,action,after)=>{
      const leaf=trieGet(after.trie,action.key),w=witnesses(after,action.key);
      return w.active<=1&&(w.active===1)===(leaf==='active');}},
  absent_witness_unique:{
    applies:()=>true,
    law:(before,action,after)=>{
      const leaf=trieGet(after.trie,action.key),w=witnesses(after,action.key);
      return w.absent<=1&&(w.absent===1)===(leaf==='absent');}},
  witness_kinds_exclude:{
    applies:()=>true,
    law:(before,action,after)=>{
      const w=witnesses(after,action.key);
      return [w.active>0,w.absent>0,w.terminal>0].filter(Boolean).length<=1;}},
  biconditional_supply_sync:{
    applies:()=>true,
    law:(before,action,after)=>{
      const leaf=trieGet(after.trie,action.key),w=witnesses(after,action.key);
      return (w.active===1)===(leaf==='active')&&(w.active===0)===(leaf!=='active')&&
             (w.absent===1)===(leaf==='absent')&&(w.absent===0)===(leaf!=='absent');}},
  terminal_attestation_sound:{
    applies:(before,action,after)=>after.held.some(h=>h.kind==='terminal'),
    law:(before,action,after)=>
      after.held.filter(h=>h.kind==='terminal')
        .every(h=>trieGet(after.trie,h.key)==='terminal')},
  termination:{
    applies:(before,action)=>trieGet(before.trie,action.key)==='terminal',
    law:(before,action,after)=>trieGet(after.trie,action.key)==='terminal'},
  occupancy:{
    applies:(before,action)=>['insertActive','updateActive'].includes(action.edge),
    law:(before,action,after)=>{
      const was=trieGet(before.trie,action.key);
      return was!=='active'&&was!=='terminal'&&trieGet(after.trie,action.key)==='active';}},
};

/** One row per statement: whether the corpus exhibits it, and whether the
 * consequence held everywhere the statement's own hypotheses were active.
 * `vacuous` counts accepted rows outside `applies`; for the unconditional
 * laws (W1, W2, W4, S3) that is zero by construction and every accepted row's
 * consequent is evaluated. A law with no applicable example is never reported
 * as exercised. */
export function theoremReport(manifest,corpus){
  const rows=[];
  for(const decl of manifest){
    const short=decl.name.split('.').at(-1);
    const entry=checks[short];
    let applicable=0,held=0,vacuous=0;
    if(entry)for(const row of corpus.cases){
      if(!row.expectedAccept)continue;
      const r=step(row.before,row.action);
      if(!r.accepted)continue;
      if(entry.applies(row.before,row.action,r.value.state)){
        applicable++;
        if(entry.law(row.before,row.action,r.value.state))held++;
      }else vacuous++;
    }
    const exercised=!!entry&&applicable>0&&held===applicable;
    rows.push({name:decl.name,status:`${decl.status} / ${decl.debt}`,
      coverage:entry?'controlled-check':'proved-only',
      applicable,held,vacuous,exercised,
      note:entry
        ?(exercised
          ?'Finite applicable examples over the corpus; the quantified statement is proved in Lean.'
          :'No applicable example in this corpus; only the Lean proof covers this statement.')
        :'No executable exhibit here; the quantified statement is proved in Lean.'});
  }
  return rows;
}
