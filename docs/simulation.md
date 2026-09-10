# Simulation candidate

<a href="https://lambdasistemi.github.io/singular/simulator/">Open the playable Singular simulator</a>. Choose **m1-naming** for the bounded first-release naming journey, or leave **generic** selected for the registry demonstration where Delete and authorized Insert withdrawal are allowed. The profiles are labelled and neither silently falls back to the other.

Register a name, explore competing requests, cancel an Insert, change its address, retire it, or delete and reinsert it in a batch. Choose a story, advance with **›**, or press **▶** to play to its outcome. Click any tree node to revisit its state. A new manual attempt creates another branch without removing the previous play.

For the naming journey, select **m1-naming**, queue two claims for `alice`, fold the first, then fold the second to observe `occupied-key`. Resolve the active record to inspect its certified fixture, and submit the crafted Delete to observe `naming-no-delete`. Then open the [playable naming lifecycle](naming-lifecycle.md) to maintain the payment destination, recover through the committed next controller, or queue and separately complete retirement through the controller or quorum route. Naming-claim cancellation is on hold and has no control; retirement-request withdrawal is a distinct refused attempt.

## Try the manual controls

1. In **Free play**, leave name key **42** and address datum **100**, then press **Queue Insert**. Change the datum to **200** and queue a second Insert for the same key.
2. Select the first request in the batch composer and press **Fold selected batch**. Name 42 now resolves to address 100. The competing request remains pending.
3. Select that pending Insert under cancellation. Press **Withdraw Insert** before approval to see its refusal. Then press **Approve exact withdrawal** and **Withdraw Insert**, using the same request and refund fields.
4. Select the application UTxO. Turn application evidence off and try **Change address** to see the refusal. Restore the evidence and change the datum to 200.
5. Press **Queue retirement (Update)** or **Queue Delete**. Resolve the name while its NFT is in request custody: the result is **pending**. Select the terminal request and fold it. Update ends at **retired**; Delete ends at **absent**.

The **Delete and reinsert in a batch** story supplies an Insert approved for the next incarnation. Its ordered batch applies Delete first, then Insert. Inspect **Successive batch effects** for each accumulator state. The logical burn and mint cancel for the default reusable NFT identity. A failure rolls back the whole selected batch; tentative intermediate effects are labelled accordingly.

The **Advanced free play** drawer exposes exact action JSON for every modeled action constructor. Examples come from the frozen corpus; they can intentionally fail when the current state differs. Edit witnesses, evidence, scope, asset identities, and net quantities there. Numeric inputs outside the exact JavaScript integer domain are refused. The resolver can also be queried with an unauthenticated view.

## What the evidence establishes

This is a **SIMULATOR-CANDIDATE**. The generic model has **41** Lean theorem declarations and the naming layer has **17**; all are **PROVED** from the standard axioms. The simulator's finite checks measure transcriptions of those models, not the proofs; no acceptance is claimed.

The focused gate replays **58 frozen generic Lean rows** — 52 transitions and 6 resolutions — plus **34 frozen naming rows** and **38 lifecycle and wire rows**. The lifecycle denominator covers maintenance, recovery, retirement, resolution, initialization, re-registration, and the exact four-field wire datum. The eight generic story trees contain **32 action steps**, including refusal forks. Story and manual steps outside the exact corpus input set exercise a transcription only; they do not acquire Lean parity by resemblance to a corpus row.

The generic theorem ledger has **12 controlled finite checks**, **17 action exhibits only**, and **12 explicit gaps**. The naming ledger has **15 controlled finite checks**, **2 exhibits only**, and **0 gaps**. Each controlled check has a fabricated intended-result failure. An action exhibit does not check its full quantified theorem. The page displays these distinctions; it does not turn unexhibited rows into passing lamps.

The Node gate also exercises **1,772 public-boundary probes** and **43 negative controls**. The source-derived generic refusal inventory currently exhibits **17 of 28 distinct model reasons**. Missing reason exhibits and generic theorem gaps remain in the [clarity record](LEAN-CLARITY.md), with exact names in the repository’s [coverage ledger](https://github.com/lambdasistemi/singular/blob/main/simulator/coverage.json).

## Model and assumptions

<a href="../lean/Singular/Model.lean">Frozen executable model</a> · <a href="../lean/Singular/Statements.lean">Theorem statements</a> · <a href="../lean/corpus.json">Lean-generated corpus</a>.

The generic model uses tagged terms for collision-free commitments and lists for authenticated logical maps and UTxO sets. Application acceptance and witness flags are supplied evidence. This page does not execute validators, verify signatures, or model wallet balances. Refund values are commitments; no refund-payment result exists in the modeled transition output. The naming fixture uses canonical binary Cardano address shapes, a 32-byte next-controller commitment, and a published threshold quorum. The browser exercises those shapes through the integrated lifecycle transition, but that design-time execution does not claim compiled-script interoperability or a ledger transaction.

Address evolution and retirement are different operations: `evolve` changes the application output without changing the registry; `update` completes retirement to `over`. The model’s `conforms` diagnostic does not enforce application semantics. Read the [clarity record](LEAN-CLARITY.md) before treating an observed outcome as a deployment guarantee.

## Reproduce the focused checks

From a source checkout:

```sh
node simulator/build.mjs --check
node simulator/gate.mjs
node simulator/gate.mjs --selftest
node simulator/lifecycle-gate.mjs
nix run .#browser-check
nix run .#lifecycle-browser-check
```

From the root of a freshly extracted documentation archive:

```sh
sha256sum --check artifacts/SHA256SUMS
nix run --no-write-lock-file ./artifacts/review#check
```

The first command verifies every shipped review input. The second uses the archive's own flake and lock to compile the shipped Lean model, regenerate and compare both corpora, check compiled axioms, rebuild the standalone page in check mode, replay the generic and naming rows, and execute the negative controls. Nix may acquire the exact locked toolchain when it is not cached; no model, scenario, simulator, or checker input comes from a checkout or an unpinned fetch.

`node simulator/build.mjs` deterministically rebuilds the standalone HTML. The page embeds its engines, actions, stories, corpora, and theorem inventories; it has no framework, CDN, or runtime asset dependency. Publishing stages `index.html` and `identity.json` under `site/simulator/`.

Build the versioned review bundle with `nix build .#docs-release` and check its packaging with `nix run .#release-check`. Then extract the actual archive into a fresh directory and run the archive commands above: a checkout-relative pass does not establish archive reproduction. The archive includes the rendered site and a complete runnable review tree under `artifacts/review/`; `artifacts/SHA256SUMS` binds every review input plus the separately served corpus and identity files. The outer `SHA256SUMS` authenticates the archive itself. A locally built bundle is reproducible review material; it is not a published release, validator, or ledger artifact.

Local browser verification exercises competing generic Inserts, separate generic withdrawal authorization, address evolution and refusal, pending and retired resolution, forged-view refusal, the naming claim/fold/resolve journey and its duplicate/Delete refusals, story branches, both themes, and a 390-pixel viewport. This local browser evidence is separate from deployed-byte/browser checks. The pinned Nix runner supplies Chromium; exact commands and retained historical evidence are described in the repository. A browser pass does not establish ledger execution.
