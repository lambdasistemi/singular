# Spec: live README and documentation links

## P1

As a reader, I open "Try the simulation" from the GitHub README and
"Open the playable Singular simulator" from documentation pages and
land on the playable HTML at
https://lambdasistemi.github.io/singular/simulator/
rather than a repository directory or a 404.

## Observed (2026-09-09, main 9e8d6b57)

- Live playable page HTTP 200, title "Singular · A name and its custody",
  Delete present (generic registry simulator, not an M1 naming profile).
- GitHub README rewrites `<a href="simulator/">` to
  `/lambdasistemi/singular/blob/main/simulator`, which serves the source
  tree.
- GitHub blob of `docs/simulation.md` rewrites
  `<a href="../../simulator/">` to `/lambdasistemi/singular/blob/simulator`
  (404). The same class appears for `../../model/...` raw HTML hrefs.
- Deployed docs with a trailing slash resolve `../../simulator/` to the
  playable page. GitHub-rendered Markdown and no-trailing-slash bases do
  not. `tools/check_site.py` filesystem-resolves relatives and skips
  scheme, netloc, and root-absolute hrefs, so the GitHub 404 is invisible.
- README still says "admitted-model limits" against proved-model docs.

## Requirements

- R-CTA-README: GitHub-rendered README CTA destination is the canonical
  playable HTML, verified by resolving the href the way GitHub rewrites
  relative links and checking response/content identity.
- R-CTA-DOCS: Simulation and design page CTAs open that same playable
  HTML from GitHub blob rendering and from built/deployed docs (project
  prefix `/singular/`, trailing-slash and no-trailing-slash directory
  URLs).
- R-CANONICAL: Dual-context CTA and published-model HTML hrefs use the
  absolute canonical GitHub Pages URL so GitHub does not rewrite them
  into blob/tree paths.
- R-WORDING: Nearby wording names the live generic registry simulator
  (Delete allowed) and proved-model limits. No naming-engine behavior.
- R-INVENTORY: Every reader-facing link under MkDocs/site coverage plus
  README is inventoried (Markdown and raw HTML href/src, nav, assets,
  anchors). Internal destinations and fragments are checked against
  built HTML with prefix-aware browser resolution. External URLs are
  requested with bounded timeout/concurrency. Redirects and final
  status are captured. Confirmed 404/broken anchor is distinct from
  network denial or 403/429.
- R-FIX: Broken in-scope links found by the inventory are corrected.
  Intended source-code destinations stay source-code destinations.
  Third-party moved docs get the authoritative replacement, not a guess.
- R-SPEECH: Bound speech companions are restamped when page prose or
  links change.
- R-CHECK: The docs site check no longer treats a filesystem-relative
  hit as proof of browser navigation under the project prefix or in
  GitHub README/blob context.

## Non-goals

Lean models, simulator engine/formal/corpus/identity, protocol rules,
naming-engine work, release version metadata/tags, indexer or source
copy. Not a child of 15 or 20.

## Invariants

- INV-26-README-PLAYABLE (BLOCKING): GitHub-resolved README CTA response
  is the playable HTML (title and Delete), not a GitHub tree/blob page.
- INV-26-DOCS-PLAYABLE (BLOCKING): Simulation and design CTAs, resolved
  from GitHub blob context and from `site_url` directory URLs, are that
  same playable HTML.
- INV-26-PREFIX (BLOCKING): A built-page relative href that 404s from
  the no-trailing-slash page URL or that GitHub rewrites to a missing
  blob path is a failure even if the file exists under `site/`.
- INV-26-INVENTORY (BLOCKING): Inventory denominator is discovered from
  README plus built HTML, not a hand list. Empty inventory is failure.
- INV-26-EXTERNAL (ADVISORY): Named external blockers include source,
  URL, and status; they do not count as a pass.
