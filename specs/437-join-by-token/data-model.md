# A registry joined from its state token: data model

These are the new or changed records. Module placement is in the
[modules model](modules-model.md).
PR1 base `23964e667fa278b2027d0c05169c0f5e0e9233cb` carries Lean tree
`16ee2d4a4233130460b7e36daffbe6f2b8b9a8ef` and constitution 1.13.0. The #419 request datum
value, held/witness datum and public fold representation are inherited without a model change.

## State token

A state token is an `Asset` (state policy, token name). On the command line it is written
`POLICY.NAME`, each part in hex; the policy is 28 bytes and the name 32 bytes.

- Parsing refuses any other shape before any provider call.

## Mint record

| field | meaning |
|---|---|
| minting transaction | the transaction that minted the asset |
| spent inputs | every input that transaction spent |
| supply | the asset's current total supply |

- The provider returns no record for an asset it does not know.

## Reference role and expected hashes

- **Roles:** the state, the request, absent witness, active witness and terminal witness scripts,
  and the application. They are spelled as the existing reference roles in receipts:
  `state`, `request`, `witness-absent`, `witness-active`, `witness-terminal`, `application`.
- **Expected hashes:** a total map from role to script hash, derived from the release and the
  token alone.
  - The state hash equals the token's policy for an admitted token.
  - Every other role's hash is the release's script for that role applied to the registry
    identity, `statePolicy ‖ tokenName`.

## Reference carrier

| field | meaning |
|---|---|
| output reference | where the carrier sits |
| output | the exact output as the provider returned it |
| source | the provider query or the actor's wallet |

- A carrier is admitted for a role only if the output carries a reference script and the hash
  computed from that script equals the role's expected hash.
- A provider-supplied hash field is never read.
- The provider is tried first; the wallet is read only for roles the provider did not supply.
  Within the first source supplying a role, the lowest admitted output reference is chosen.
- Only needed roles are searched; no needed roles means no discovery reads.

## Resolved registry

| field | meaning |
|---|---|
| token | the state token |
| seed | the input of the minting transaction whose derived name equals the token name |
| creation transaction | the minting transaction |
| state output | the output holding the token, with its decoded state datum |
| rules | the windows and the tip, read from the datum |
| configuration | the pinned registry configuration derived from the release and the token, equal to the datum's four policies |
| expected hashes | as above |
| network | the provider session's network |

- A resolved registry exists only after every identity check passes.
- It is never written to disk.

## Refusals

**Identity refusals.** Seven, rendered in this order of checking:
1. `state-token-foreign-release`
2. `state-token-not-found`
3. `state-token-burned`
4. `state-token-seed-mismatch`
5. `state-output-missing`
6. `registry-pin-mismatch <field>`
7. `network-mismatch`

**Reference refusal.** `reference-missing <role> <hash>: not found by this provider or wallet`.
Its message names `singular registry publish-references` as the remedy.

## Actor directory

Allowed contents:
- `journal.jsonl`, `submissions/`, `.lock`;
- `registry.pending.json`, during `create` only.

Anything else is ignored. Nothing in the directory is an input to identity or reference
resolution.
Bob receives no Alice directory/files. His fold uses the registry's public history and requests
whose datums carry the value they name, preserving #419's removal of private preimage inputs.

## Deferred PR2 records

The closed wallet-output funding view, required-token selection, narrowed fund inputs, registry
page/release-archive records and independently derived report action identity remain required
by the full issue and are not delivered by PR1. Their accepted A-009/A-011/A-012/A-013 bindings and preserved plans remain requirements
for the same open issue. Retirement records retain their reason/history without carrying an old
receipt or product state into another row.

The next funding phase versions opaque WalletOutputs and its named protocol selectors against
current main; no raw wallet list reaches builders. Page facts include ReleaseInfo from adjacent
version.txt, blueprint digest and computed ConformanceLocation; an unverified BlockPoint for the
last state transaction is distinct from a missing anchor or failed read. The page carries identity,
rules, public replay, provider-found references, archive-claimed release facts and computed links,
with deterministic human and machine representations. These are required records, not observed
product facts. Exact fields/refusals and callable interfaces are adapted from the retained PR2
model before implementation; no private preimages or caller reference hints may reappear.
