# Run recipes within nix develop.
build-docs:
    python3 tools/prepare_docs.py
    mkdocs build --strict

serve-docs:
    python3 tools/prepare_docs.py
    mkdocs serve

check-presentation:
    python3 tools/check_presentation.py --front README.md README.md docs specs

ci:
    just build-docs
    python3 tools/check_site.py site
    just check-presentation
