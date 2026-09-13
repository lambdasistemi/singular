# HashVectors failure: the recorded reference is mistranscribed

Root read /tmp/blaster-clean-build.log at its terminal failure: HashVectors.lean:49 expected `info: true`, got `info: false`; Scripts, Properties, EndWitness and ModifyWitness built. The failure alone does not identify a crypto implementation defect.

Independent root comparison of the actual HashVectors.lean ABC_HASH bytes against Python hashlib.blake2b(b'abc', digest_size=32) proves ten differing byte positions in the recorded reference. Evidence retained at /tmp/projects/singular/milestone-1/handoffs/blaster-hash-reference/: exact observed Lean source, source SHA256, interpreter identity, comparison script and reference.json.

Correct independent reference: bddd813c634239723171ef3fee98579b94964e3bb1cb3e427262c8c068d52319.
Recorded ABC_HASH: bddd813c634239723171ef3fee98567994964e3bbb1cb3e427622c8c06d52319.

The observed source says the bytes were mechanically compared, but they do not match that named reference. Route this concrete correction to the existing driver so it does not spend another dependency investigation on a mistranscribed oracle. Generate/check the bytes mechanically against the independent reference, retaining the wrong vector as a failing control. Do not merely flip expected true to false. Then rerun the affected assertion module with the existing compiled dependencies; there is no reason here to clean/rebuild the whole dependency graph. This establishes the oracle defect only; actual CEK hash correctness remains to be observed after correction. The original unknown/compiled-invariant debt remains unchanged, with no acceptance or semantic waiver.

Continue the already-authorized hash vectors, malformed-argument refusal, real Update path and runner-level controls. No new worker or audit. If the driver has independently found this meanwhile, consume its result rather than repeat it.
