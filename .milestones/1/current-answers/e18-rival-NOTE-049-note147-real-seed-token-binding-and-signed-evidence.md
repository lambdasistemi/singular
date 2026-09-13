# NOTE-049 — NOTE-147 real seed-token binding and complete signed evidence

Read and ACK in `STATUS.md`. Continue the same `%994` NOTE-048 offline-only
block. Let the currently in-flight mintless-control compile/run finish unchanged
and preserve its true output and exit. This is an amendment to that block, not a
terminal handback, context reset, or ledger release.

Root's static review is frozen at
`/tmp/projects/singular/milestone-1/handoffs/rival-root-note048-source-review.json`
(SHA256
`2dd5bb637fb8500cd2fc4d920294aeea6b9a4117e204fa99bb01be859812760d`).
It reviewed Main
`601610bf15f3eda302857af6a73f1497f789dcb2854bf961cf51972fd74da3a9`,
the current seed control
`5ffacfd01edf8aaabea172bf6cb80245b2e531b7c8c3d5a09b6745a752052396`,
and mintless helper
`b1c89e02a05ffee2daaf76dbaf832d7eebf8d8d8867e571553383ae4462f1039`.
These are reviewed snapshots, not accepted results or executed root controls.

## 1. One real configured-seed-to-token verifier

The current three independent checks—configured seed occurs among the signed
boot inputs, actual mint contains `tokB` at quantity 1, and `tokB /= tokA`—do
not prove that the selected configured seed derived `tokB`. With both the real
seed and an extra funding input consumed, substituting that funding input as
the alleged seed can leave all three predicates true.

Factor one actual verification function used by both `runRivalSetup` and the
new named controls. It must take the configured seed from returned `cfgB` and
the actual signed boot transaction, apply the existing production derivation
rule (`deriveAssetName` for that exact on-chain seed reference) and require the
derived token identity to equal the one exact quantity-1 token minted under
the executed B cage policy. Equivalently, additionally bind the actual minting
redeemer's seed for that executing policy, but a mere input-membership predicate
is insufficient. Also require the configured seed input is actually consumed
and preserve the distinct-B-from-A check.

The separately named positive seed-plus-fee control must call this same
verification function on an actual typed boot-shaped value: configured seed and
distinct fee input both spent, exact configured-seed-derived token minted at
quantity 1, every other live valid funding input selectable, both spent inputs
unselectable. Its wrong-seed case changes only the selected configured seed to
the spent fee input while retaining the actual mint/inputs/policy; the real
verification function must return false and the control must exit nonzero if it
does not discriminate. Do not credit the current locally constructed flag-list
comparison as seed-binding evidence; retain it only as bounded funding-selection
evidence. Preserve the existing 22/5 denominator separately.

## 2. Preserve complete signed transaction and TxOut evidence

Keep the current exact serialization of `bodyTxL`, and additionally serialize
and write the complete signed boot and complete signed target transactions so
an independent reader can recover witnesses, redeemers and executing script
material. The full-transaction path must consume the exact signed value passed
to `submitTx`, not reconstruct a summary. Retain distinct, stable filenames for
body bytes and full signed transaction bytes. Add an offline round-trip or typed
readback control where available that proves the retained full encoding recovers
the same body/transaction identity and the expected witness/redeemer material;
a nonempty file or source grep is not evidence.

For every retained UTxO observation, write:

- the query address that produced the observation;
- the complete exact `TxIn` outref;
- exact serialized `TxOut` bytes; and
- decoded address, value/assets, datum and other fields needed to recover B's
  configured seed/NFT/address/root/value successor and refused-input liveness.

Do not replace exact bytes with `show`, a summary boolean or source assertion.
Use only existing dependencies and the isolated evidence path; no service or
ambient environment dump.

## 3. Condition post-state evidence on the actual result

Immediate snapshots taken after `submitTx` but before confirmation may remain,
but name them explicitly as pre-confirmation and do not cite them as the later
successor.

For `Submitted`, first complete the existing confirmation/observation step,
then query and retain the exact target-created B successor joined to the complete
target TxId, together with the old B anchor and attempted record's post-state.
The retained record must include complete address, exact B policy/token quantity,
root and value data and must distinguish consumed old inputs from the live
target-created successor.

For `Rejected`, retain the full typed raw result, require exact executing
application subject and explicit non-budget classification, then query and
retain both exact attempted record and attempted anchor as still live. A query
or setup failure is not a semantic refusal.

## 4. Finish the existing offline handback only

Fold these changes into NOTE-048's actual mintless construction/control,
changed-source executable builds, Nix wrapped source closure, exact evidence
index and fresh guarded unexecuted command. Preserve current and earlier
compile/setup failures with their true exits. Do not run a node, query a socket,
invoke the official wrapper, create the new result root, submit a transaction,
or execute any ledger command. Stop for owner review of the frozen candidate.

No second ledger run, automatic retry, blanket replay, new seat/reset/model,
product/compositor/schema/model adoption, commit, push, merge, release or
acceptance. A006 and E17 continue independently.
