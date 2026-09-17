// The naming profile. Naming is an *instance* of the registry, not a second
// model, so this does not re-implement it: it replays the rows the Lean naming
// corpus exports and plays the one journey a reader should watch — a retired
// name attested by a folded read, the Over witness minted and freely burned.
//
// Re-implementing naming in JavaScript is what the previous simulator did, and
// it is how a mirror drifts from what it mirrors.
import {initial,step,witnesses,trieGet} from './core.mjs';
import {approved,read} from './actions.mjs';

export const NAMING_SECTIONS=['spellings','queues','folds','steps','resolves','replays'];

/** Replay the naming corpus: every row states an expectation the Lean model
 * computed, and every row must still say what it said. */
export function checkNamingCorpus(corpus){
  let discovered=0,executed=0;
  const ids=new Set();
  for(const section of NAMING_SECTIONS){
    const rows=corpus[section];
    if(!Array.isArray(rows)||rows.length===0)
      throw Error(`empty naming corpus section: ${section}`);
    for(const row of rows){
      discovered++;
      if(ids.has(row.id))throw Error(`duplicate naming row: ${row.id}`);
      ids.add(row.id);
      if('expected' in row&&'actual' in row&&row.expected!==row.actual)
        throw Error(`naming row disagrees with its own expectation: ${row.id}`);
      if('resolved' in row&&typeof row.resolved!=='boolean')
        throw Error(`naming row has no verdict: ${row.id}`);
      executed++;
    }
  }
  if(discovered!==executed)throw Error('naming denominator');
  return {discovered,executed,sections:NAMING_SECTIONS.length};
}

/** The Over witness, played rather than asserted: book a name, retire it, and
 * watch the attestation minted by a folded read — twice, because it is plural —
 * then burned, because an implicational witness may be. */
export function overWitnessJourney(key=42,owner=42,output=555){
  const steps=[];
  let state=initial();
  const take=(what,req)=>{
    const r=step(state,req);
    steps.push({what,edge:req.edge,accepted:r.accepted,
      reason:r.accepted?'':r.reason,
      witnesses:r.accepted?witnesses(r.value.state,key):witnesses(state,key),
      leaf:r.accepted?trieGet(r.value.state.trie,key):trieGet(state.trie,key)});
    if(r.accepted)state=r.value.state;
    return r;
  };
  take('the controller books the name',approved('insertActive',key,{owner,output}));
  take('the quorum retires it: updateTerminal',approved('updateTerminal',key,{owner,output}));
  take('a folded read mints the Over witness',read(key,700));
  take('and another: the terminal witness is plural',read(key,701));
  // burning is free: an implicational witness may be dropped and stays true
  const burned={...state,held:state.held.filter(h=>h.kind!=='terminal')};
  steps.push({what:'both Over witnesses burned; the leaf is still terminal',
    edge:'(burn)',accepted:true,reason:'',
    witnesses:witnesses(burned,key),leaf:trieGet(burned.trie,key)});
  return {steps,final:burned};
}
