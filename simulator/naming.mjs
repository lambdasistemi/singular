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

/** The observations each section's rows must carry. The rows are verdicts the
 * Lean computed; a row that carries only an id is not evidence, and a checker
 * that waved it through would report rows it never looked at. */
const NAMING_OBSERVATIONS={
  spellings:['spelling','resolved'],
  queues:['expected','actual'],
  folds:['expected','actual'],
  steps:['expected','actual'],
  replays:['expected','actual'],
  resolves:['leaf','active','absent','terminal'],
};

/** A resolve row's observations must agree with the model's own laws: the
 * supply biconditional in full — Statements.lean S3 claims one witness IFF the
 * leaf says so AND zero witnesses IFF it does not, for both the active and the
 * absent kind — plus terminal attestation soundness (S1: no attestation of a
 * non-terminal leaf; plural attestations on a terminal leaf stay allowed, W3).
 * Kind exclusion is not checked separately: with the zero halves in place a
 * count above zero pins the leaf, and one leaf cannot be two states, so a row
 * failing exclusion always fails the biconditional or the terminal check
 * first. A row that claims witnesses and the wrong leaf contradicts itself
 * and is not evidence. */
function checkResolveObservations(row){
  const leaf=row.leaf==='unknown'?null
    :(row.leaf&&typeof row.leaf==='object'&&row.leaf.known?row.leaf.known.s:undefined);
  if(leaf!==null&&!['absent','active','terminal'].includes(leaf))
    throw Error(`naming resolve row with an unreadable leaf: ${row.id}`);
  for(const k of ['active','absent','terminal'])
    if(!Number.isSafeInteger(row[k])||row[k]<0)
      throw Error(`naming resolve row without a witness count: ${row.id}`);
  if((row.active===1)!==(leaf==='active')||(row.active===0)!==(leaf!=='active')||
     (row.absent===1)!==(leaf==='absent')||(row.absent===0)!==(leaf!=='absent'))
    throw Error(`naming resolve row contradicts the supply biconditional: ${row.id}`);
  if(leaf===null&&(row.active>0||row.absent>0||row.terminal>0))
    throw Error(`naming resolve row claims witnesses on an unknown leaf: ${row.id}`);
  if(leaf!=='terminal'&&row.terminal>0)
    throw Error(`naming resolve row attests a leaf that is not terminal: ${row.id}`);
}

/** Inspect the naming corpus: every row states an expectation the Lean model
 * computed, and every row must still say what it said, completely — an
 * id-only row, a missing observation, a duplicate id or a row that
 * contradicts itself is a failure, not a smaller pass.
 *
 * The receipt reports INSPECTION, never execution: nothing here runs a
 * transition, so `executed` is zero by construction and the page labels say
 * "inspected", not "replayed". */
export function checkNamingCorpus(corpus){
  let discovered=0,inspected=0;
  const ids=new Set(),bySection={};
  for(const section of NAMING_SECTIONS){
    const rows=corpus[section];
    if(!Array.isArray(rows)||rows.length===0)
      throw Error(`empty naming corpus section: ${section}`);
    bySection[section]=0;
    for(const row of rows){
      discovered++;
      if(typeof row.id!=='string'||!row.id)
        throw Error(`naming row without an id in ${section}`);
      if(ids.has(row.id))throw Error(`duplicate naming row: ${row.id}`);
      ids.add(row.id);
      for(const field of NAMING_OBSERVATIONS[section])
        if(!(field in row))
          throw Error(`naming row missing its ${field} observation: ${row.id}`);
      if(section==='spellings'){
        if(typeof row.resolved!=='boolean')
          throw Error(`naming row without a boolean verdict: ${row.id}`);
        if(row.resolved&&(!Number.isSafeInteger(row.key)||row.key<0))
          throw Error(`naming row claims a resolution without the key: ${row.id}`);
      }else if(section==='resolves'){
        checkResolveObservations(row);
      }else{
        if(typeof row.expected!=='boolean'||typeof row.actual!=='boolean')
          throw Error(`naming row without a boolean verdict: ${row.id}`);
        if(row.expected!==row.actual)
          throw Error(`naming row disagrees with its own expectation: ${row.id}`);
      }
      bySection[section]++;
      inspected++;
    }
  }
  if(discovered!==inspected)throw Error('naming denominator');
  return {discovered,inspected,executed:0,sections:NAMING_SECTIONS.length,
    bySection,boundary:'evidence'};
}

/** The Over witness, played rather than asserted: book a name, retire it, and
 * watch the attestation minted by a folded read — twice, because it is plural —
 * then burned, because an implicational witness may be. Unlike the corpus
 * checks above this EXECUTES behavior: each step runs the engine. */
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
