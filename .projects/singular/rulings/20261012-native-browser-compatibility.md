# 12 October 2026: backend compatibility before additional edges

## Authority

Direct operator commission: “define the interfaces so that we can swap the providers”; “the wallet has to be CIP30”; “the provider in the sense of ledger provider, is fine”; create a separate milestone, design the code restructuring and separate the Wasm-compilable packages before the current M2 new edges. Existing ledger/Wasm work in cardano-tx-tools, Cardano Swiss Knife, MPFS, cardano-ledger-wasm and haskell-mts must be reused.

Scheduling clarification: “browser compatibility can fall in parallel with the script sharing”; “as soon as I can go working on Cardano Carry this should be a priority”; “I can go work on Cardano Carry before script sharing”. Cardano Carry refers to Cardano KERI in this discussion.

## Recorded outcome

- [Milestone 7: Native/browser compatibility](https://github.com/lambdasistemi/singular/milestone/7), [epic #584](https://github.com/lambdasistemi/singular/issues/584), children #579, #580, #581, #582, #583.
- Browser compatibility is the priority once the operator can switch to Cardano KERI. It can proceed alongside M1.5 script sharing and does not wait for it. The KERI handoff does not wait for script sharing.
- M2 remains the five missing edges, GitHub milestone 5. Its new-edge delivery waits for implemented and accepted compatibility, not merely this design document. Existing stable milestone IDs and scope are preserved.
- The design defines public wallet/view and witness contracts, checked assembly, portable package boundaries and replaceable storage/runtime/evidence services. LedgerProvider remains the existing abstraction.
- The milestone includes a minimal executable browser integration host to prove the adapters, not a full browser product or embedded seed vault. Native vault #490 and state/evidence ownership #545 retain their existing outcomes/owners.
- Planning publication is authorized now. Implementation workers, existing paused-lane releases, public-network transactions and runtime release publication are not commissioned by this filing.

## Binding and limits

Read and acknowledged AGENTS.md, current constitution 1.15.0 and the current PR template. Survey baseline: main 1d9f8b0da3aee5a4743b718b22abea99ef1501ff, Lean 20b35407c8a8e955dea396e59ae926b7c9e13d03, tree d9161edd0274b67151f331949521f34bbf18612f. Rebind before implementation. Source inspection and planning metadata are the evidence here; no runtime build, browser integration, model change or product acceptance is claimed.

[Detailed design](../design/native-browser-compatibility.md). Native sub-issue/dependency links and Project 4 Todo entries accompany the GitHub tickets. The current public projection is [the roadmap](https://github.com/lambdasistemi/singular/wiki/Project-roadmap).
