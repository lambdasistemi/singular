# Plan: live README and documentation links

Base: `origin/main` `9e8d6b57`. Isolated clone `/code/singular-issue-26`,
branch `docs/live-links`. One OWNER slice. draft=NONE.

## Strategy

Absolute canonical URLs for hrefs that are rendered both on GitHub and
on GitHub Pages (`site_url`
https://lambdasistemi.github.io/singular/).
`tools/prepare_docs.py` copies README to `index.md` and ships
`simulator/` and `model/` next to docs; do not change that staging.
Extend `tools/check_site.py` so browser-style resolution with the
project prefix and GitHub README/blob rewrite is part of `docs-check`.
Keep the existing local-relative and speech coverage checks.

Exclusive first-touch files (parent NOTE-001): `README.md`,
`README.speech.json`, `docs/simulation.md`,
`docs/simulation.speech.json`. `docs/design.md` and other
prefix-escaping raw HTML hrefs are in inventory scope; further
overlaps go through parent before simultaneous edits.

## Slice

One slice: CTA destinations, wording, inventory, checker, speech.

## Verification

Focused gate (runtime `./gate.sh`): GitHub-rewrite CTA identity,
built-site prefix resolution, inventory non-empty, `just build-docs`,
`python3 tools/check_site.py site`, `just check-presentation`.
Do not run Lean/simulator/browser locally. CI on the candidate still
includes those jobs.

Live PR preview (`.#preview-check`) after the draft PR exists.
Live main README/docs after merge.

## Staffing

Commit owner: glm, `glm --approve`,
`family=glm harness=pi provider=zai model=glm-5.3-flash effort=max`.
Auditor: one Sol seat, then at most one delta. draft=NONE.
