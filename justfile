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
    python3 tools/check_site.py site
    just check-presentation
    just rename-registry-test
    just commit-subjects-test

# #108: the rename tool must re-run cleanly on a pre-rename tree, be a no-op
# on the second run, and its gate must catch strays planted in .sh files.
rename-registry-test:
    bash tools/rename-registry.test.sh

# #195: every non-merge commit subject in a range must carry the Conventional
# Commit type release-please classifies by, or the work drops out of the
# changelog.
commit-subjects-test:
    bash tools/commit-subjects.test.sh
