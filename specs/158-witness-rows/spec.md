# #158 — `witness-rows`: terminal tokens on a devnet from the released archive

Authority: the settled interface (gist `4a2bd178`), the frozen #156 Lean and
the #157 cage as accepted. Constitution v1.0.0. Depends on #157 and follows it;
this is the epic's last child and its runnable artifact.

## The story

As **a reviewer with the released archive and no git checkout**, I run one
executable against a devnet and watch the registry do what the interface
promises, attributed on ledger: a name registered; retired and completed as
`updateTerminal`; a first and then a second terminal token minted for it by
`Read Terminal`, both accepted; `Read Active` on a live name refused by the
cage; a second active token refused as a delta mismatch; a read of a name
nobody ever mentioned refused; `insertAbsent` putting an absent token into the
cage's custody with the inserter's refund address beside it; `updateActive`
consuming it, the deposit back with the inserter, the active token at the
booker's record; and one terminal token burned freely, with no fold at all.

What I see when it works: one narration line per step with the policy id, the
asset name and the transaction id, a VERIFIED line per row read back from the
chain, and a JSON file I can hand to someone else. What I see when it fails:
the first row that did not hold, and a non-zero exit.

As **Bob**, I see the thing my escrow will consume exist on a ledger: two
terminal tokens for one retired name, and a representative that only Alice's
record holds.

## Requirements

### W1 — the journey executable

`witness-rows`, in `offchain/journey/witness-rows/`, patterned on
`offchain/journey/retirement` and `retire-verify`: it runs, or reuses from a
supplied evidence directory, a completed retirement on the devnet, then executes
the rows below in order, one narration line per step, and verifies what the
chain holds after each. Exposed as `nix run .#witness-rows`; wrapped like
`retirement-rows` in `offchain/flake.nix`.

### W2 — the rows

| id | row | expected |
|---|---|---|
| WR01 | register `alice`: `insertActive` with the controller's approval, record created by the fold | accept; active token `(active_policy, key)` at the record |
| WR02 | retire with the committed recovery key (reveal + signature) and complete: `Update(0x01,0x02)` folded from completion-only custody | accept; active token burned; leaf `0x02` (proved by WR03); a sub-row shows the current control key alone refused |
| WR03 | first `Read(0x02)` for `alice`, destination Bob's address | accept; terminal token at Bob's output |
| WR04 | second `Read(0x02)` for `alice`, destination Carol's address | accept; a second terminal token, same policy and name |
| WR05 | `Read(0x01)` on a live name (`bob`, registered in the setup) | **refuse** — cage, `read-non-terminal` |
| WR06 | fold of `insertActive` for `bob` again with a second active token in the mint | **refuse** — cage, `delta-mismatch` (and the MPF insert on a known key) |
| WR07 | `Read(0x02)` for a name never mentioned, with a proof against the current root | **refuse** — proof does not verify |
| WR08 | `insertAbsent` for `dave` by Carol with refund address Carol | accept; absent token in an output at the cage address with `AbsentCustody { dave, Carol }` |
| WR09 | `updateActive` for `dave` by its controller Dave | accept; custody spent; Carol's output receives the custody lovelace; active token at Dave's record |
| WR10 | `insertAbsent` for `erin` by Carol, then `deleteAbsent` by Carol | accept; custody spent; Carol refunded; `erin` unknown again |
| WR11 | `deleteAbsent` for a Carol-witnessed name attempted by Dave | **refuse** — naming policy, `Approve` arm (no approval can be minted) |
| WR12 | burn one of the two terminal tokens in a transaction with no fold | accept; the other still exists |

Each refusal is attributed: the row records which script refused (cage, witness
policy or naming policy) and the trace label, matched against #157's
trace-label table. A refusal that fails for another reason — fee, collateral,
a wrong input — fails the run; it is not a pass.

### W3 — human and structured output

Every narration line names the policy id, the asset name and the transaction id
it produced or inspected. A JSON report with one object per row (id, expected,
observed, transaction ids, attributing script, trace) is retained under the
evidence directory; a reader like `retire-verify` can verify WR01–WR04 from the
retained CBOR alone.

### W4 — conformance receipts

The rows land in `conformance/` with receipts bound to the current base (the
#157 blueprint hashes and the release version); `just ci` green.

### W5 — in the released archive, without a git checkout

`witness-rows` is included in the on-chain release archive the way
`retirement-rows` is (#91): `tools/check_release.py` requires the
`nix run .#witness-rows` phrase in the archive README; `release_surface_control.sh`
gains the corresponding missing-command variant. It runs from the extracted
archive against a devnet with no repository present.

### W6 — the runner's page

`docs/witness-rows.md`: who it is for, what to run, the twelve rows as a table
and the journey as a sequence diagram, what a refusal looks like, the finite
limits; `.speech.json` curated and stamped; nav entry under the naming pages.
The interface page itself is #159, not this ticket.

## Rejection behavior

Rows WR05, WR06, WR07 and WR11 must be refused **by the named script with the
named trace**; the runner compares the attribution against #157's table and
fails otherwise. A skipped row fails the run (control).

## Observable success

From the extracted release archive, on a devnet: `nix run .#witness-rows`
exits 0, prints twelve VERIFIED lines, and leaves the JSON report. From the
repository: `nix develop --quiet -c just ci` exits 0.

## Non-goals

Escrow consumption (#152). The `singular-naming witness-over` CLI form (#139).
Preprod (#153). Any change to validators — a validator defect found here is a
Q to the epic owner against #157, not a repair here.
