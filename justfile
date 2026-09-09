# Run recipes within nix develop.
build-docs:
    python3 tools/prepare_docs.py
    mkdocs build --strict

serve-docs:
    python3 tools/prepare_docs.py
    mkdocs serve

# Stories, diagrams, no index labels, and speech bound to each page's hash.
check-presentation:
    python3 tools/check_presentation.py --front README.md README.md docs specs

# After editing PAGE.md and redoing PAGE.speech.json: just stamp-speech PAGE.md
stamp-speech +pages:
    python3 tools/stamp_speech.py {{pages}}

model:
    lake build
    python3 tools/check_model.py

simulator:
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
    python3 tools/check_site.py site
    just check-presentation
