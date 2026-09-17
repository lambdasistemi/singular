# simulator — the model, playable

One self-contained page, built from these sources. No framework, no network, no
server: `index.html` carries its engines, its stories and its corpora inside it.

| file | what it is |
| --- | --- |
| `core.mjs` | the registry model, transcribed from `Singular.Model` |
| `actions.mjs` | the request shapes a reader drives it with |
| `properties.mjs` | the laws, checked over the corpus |
| `naming.mjs` | the naming instance: the Over witness journey, and the corpus replay |
| `lifecycle.mjs` | the lifecycle replay — seeding, maintenance, recovery, retirement, wire |
| `page.mjs`, `page-body.html`, `page.css`, `template-generic.js` | the page |
| `stories.json` | five journeys, twenty steps |
| `corpus.json` | a copy of the generated `lean/corpus.json`, embedded in the page |
| `formal/` | every Lean source and manifest, mirrored so the page ships what it was built from |
| `identity.json` | the sha256 of everything above that is bound |

## The commands

```sh
node simulator/mirror-check.mjs     # the shipped Lean equals the built Lean, both ways
node simulator/build.mjs --check    # index.html is exactly what these sources build
node simulator/gate.mjs             # replay every exported row
node simulator/gate.mjs --selftest  # and prove the gate rejects a seeded defect
node simulator/identity.mjs         # regenerate identity.json after the Lean moves
node simulator/serve.mjs            # preview the built page locally
```

`just simulator` runs the first four. `just browser` drives the built page in a
pinned Chromium; it serves `index.html` and returns 404 for everything else, so
a page that grew a subresource fails rather than quietly fetching it.

## What the numbers are

`gate.mjs` prints what it covered rather than a bare PASS: 38 corpus cases, 7
codec rows, 2 deposit rows, 28 complement pairs of which 21 refuse, 20 story
steps, 7 controlled laws, 24 naming rows, 21 lifecycle rows, 4 boundary refusals.
A denominator that shrinks is a failure, not a smaller pass.

## What is not here

This directory does not re-implement the naming layer or its lifecycle. It
replays the rows the Lean exported for them. The previous simulator did
re-implement them, in about nine hundred lines, and when the Lean moved to
registry mode every one of those lines went on describing a model that no longer
existed while still reporting green. `mirror-check.mjs` exists so that drift is
a failing check rather than a discovery.

Evidence from the current tree is in `evidence/`. It is regenerated, not
accumulated: a receipt for a page that no longer exists is not evidence.
