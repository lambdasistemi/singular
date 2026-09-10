# Spec: docs link re-cut — checker ref-binding and served-route evidence (issue 29)

Predecessor #26 retained as delivery tracker, NOT delivered here. Rejected baseline `f03eac8ef27a5fe812f708f52d4f6795a3eb8fbe` UNACCEPTED inherited context (report `0aa2b702`, blocking MODEL-IDENTITY + PREFIX). Accepted integration base `9e8d6b57a6e538719b8f782b521bd456301df71e` refreshed. Branch `docs/live-links`, worktree `/code/singular-issue-26-docs`, PR28 draft.

## Carried GREEN (must keep passing)

- README-PLAYABLE, DOCS-PLAYABLE: CTA canonical URLs, relative CTA rejected.
- INVENTORY: 1093-row discovered denominator, empty-denominator fails, no shrink.
- Model byte-identity 6/0, speech stamps, presentation gate, scope fence (docs + 2 tools only).

## Open rows (this slice)

- INV-29-MODEL-IDENTITY (BLOCKING, ex INV-26-MODEL-IDENTITY): every published-candidate model/statement/lemma/corpus evidence destination bound to inspected candidate ref or on-host staged bytes; moving `blob/main`/production alias fails identity check for that reason. Current checker at `tools/check_site.py:26,142-144,201-210` hardcodes `blob/main` and treats existing main path as identity — CONTROL-SURVIVED at 1093/1093.
- INV-29-PREFIX (BLOCKING, ex INV-26-PREFIX): served-redirect evidence for entire discovered internal denominator, redirect-aware from ACTUAL final document URL after redirects, across canonical production, exact candidate PR preview and supported archive-serving command. Raw no-slash math neither PASS nor failure. No blanket advisory, no 4-route extrapolation, no shrink. Isolated prefix negative must reach intended resolver with all fixtures.
- INV-29-EXTERNAL (ADVISORY, ex INV-26-EXTERNAL): zero external rows honestly reported; real external URLs requested with bounded timeout/concurrency when discovered; status-branch control meaningful, not manufactured.
- INV-29-README-PLAYABLE, INV-29-DOCS-PLAYABLE, INV-29-INVENTORY (BLOCKING, carried KILLED): must remain KILLED with fresh evidence.

## Requirements

- R-REFBIND: checker resolves GitHub source context by candidate ref (not hardcoded `blob/main` or stale SHA); relative GitHub links follow viewed source ref; main-branch navigation unbroken; ordinary user links not pinned stale; future runs need no hardcoded branch/SHA. Moving alias on candidate evidence => nonzero for identity reason. No circular existence==identity.
- R-SERVED: redirect-aware correctness per link from final document URL; production + preview + archive observed; genuine 404/broken anchor blocks.
- R-INVENTORY: full README+reader-facing docs (Markdown, raw href/src, nav, assets, anchors); external rows=0 demonstrated, not asserted.
- R-SPEECH/FENCE: speech restamped on prose change; own docs/README/speech + minimal `tools/check_site.py`/`tools/prepare_docs.py` + fixtures only.

## Non-goals

Lean/simulator engines, naming, release/tags, indexer, imports, economics. No `/code/singular` edits. Reserved lane files: README.md, README.speech.json, docs/simulation.md, docs/simulation.speech.json.
