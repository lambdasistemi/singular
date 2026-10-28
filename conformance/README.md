# The registry's promises and evidence

As an integrator, I read the registration, holding update, termination and reading
requirements and see which comparisons have evidence.
[The consumer record](../docs/consumer-conformance.md) explains the interface;
[the generated evidence page](../docs/conformance-evidence.md) publishes every
requirement and computes its standing from validated receipts.

The seven comparison requirements and four reading requirements remain uncovered. No executable comparison
with the application-held model exists yet. Development-network journeys are
separate evidence and do not establish model agreement.

```sh
nix run ./conformance#conformance -- list
nix run ./conformance#conformance-appendix-tests
```


`list --receipts DIR` validates the caller's receipt directory. Without a
receipt for the current revision the inventory publishes the declared plan.
The appendix tests check the reader and its refusal controls; they do not
supply product evidence.

## Reading a registry key

As a reader, I supply a registry address and key without a signer, blueprint or
local registry state. The four reading requirements describe the neutral key
status, the application's holding and pending-termination answers, measured
provider work beside another registry's holdings, and named refusals. They stay
uncovered because no executable model comparison backs them yet. The separate
packaged-command evidence is uploaded by the registration journey and refusals
jobs; it establishes the observed command behavior and measured work only.
