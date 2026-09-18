# #158 — tasks

Checked by the ticket owner after the audited candidate is accepted.

- [ ] T158-01 — builders for the registry-mode shapes in `offchain/lib`, with
      encoding round-trips against the #157 blueprint.
- [ ] T158-02 — `witness-rows` setup: boot or reuse; `bob` registered; `alice`
      retired and completed.
- [ ] T158-03 — rows WR01–WR04 (register, complete, two reads) with chain
      read-back.
- [ ] T158-04 — refusal rows WR05–WR07 with attribution against #157's table.
- [ ] T158-05 — absent rows WR08–WR11 with custody decode and refund lookups.
- [ ] T158-06 — WR12 free burn; WRX skip/attribution control.
- [ ] T158-07 — narration and JSON report; CBOR retained.
- [ ] T158-08 — flake wrapper `witness-rows`; archive README phrase;
      `check_release.py`; `release_surface_control.sh` variant; archive run
      without a checkout.
- [ ] T158-09 — conformance rows and receipts bound to the base.
- [ ] T158-10 — `docs/witness-rows.md` with sequence diagram, row table,
      speech; nav entry; `just check-presentation` green.

## Gate-held, not a task

`nix develop --quiet -c just ci` exit 0 and green GitHub CI on the pushed head.
The PR targets #157's branch until #157 merges, then `main`.
