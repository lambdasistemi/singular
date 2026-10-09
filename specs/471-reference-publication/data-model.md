# Publication and funding: data model

Placement is in [modules-model.md](modules-model.md). Exact inherited identity/refusal rules
remain in the parent [data model](../437-join-by-token/data-model.md).

## Capabilities

Session is abstract to shipped builders and CLI: no constructor, raw fields, record update,
generic output queries/combinators or raw history. Provider constructors return this abstraction.
WalletOutputs is opaque; its defining module alone can construct or read its raw collection.
Only filtered funding and named protocol/carrier selections expose permitted input purposes.

The ordinary funding view contains ADA-only outputs without reference scripts. A chosen input
restriction narrows this view only, persists across later acquisitions, and never changes
reference fallback, owned-carrier matching, protocol/history/observation reads or other addresses.
Create's fundable seed is reserved from publication funding without changing its identity.
Burn candidates name the exact required policy/name; there is no all-token funding view.

SeedRefusal distinguishes absent from not fundable. FundingRefusal distinguishes absent from
ineligible chosen funding. FundingViewRefusal separates FundingReadFailure ReadFailure from
FundingInputRefusal FundingRefusal. These internal distinctions preserve existing public
failure classes/messages and refusal order rather than adding outcomes.

ScriptAddress has a private constructor and accepts script payment credentials only. Exact
output visibility takes the expected input/output pair. Address-wide recovery/refund observations
remain address-wide, and inspect reporting preserves its JSON and failure behavior.

## Scripts and publication

ReferenceRole retains the existing six-role vocabulary. Expected hashes derive from the release
and token; built scripts are locally hash-checked against those roles. ReferenceScriptMismatch
records role, expected and actual built hashes; public refusal is reference-script-mismatch.
Missing-reference discovery returns admitted role/carrier pairs and the still-missing role set.
Read failure remains distinct from successful emptiness.

One publication transaction creates one minimum-ADA output per selected missing script at the
payer's address. Each receipt identifies the destination, role, script hash, transaction and output
reference, with confirmed live readback. No registry/token creation, state change or permanent
carrier lifetime is inferred. In-flight submissions use existing retained transaction identity
and recovery records; retry reconciles that identity instead of blind resubmission.

PublishArgs uses existing token, blueprint, network/provider, wallet/actor-directory, preview,
receipt and applicable fund-input/max-outlay settings, plus repeatable requested roles.
No selected role means all missing roles. Explicit automatic publication is opt-in for existing
transaction-building commands and restores only their missing needed roles.

New retirement and page data are not delivered in this slice. Physical script placement and
reference lifetime remain outside the abstract Lean model; actual ledger evidence establishes
this command's narrower preservation claims.
