"""One presentation contract for the flake check and development shell."""
from check_presentation import main

# These files are exact lookup registers, not substitutes for reader pages.
raise SystemExit(main([
    "--front", "README.md",
    "--register", "docs/model-ledger.md",
    "--register", "docs/theorems.md",
    "--register", "docs/mutants.md",
    "README.md", "docs", "specs",
]))
