# First demo: play the registry model

This is the model rehearsal for the [8 October Singular registry handoff story](https://github.com/orgs/lambdasistemi/projects/4/views/5?pane=issue&itemId=252955454). The source is the accepted [Singular Lean model](../lean/Singular/Model.lean), played through the existing [registry simulator](simulation.md). The recorded outcomes are simulator results. The [registry-mode epic #154](https://github.com/lambdasistemi/singular/issues/154) still needs its separate released-archive devnet evidence.

## Story and assets

As a Cardano KERI integrator, I want to see whether one Singular registry key can move through absence, booking and permanent retirement, with its custody refund, token changes and refusals visible, so that I can prepare a consumer mapping without treating a name or a toy token as an accepted interface.

The fictional label **ORCHID-42** denotes model key `42`. Funder `91` places `200` model units in absent custody; holder `42` books output `555`; terminal witnesses use outputs `700` and `701`. These are input values for the model. They are not Cardano addresses, policy IDs, real assets or ledger payments. The cast prints the SHA-256 of the Lean source it read at run time.

## Run of show

| Time | Presenter action | Observation to ask for |
| --- | --- | --- |
| 0–2 min | State the user story and the model-only boundary. Show the fictional inputs. | The starting key is unknown; no custody or token is held. |
| 2–4 min | Play frames 1–2: `insertAbsent`, then the wrong approval tuple. | The absent token and deposit enter custody; the mismatched approval refuses without changing them. |
| 4–6 min | Play frame 3: `updateActive`. | The absent token is consumed, the active token is held at output `555`, and the recorded funder receives the `200` model units. |
| 6–8 min | Play frames 4–6: retire, then attest twice. | The active token burns; both terminal witnesses coexist while the leaf and root remain terminal. |
| 8–10 min | Play frames 7–8: try to book the terminal key and omit a mint delta. | `terminal-immutable` and `net-mint-mismatch` refuse; two witnesses remain. |
| 10–15 min | Read the evidence boundary and the next handoff gate. | Model replay is visible; connected archive, scripts, transaction IDs and node readbacks remain to be shown. |

The full cast is about half a minute; pause at each frame for the discussion above. Its colored `ACCEPTED` and `EXPECTED REFUSAL` lines are computed by `foldBatch` and checked by the script against the model simulator's observations. The script stops if an expected result changes.

## Replay the cast

<div id="first-registry-cast" aria-label="Singular registry model rehearsal"></div>
<script>
window.addEventListener("load", function () {
  AsciinemaPlayer.create("../assets/video/first-registry-model-demo.cast",
    document.getElementById("first-registry-cast"), {
      cols: 80, rows: 24, autoPlay: false, preload: true, controls: true
    });
});
</script>

[Download the asciicast](assets/video/first-registry-model-demo.cast) or play it from this checkout:

```sh
nix shell github:NixOS/nixpkgs/117cc7f94e8072499b0a7aa4c52084fa4e11cc9b#asciinema \
  -c asciinema play docs/assets/video/first-registry-model-demo.cast
```

To run the model sequence without pauses, use `node demo/first-registry-demo.mjs --fast`. To record it again after a model or scenario change, use `demo/record-first-registry-demo.sh`; that command first runs the scenario, records an 80×24 cast with pinned asciinema, and validates the recorded content. The existing `just simulator` gate separately replays the exported model corpus.

## What remains for 8 October

The project story requires the downloaded release archive and a fresh devnet run: connected registration, retirement, two terminal witness reads and absent custody consumption, plus a refused edge or token delta. The evidence pack must bind the accepted Lean revision, archive and installed command identities, script and policy IDs, transaction IDs, node readbacks, refusal traces and uncovered conformance rows. This model cast supplies none of those ledger receipts; it prepares the play and gives the audience an explicit expected sequence.
