# #158 — plan and invariant mandate

One PR, `code-the-design`. The ledger is the boundary under test: every row is
a transaction the devnet either accepted or refused, read back from the chain,
attributed. Model-level and Aiken-level evidence exist already (#156, #157);
what this ticket establishes is the composition on a real node, and that a
person with the archive can reproduce it.

## Strategy

1. **Builders first** — transaction construction for the new shapes: a request
   carrying an approval and a destination; `Read`; the custody output and its
   spend; the co-minted terminate approval at `Retire`. They live in
   `offchain/lib` beside the existing builders and are used by the journey.
2. **The journey** — twelve rows in order, each a function returning its
   observation; narration and JSON from one source.
3. **The archive** — flake wrapper, README phrase, `check_release.py` and the
   surface control variant.
4. **Conformance and the page.**

The PR is stacked on #157's branch and targets it; re-targeted to `main` when
#157 merges.

## Staffing

Operator ruling: epic owner codex, ticket owner Opus, commit owner `glm` else
`muse`, auditor Opus. Haskell and devnet work: `muse --approve` preferred for
the commit owner (the GLM fence on network and devnet processes is the
question; if it allows, `glm`). Auditor fresh Opus loading `commit-auditor`
and `verification`. `draft=NONE`.

## Constraints

- No validator change. A refusal that does not match #157's trace-label table
  is a finding against #157, filed as a Q, never worked around in the runner.
- Every accepted row is verified from chain state, not from the builder's
  intent: the token is looked up at the address the request named; the custody
  datum is decoded from the UTxO; the refund is a UTxO at the refund address.
- Every refused row is verified from the node's phase-2 failure with the
  script hash and the trace, and the run fails if the refusal is attributed
  elsewhere.
- The evidence directory retains the transaction CBOR for every row.
- Devnet only; nothing is submitted to preprod (#153).

## Invariant rows

`Given / When / Then` is the obligation; **Observation** what is read back;
**Control** the seeded fault that must make the run fail for the named reason.

| id | binds | Given / When / Then | Observation | Control |
|---|---|---|---|---|
| WR01 | #157 N1, T1, C6 | Given the controller's `insertActive` approval and request with the record destination; when folded; then the record output at the application address holds `(active_policy, alice)` and the bound datum. | UTxO lookup at the record address; datum bytes equal the bound datum | A request naming a wallet destination is refused `destination` by the cage — recorded as a negative sub-row, not as WR01 |
| WR02 | #157 N6, N8 | Given the live record; when `Retire` by the controller and then the completion fold run; then the active token is burned and custody is empty. | Mint field of the completion tx: `(active_policy, alice) = −1`; custody address empty | A completion whose mint omits the burn is refused `delta-mismatch` |
| WR03 | #157 G4, T2; #156 I-S1 | Given the terminated leaf; when `Read(0x02)` is folded with Bob's destination; then one `(terminal_policy, alice)` is at Bob's output and the root is unchanged. | Bob's UTxO; state datum root equal before and after | A proof built against the previous root is refused |
| WR04 | #156 I-W3 | Given WR03; when a second read is folded with Carol's destination; then a second terminal token exists; both are on ledger. | Two UTxOs, same policy and name | — |
| WR05 | #157 M3; #156 I-S1 | Given the live `bob`; when `Read(0x01)` is folded; then the node refuses in phase 2 attributed to the cage with `read-non-terminal`. | Script hash equals the state script; trace matches | A run that records a fee failure here fails the run |
| WR06 | #157 M1; #156 I-W1 | Given the live `bob`; when a fold mints a second `(active_policy, bob)`; then refused by the cage, `delta-mismatch`. | Attribution and trace | — |
| WR07 | interface §2 | Given an unmentioned name; when `Read(0x02)` is folded with any proof; then refused — the proof cannot verify against the root. | Attribution to the cage | — |
| WR08 | #157 T3; #156 I-W2 | Given Carol's `insertAbsent` for `dave`; when folded; then a UTxO at the cage address holds `(absent_policy, dave)` with `AbsentCustody { dave, Carol }`. | Custody UTxO decoded | A folder placing the token at Carol's wallet is refused `absent-custody` |
| WR09 | #157 T4; R-ADA | Given WR08; when Dave's `updateActive` is folded; then custody is spent, Carol's address holds a new UTxO with at least the custody lovelace, and Dave's record holds the active token. | Three lookups | A fold paying the lovelace to Dave's record is refused `refund` |
| WR10 | #157 T4, N4 | Given Carol's absent witness for `erin`; when Carol mints `deleteAbsent` and it is folded; then custody is spent, Carol is refunded, and `Read(0x00) erin` — attempted as a probe — is refused because the leaf is unknown. | Lookups; the probe's refusal | — |
| WR11 | #157 N4; R-NM4 | Given Carol's witness; when Dave tries to mint `Approve { deleteAbsent, .. }`; then the naming policy refuses. | Attribution to the application policy | — |
| WR12 | #157 P2; #156 I-W3 | Given two terminal tokens; when one is burned in a transaction with no registry input; then accepted; the other remains. | Mint field; remaining UTxO | Burning an active token the same way is refused `no-fold` (sub-row) |
| WRX | W2 | Given the twelve rows; when any is skipped or its attribution differs; then the run exits non-zero. | Exit status; the JSON's `observed` field | The control run with WR05 skipped exits non-zero |

## Archive and page rows

| id | Given / When / Then | Observation | Control |
|---|---|---|---|
| R1 | Given the extracted release archive with no `.git`; when `nix run .#witness-rows` runs against a devnet; then exit 0 with twelve VERIFIED lines. | The archive run's log | An archive README without the phrase fails `check_release.py` |
| R2 | Given `release_surface_control.sh`; when the missing-command variant for `witness-rows` runs; then it fails as designed. | The control's log | — |
| P1 | Given `docs/witness-rows.md`; when `just check-presentation` runs; then the page has a story, a sequence diagram, a row table, fresh speech. | Exit 0 | An unstamped page fails |

## Gates

**Gate W — this ticket.** `cabal build` of the journey; the twelve rows on a
devnet with attribution checks; the JSON report present; the archive phrases;
`just check-presentation`; the diff inside `offchain/journey/witness-rows/`,
`offchain/lib` builders, `offchain/flake.nix`, `conformance/`, `tools/check_release.py`,
`tools/release_surface_control.sh`, `onchain-release/README.md`, `docs/witness-rows*`,
`mkdocs.yml`. Falsified per class before the commit owner starts.

**Ticket gate.** `nix develop --quiet -c just ci` exit 0; green GitHub CI on
the pushed head; the archive assembled and `check_release.py` green; fresh
Opus audit bound to candidate, base and the devnet evidence directory.

## Evidence required at acceptance

- the devnet run log and JSON with twelve rows, transaction ids, attributions;
- the retained CBOR per row;
- `check_release.py` and the surface control receipts;
- conformance receipts bound to the base;
- fresh independent audit report; green CI.
