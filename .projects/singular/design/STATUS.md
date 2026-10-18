# Backend compatibility planning journal

## 2026-10-12 — planning publication

ACK: operator mandate and scheduling corrections read in full; AGENTS.md, constitution 1.15.0 and current PR template read. Survey rebound from older local checkout to main 1d9f8b0da3aee5a4743b718b22abea99ef1501ff; Lean 20b35407c8a8e955dea396e59ae926b7c9e13d03 / tree d9161edd0274b67151f331949521f34bbf18612f.

Created milestone 7, epic #584, children #579, #580, #581, #582, #583; designed wallet/witness/runtime/storage/package boundaries and preserved existing provider/vault/effect owners. Product runtime unchanged; acceptance not claimed. Planning outputs are independent of other worktrees. Session verified from this conversation's pane: singular-browser-compat / wallet-interfaces / %245. Restored mistakenly moved factory-dashboard pane %20 before continuing.

## 2026-10-12 — open-datum placement clarified

Read the current application Cabal boundary: its library still depends on registry-cli. Explicitly split portable application logic from CLI/browser adapters in the diagram and design; strengthened #580/#581/#582 criteria and bound the application Lean revision alongside the registry model. No runtime changes or integration acceptance claimed.
