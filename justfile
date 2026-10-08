# Run recipes within nix develop.
# The generated API references (Haddock for the off-chain and Conformance
# libraries, `aiken docs` for the validators) are staged from the packaged
# site build, so the local site serves the same generated pages CI checks.

# Build the documentation site with the staged generated references.
build-docs:
    python3 tools/prepare_docs.py --api-site "$(nix build --quiet --no-link --print-out-paths .#docs)"
    mkdocs build --strict || { chmod -R u+w site; exit 1; }
    chmod -R u+w site

serve-docs:
    python3 tools/prepare_docs.py --api-site "$(nix build --quiet --no-link --print-out-paths .#docs)"
    mkdocs serve

# Stories, diagrams, no index labels, and speech bound to each page's hash.
check-presentation:
    python3 tools/check_presentation_repo.py

# Rewrite the speech companions from the pages, exactly as the pages read.

# The extraction tool renders each page with this site's own Markdown settings.
extract-speech:
    mkdocs-speech --config mkdocs.yml docs
    mkdocs-speech --config mkdocs.yml specs
    dir="$(mktemp -d)" && cp README.md "$dir" && mkdocs-speech --config mkdocs.yml "$dir" && cp "$dir/README.speech.json" README.speech.json

# Generate the narration clips the companions still lack (needs DEEPINFRA_API_KEY).

# A segment that changed gets a new clip; the rest are kept.
narrate:
    python3 tools/narrate.py --generate

# After editing PAGE.md and redoing PAGE.speech.json: just stamp-speech PAGE.md
stamp-speech +pages:
    python3 tools/stamp_speech.py {{ pages }}

model:
    lake build
    python3 tools/check_model.py
    python3 tools/check_m1.py
    python3 tools/check_m1_transport.py

# #310: the open-datum application, an isolated Lake project over the unchanged
# root model. The selected compiler must be the root pin. `check` regenerates the
# corpus and ledgers from the model surface against the committed ones, replays
# every committed scenario from its own JSON, and runs its own controls: a
# controlled alteration each comparison must notice and definition mutants each
# of which must move at least one scenario. The ledger's proof status is compiled
# into the executable from the statements the build elaborated; the saved axiom
# report is then cross-checked against the ledger and the statement source by an
# independent bridge.

# Build, check and cross-check the open-datum application model.
application-model:
    lean --version | grep -q "version $(sed 's/.*:v//' lean-toolchain),"
    lake -d applications/open-datum --keep-toolchain build
    lake -d applications/open-datum --keep-toolchain exe open-datum-application check applications/open-datum
    lake -d applications/open-datum --keep-toolchain env lean applications/open-datum/lean/AuditReport.lean > applications/open-datum/.lake/axioms-report.txt
    python3 tools/check_application_model.py --axioms-report applications/open-datum/.lake/axioms-report.txt

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
    just node-confinement
    just node-confinement-controls
    just inventory
    just inventory-controls
    just format-check
    just format-controls
    just lint
    just lint-controls

# Local bundle for the dev-shell-only checks. Hosted: the Development shell checks job runs application-model, check-presentation, rename-registry-test, no-global-fixture-state, node-confinement, node-confinement-controls and lint-controls; whole-repository `just lint` runs in the Development shell build job; inventory, inventory-controls, format-check and format-controls keep their existing hosted carriers.
ci-shell:
    just application-model
    just check-presentation
    just rename-registry-test
    bash tools/no-global-fixture-state.sh
    just node-confinement
    just node-confinement-controls
    just inventory
    just inventory-controls
    just format-check
    just format-controls
    just lint-controls

# #108: the rename tool must re-run cleanly on a pre-rename tree, be a no-op
# on the second run, and its gate must catch strays planted in .sh files.

# Run the rename tool's re-run, no-op and gate tests.
rename-registry-test:
    bash tools/rename-registry.test.sh

# #278: machine-checked inventory mapping every file the tree holds to its
# lint and format policy — or to a named non-code class — discovered from
# the tree itself (extensions, shebangs, executable mode, component
# manifests). Fails closed on anything unmapped. Mapping is not enforcement:
# the report names the CI carrier that executes each policy.

# Map every file to its lint and format policy.
inventory:
    python3 tools/code_inventory.py

# Negative and positive controls for the inventory (#278): each injects one
# synthetic orphan into a scratch export of the classified tree — a copy
# with no .git, so every run also proves the walk needs none — and requires
# the intended diagnostic. The working tree is never touched; no deliberate
# source defect is ever committed.

# Run the inventory's negative and positive controls.
inventory-controls:
    bash tools/code_inventory_controls.sh
    python3 tools/test_tags_controls.py

# #278 terminal-attestation-permanent: apply the house Fourmolu configuration (fourmolu.yaml at the
# repository root) to every discovered Haskell source — offchain and
# conformance, the formerly fenced verifier sources and the evaluation
# spike included, no directory exclusions. Run within nix develop.

# Apply the house Fourmolu configuration to every Haskell source.
format:
    bash tools/format_haskell.sh inplace

# The matching check over the same discovered extent with the same one
# configuration; this is the carrier `just ci` and PR CI run.

# Check every Haskell source against the house Fourmolu configuration.
format-check:
    bash tools/format_haskell.sh check

# Negative and positive controls for the Haskell format check (#278 terminal-attestation-permanent):
# a source Fourmolu defaults accept but the house configuration rejects
# must fail the check (proving the configuration is read) and its formatter
# correction must pass it again; a tree without the configuration must
# fail loudly rather than format with defaults; a newly tracked component
# tree joins the check through the Git index while ignored untracked build
# noise never enters it. Scratch copies only; the working tree is never
# touched.

# Run the Haskell format check's negative and positive controls.
format-controls:
    bash tools/format_controls.sh

# #278: lint and format checks over every other code family the inventory
# discovers — Nix, Python, shell, JavaScript/CSS, justfiles, workflow YAML,
# Lean and HTML — with the pinned tools of the development shell. The
# extent is the inventory's own, so a new file or directory is checked with
# nothing to edit, and a code family with no checker fails the run. Pass
# family names to narrow the run. Run within nix develop.

# Lint and format-check every other code family.
lint *families:
    python3 tools/lint_code.py check {{ families }}

# Apply the formatters (and safe lint fixes) of `just lint` in place.
lint-fix *families:
    python3 tools/lint_code.py fix {{ families }}

# Negative controls for `just lint`: one planted defect per checker family,
# including a new source under a new directory, in scratch copies of the
# classified tree. The working tree is never touched.

# Run the lint and format checks' negative controls.
lint-controls:
    bash tools/lint_controls.sh

# #323: the node backend is named only by the composition and fixture
# modules tools/node-confinement.allow lists, each with its reason, over
# every Haskell source under the roots the check names (`--roots`): the
# commands, the library, the runners, the end-to-end suite and the
# conformance harness.

# Check that only allowlisted modules name the node backend.
node-confinement:
    bash tools/node_confinement_check.sh

# Its controls, on scratch copies: a planted backend import and a raw
# submit in a new module under each scanned root, reasonless, stale and
# unneeded allowlist entries, and each root emptied fail with their
# diagnostic.
# The working tree is never touched.

# Run the node confinement check's negative and positive controls.
node-confinement-controls:
    bash tools/node_confinement_controls.sh
