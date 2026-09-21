// What the corpus exhibits, per statement. This is a coverage report, not a
// proof: a finite row can exhibit a theorem's consequent, never its quantifier.
// The proofs live in Lean; this says which of them a reader can watch happen.
import {step,witnesses,trieGet} from './core.mjs';

/** Checks that must HOLD on every accepted row where the law's hypotheses are
 * active. Each entry names the statement's own hypothesis separately from its
 * consequence: `applies` decides whether the row is an example of the law at
 * all, `law` evaluates the consequence. A row outside `applies` can satisfy
 * the implication vacuously, so it is counted as vacuous, never as exhibited. */
export const checks={
  active_witness_unique:{
    applies:(before,action,after)=>witnesses(after,action.key).active>0,
    law:(before,action,after)=>witnesses(after,action.key).active<=1},
  absent_witness_unique:{
    applies:(before,action,after)=>witnesses(after,action.key).absent>0,
    law:(before,action,after)=>witnesses(after,action.key).absent<=1},
  witness_kinds_exclude:{
    applies:(before,action,after)=>{
      const w=witnesses(after,action.key);
      return w.active+w.absent+w.terminal>0;},
    law:(before,action,after)=>{
      const w=witnesses(after,action.key);
      return [w.active>0,w.absent>0,w.terminal>0].filter(Boolean).length<=1;}},
  biconditional_supply_sync:{
    applies:(before,action,after)=>{
      const w=witnesses(after,action.key);
      return w.active+w.absent>0;},
    law:(before,action,after)=>{
      const leaf=trieGet(after.trie,action.key),w=witnesses(after,action.key);
      return (w.active===1)===(leaf==='active')&&(w.absent===1)===(leaf==='absent');}},
  terminal_attestation_sound:{
    applies:(before,action,after)=>after.held.some(h=>h.kind==='terminal'&&h.key===action.key),
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
 * consequence held everywhere the hypotheses were active. `vacuous` counts
 * accepted rows that passed through an inactive hypothesis; a law with no
 * applicable example is never reported as exercised. */
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
