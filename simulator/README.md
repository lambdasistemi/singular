# Singular simulator candidate

The self-contained browser artifact is `index.html`; it embeds the exact core, action builders, property code, eight story trees, corrected Lean corpus, theorem inventory, and formal identity. Publishing needs only `index.html` and `identity.json` at `site/simulator/`. Formal files are linked under the parent's canonical `site/model/` location.

Run from the repository root:

```sh
node simulator/build.mjs --check
node simulator/gate.mjs
node simulator/gate.mjs --selftest
```

To rebuild, run `node simulator/build.mjs`. To serve locally, run `node simulator/serve.mjs` and open `http://127.0.0.1:8769/simulator/?selftest=1`. The page's self-test is finite corpus/story replay, not a proof or a replacement for the browser gate.

`browser-check.js` is a Playwright MCP `browser_run_code_unsafe` function; pass the file as its `filename` (or its text as `code`). It exercises real manual controls and story branches. `evidence/browser-*-receipt.json` and the supplementary receipts retain the exact tool output and code. Screenshots and browser-observed HTML hashes are retained alongside them.

`formal/` contains frozen input copies for clean-clone gates. `identity.json` pins them. `coverage.json` gives one exact row per theorem declaration and source-derived refusal sites. The split is **12 controlled finite checks / 17 action exhibits only / 12 gaps** across 41 admitted declarations. **58 corpus rows**, **32 story steps**, **1,764 numeric-boundary probes**, and **22 negative controls** are checked. No universal parity or proof is claimed.

`page-template.html` is the shared skill snapshot obtained with `page-template.mjs start`. Its first style block and the helpers in `template-generic.js` are retained. The second stylesheet and machine-specific page/rendering adapters are explicit. The broader generic template renderer identity and full prose-atom/guard-conjunct reconciliation are not claimed; see `docs/LEAN-CLARITY.md`.

`make-stories.mjs` is an authoring generator. The gate replays the pinned `stories.json` expectations without regenerating them. Review any intentional scenario regeneration as changed expectations. These stories do not become Lean corpus rows through regeneration.

Author consumption: zero Lean compiles, zero full Nix gates. This is a **SIMULATOR-CANDIDATE**; publication and independent acceptance belong to the parent.
