# M1 contract registry — 2026-09-22

| Boundary | Required correspondence | Evidence and enforcing status |
|---|---|---|
| Lean registry model to Aiken and consumers | State alphabet, wire encoding, token/refund effects, request home, read/approval policing agree | PARTIAL; E154 current slices and bound receipts. T178 identity refresh CG03 exit0 reaches edge4, review003 and remaining S1 checks pending. No full-census acceptance. |
| Shared driver to every executing harness | Preserve exact observations and actual execution | PR193 merged265c595; broader off-chain effects remain T198 draft PR219. Exact missing behavior requires its own evidence, not merge status. |
| Model to simulator and tests | Missing execution/wrong token effects must fail | E199: PR201/PR206 merged; T198 open and205 undispatched. Full coverage enforcement not established. |
| Public conformance statement to behavior | Story/model/implementation choices/evidence and stale detection agree | Constitution1.1.0 landed; T209 PR217 open unaccepted, generic-driver/whole-boundary work parked. New translation principle governance disposition pending. |
| Ordered-name escrow to registry witnesses | Only first nonterminal name pays current address, including after recovery | NONE for expanded preprod outcome;141/152/153 and prerequisites open. |
| Released artifact to preprod deployment | Identities and archive-only journeys bind current deployment | Historical v0.6.1 acceptance retained; no new expanded replay or deployment acceptance in this sweep. |
| Compiled-code proof coverage | Exact compiled behavior meets claimed obligations | NONE at full M1 scope; do not substitute green CI or source presence. |
