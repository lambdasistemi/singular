// Request and approval builders. An approval's asset name commits to the tuple
// it scopes (D-APPROVAL), so a builder is the only honest way to make one: a
// hand-written name would not match and the fold would refuse it.
import {approvalAssetName,requestDestination} from './core.mjs';

export const POLICY=7;

export const request=(edge,key,opts={})=>({
  edge,key,
  owner:opts.owner??0,
  refundAddress:opts.refundAddress??0,
  deposit:opts.deposit??0,
  tip:opts.tip??0,
  reference:opts.reference??0,
  output:opts.output??0,
  approval:null,
  claimed:opts.claimed??[]});

/** An approval scoped to exactly this request. */
export const approvalFor=(r,opts={})=>{
  const destination=requestDestination(r);
  return {policy:opts.policy??POLICY,edge:r.edge,key:r.key,owner:r.owner,destination,
    assetName:opts.assetName??approvalAssetName(r.edge,r.key,r.owner,destination),
    signatures:opts.signatures??[]};
};

/** A request carrying a matching approval: the normal case. */
export const approved=(edge,key,opts={})=>{
  const r=request(edge,key,opts);
  return {...r,approval:approvalFor(r,opts)};
};

/** A request whose approval is under the correct policy but names another
 * tuple — the case D-APPROVAL exists to refuse. */
export const mismatched=(edge,key,opts={})=>{
  const r=request(edge,key,opts);
  const ap=approvalFor(r,opts);
  return {...r,approval:{...ap,key:ap.key+1,
    assetName:approvalAssetName(ap.edge,ap.key+1,ap.owner,ap.destination)}};
};

/** A request whose approval is under some other policy entirely. */
export const otherPolicy=(edge,key,opts={})=>{
  const r=request(edge,key,opts);
  return {...r,approval:approvalFor(r,{...opts,policy:99})};
};

/** The read needs no approval at all. */
export const read=(key,output=0)=>request('witnessTerminal',key,{output});
