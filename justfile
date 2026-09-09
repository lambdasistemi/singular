# Run recipes within nix develop.
build-docs:
    python3 tools/prepare_docs.py
    mkdocs build --strict

serve-docs:
    python3 tools/prepare_docs.py
    mkdocs serve

ci:
    just build-docs
    python3 tools/check_site.py site
