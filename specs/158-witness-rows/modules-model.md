# #158 — modules model

```
offchain/lib               builders for the registry-mode shapes (approval + destination request,
                           Read, custody output, custody spend, co-minted terminate approval)
offchain/journey/witness-rows/Main.hs   the twelve rows, narration, JSON, attribution checks
offchain/flake.nix         witness-rows wrapper (pattern: retirement-rows)
onchain-release/README.md  the advertised command
tools/check_release.py     required phrase; tools/release_surface_control.sh variant
conformance/               rows and receipts
docs/witness-rows.md       the runner's page; mkdocs.yml nav
```

| module | responsibility |
|---|---|
| builders | Construct each new transaction shape once; used by the journey and, later, by #139's CLI. Never decide what the cage accepts. |
| `witness-rows` | Execute the rows in order; read the chain back; attribute refusals against #157's table; emit narration and JSON; exit non-zero on the first row that does not hold. |
| flake wrapper | Make the executable runnable from the archive without a checkout. |
| release tooling | Prove the archive advertises and carries the runner. |
| conformance | Bind the rows to the base as receipts. |
| the page | Tell a reader what to run and what they will see. |

## Out of this ticket's surface

Validators (#157), the Lean (#156), the escrow (#152), the CLI (#139),
preprod (#153).
