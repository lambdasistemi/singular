# Simulation candidate

<a href="../../simulator/">Open the playable Singular simulator</a>.

Register a name, explore competing requests, cancel an Insert, change its address, retire it, or delete and reinsert it in a batch. Choose a story, advance with **›**, or press **▶** to play to its outcome. Click any tree node to revisit its state. A new manual attempt creates another branch without removing the previous play.

## Try the manual controls

1. In **Free play**, leave name key **42** and address datum **100**, then press **Queue Insert**. Change the datum to **200** and queue a second Insert for the same key.
2. Select the first request in the batch composer and press **Fold selected batch**. Name 42 now resolves to address 100. The competing request remains pending.
3. Select that pending Insert under cancellation. Press **Withdraw Insert** before approval to see its refusal. Then press **Approve exact withdrawal** and **Withdraw Insert**, using the same request and refund fields.
4. Select the application UTxO. Turn application evidence off and try **Change address** to see the refusal. Restore the evidence and change the datum to 200.
5. Press **Queue retirement (Update)** or **Queue Delete**. Resolve the name while its NFT is in request custody: the result is **pending**. Select the terminal request and fold it. Update ends at **retired**; Delete ends at **absent**.

The **Delete and reinsert in a batch** story supplies an Insert approved for the next incarnation. Its ordered batch applies Delete first, then Insert. Inspect **Successive batch effects** for each accumulator state. The logical burn and mint cancel for the default reusable NFT identity. A failure rolls back the whole selected batch; tentative intermediate effects are labelled accordingly.

The **Advanced free play** drawer exposes exact action JSON for every modeled action constructor. Examples come from the frozen corpus; they can intentionally fail when the current state differs. Edit witnesses, evidence, scope, asset identities, and net quantities there. Numeric inputs outside the exact JavaScript integer domain are refused. The resolver can also be queried with an unauthenticated view.

## What the evidence establishes

This is a **SIMULATOR-CANDIDATE**. All **41** Lean theorem declarations are **STATED**, with admitted `sorryAx` proof debt. No theorem proof or acceptance is claimed.

The focused gate replays **58 frozen Lean rows**: 52 transitions and 6 resolutions. The eight story trees contain **32 action steps**, including refusal forks. Story and manual steps outside the exact corpus input set exercise the transcription only; they do not acquire Lean parity by resemblance to a corpus row.

The theorem ledger has **12 controlled finite checks**, **17 action exhibits only**, and **12 explicit gaps**. Each controlled check has a fabricated intended-result failure. An action exhibit does not check its full quantified theorem. The page displays these distinctions; it does not turn unexhibited rows into passing lamps.

The Node gate also exercises **1,764 numeric-boundary probes** and **22 negative controls**. The source-derived refusal inventory currently exhibits **17 of 28 distinct model reasons**. Missing reason exhibits and theorem gaps remain in the [clarity record](LEAN-CLARITY.md), with exact names in the repository’s [coverage ledger](https://github.com/lambdasistemi/singular/blob/feat/model-simulation-s1/simulator/coverage.json).

## Model and assumptions

<a href="../../model/Singular/Model.lean">Frozen executable model</a> · <a href="../../model/Singular/Statements.lean">Theorem statements</a> · <a href="../../model/corpus.json">Lean-generated corpus</a>.

The model uses tagged terms for collision-free commitments and lists for authenticated logical maps and UTxO sets. Application acceptance and witness flags are supplied evidence. This page does not execute validators, verify signatures, or model wallet balances. Refund values are commitments; no refund-payment result exists in the modeled transition output. Names and addresses are natural numbers; key 42 and addresses A=100/B=200 are illustrative choices.

Address evolution and retirement are different operations: `evolve` changes the application output without changing the registry; `update` completes retirement to `over`. The model’s `conforms` diagnostic does not enforce application semantics. Read the [clarity record](LEAN-CLARITY.md) before treating an observed outcome as a deployment guarantee.

## Reproduce the focused checks

From the repository root:

```sh
node simulator/build.mjs --check
node simulator/gate.mjs
node simulator/gate.mjs --selftest
```

`node simulator/build.mjs` deterministically rebuilds the standalone HTML. The page embeds its engine, actions, stories, corpus, and theorem inventory; it has no framework, CDN, or runtime asset dependency. Publishing stages `index.html` and `identity.json` under `site/simulator/`.

Local browser verification exercised competing Inserts, folding, separate withdrawal authorization, address evolution and refusal, pending and retired resolution, forged-view refusal, story branches, both themes, and a 390-pixel viewport using Chromium 144.0.7559.96. This local browser evidence is separate from deployed-byte/browser checks. Exact commands, receipts, screenshots, and tested hashes are retained under `simulator/evidence/` in Git. These checks consumed no Lean compile or full Nix gate.
