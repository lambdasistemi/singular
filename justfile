# Run recipes within nix develop.
build-docs:
    python3 tools/prepare_docs.py
    mkdocs build --strict

serve-docs:
    python3 tools/prepare_docs.py
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

simulator:
    node simulator/mirror-check.mjs
    node simulator/build.mjs --check
    node simulator/gate.mjs
    node simulator/gate.mjs --selftest

browser:
    node tools/browser-check.mjs

ci:
    just model
    just simulator
    just browser
    just build-docs
    nix run --quiet .#docs-check
    just check-presentation
    just rename-registry-test
    bash tools/no-global-fixture-state.sh
    just inventory
    just inventory-controls

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
