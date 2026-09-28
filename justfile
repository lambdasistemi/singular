# Run recipes within nix develop.
# The generated API references (Haddock for the off-chain and Conformance
# libraries, `aiken docs` for the validators) are staged from the packaged
# site build, so the local site serves the same generated pages CI checks.
build-docs:
    python3 tools/prepare_docs.py --api-site "$(nix build --quiet --no-link --print-out-paths .#docs)"
    mkdocs build --strict

serve-docs:
    python3 tools/prepare_docs.py --api-site "$(nix build --quiet --no-link --print-out-paths .#docs)"
    mkdocs serve

# Stories, diagrams, no index labels, and speech bound to each page's hash.
check-presentation:
    python3 tools/check_presentation_repo.py

# After editing PAGE.md and redoing PAGE.speech.json: just stamp-speech PAGE.md
stamp-speech +pages:
    python3 tools/stamp_speech.py {{pages}}

model:
    lake build
    python3 tools/check_model.py

# #310: the open-datum application, an isolated Lake project over the unchanged
# root model. The selected compiler must be the root pin. `check` regenerates the
# corpus and ledgers from the model surface against the committed ones, replays
# every committed scenario from its own JSON, and runs its own controls: a
# controlled alteration each comparison must notice and definition mutants each
# of which must move at least one scenario.
application-model:
    lean --version | grep -q "version $(sed 's/.*:v//' lean-toolchain),"
    lake -d applications/open-datum --keep-toolchain build
    lake -d applications/open-datum --keep-toolchain exe open-datum-application check applications/open-datum

simulator:
    node simulator/mirror-check.mjs
    node simulator/build.mjs --check
    node simulator/gate.mjs
    node simulator/gate.mjs --selftest

browser:
    node tools/browser-check.mjs

ci:
    just model
    just application-model
    just simulator
    just browser
    just build-docs
    nix run --quiet .#docs-check
    just check-presentation
    just rename-registry-test
    bash tools/no-global-fixture-state.sh
    just inventory
    just inventory-controls
    just format-check
    just format-controls

# #108: the rename tool must re-run cleanly on a pre-rename tree, be a no-op
# on the second run, and its gate must catch strays planted in .sh files.
rename-registry-test:
    bash tools/rename-registry.test.sh

# #278: machine-checked inventory mapping every file the tree holds to its
# lint and format policy — or to a named non-code class — discovered from
# the tree itself (extensions, shebangs, executable mode, component
# manifests). Fails closed on anything unmapped. Mapping is not enforcement:
# the report names which policies CI executes today and which are pending
# debt owned by the remaining slices of the lint-and-format work.
inventory:
    python3 tools/code_inventory.py

# Negative and positive controls for the inventory (#278): each injects one
# synthetic orphan into a scratch export of the classified tree — a copy
# with no .git, so every run also proves the walk needs none — and requires
# the intended diagnostic. The working tree is never touched; no deliberate
# source defect is ever committed.
inventory-controls:
    bash tools/code_inventory_controls.sh

# #278 S2: apply the house Fourmolu configuration (fourmolu.yaml at the
# repository root) to every discovered Haskell source — offchain and
# conformance, the formerly fenced verifier sources and the evaluation
# spike included, no directory exclusions. Run within nix develop.
format:
    bash tools/format_haskell.sh inplace

# The matching check over the same discovered extent with the same one
# configuration; this is the carrier `just ci` and PR CI run.
format-check:
    bash tools/format_haskell.sh check

# Negative and positive controls for the Haskell format check (#278 S2):
# a source Fourmolu defaults accept but the house configuration rejects
# must fail the check (proving the configuration is read) and its formatter
# correction must pass it again; a tree without the configuration must
# fail loudly rather than format with defaults; a newly tracked component
# tree joins the check through the Git index while ignored untracked build
# noise never enters it. Scratch copies only; the working tree is never
# touched.
format-controls:
    bash tools/format_controls.sh
