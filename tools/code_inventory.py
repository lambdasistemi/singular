#!/usr/bin/env python3
"""Repository code inventory (issue #278, slice S1).

Every file the tree actually holds is discovered by walking it — extensions,
shebangs, executable mode and component manifests are the only discovery
signals; there is no per-file list anywhere in this tool. Each discovered
file must resolve to exactly one row:

  - a code row, carrying one lint policy ID and one distinct format policy
    ID from the checked registry below, or
  - a non-code artifact class (data, evidence, lock, manifest, ...).

Anything else fails closed with a named diagnostic: an unmapped code file, a
file with an extension nobody classified, an extensionless executable with no
shebang, an unknown interpreter, an inert registry rule, or a dead policy.

The registry states enforcement HONESTLY. A policy is `enforced` only where a
checker actually runs in CI today, with its carrier named; everything else is
`pending` with the slice that owns it (#278 S2-S4) — pending policies are
visible debt, never green language coverage. This inventory is a mapping, not
enforcement: it proves every file is CLAIMED by a policy, and says which
claims are currently executed.

Reproducibility across contexts: in a Git checkout the walk skips `.git`
and skips an ignore-matched path ONLY when it is not tracked — a tracked
file is never concealed, so a force-added source stays in the inventory
while generated untracked noise is skipped. In a Git-free source, such as
a Nix flake store copy, ignore rules are inert, because every present file
is repository source. The `.gitignore` files are parsed (a supported,
fail-closed subset of gitignore syntax) in both contexts so the two cannot
drift. Nothing else depends on Git.

Usage:
  python3 tools/code_inventory.py [--root DIR] [--json] [--export-tree DIR]

Exit codes: 0 inventory complete; 1 unmapped/unclassified/inert findings;
2 usage or environment error.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import sys
from dataclasses import dataclass, field
from pathlib import Path, PurePosixPath

# ---------------------------------------------------------------------------
# Policy registry
# ---------------------------------------------------------------------------
# status:
#   enforced         — the checker runs in CI today over the stated extent
#   enforced-partial — a checker runs, but over less than the family extent;
#                      the note names exactly what runs and what does not
#   pending          — no checker exists yet; `owner` names the slice that
#                      owes it. Never described as coverage.
# A policy with status enforced/enforced-partial MUST carry `carrier`.

POLICIES: dict[str, dict] = {
    # ---- lint / static-check policies -------------------------------------
    "hlint-offchain-active": {
        "kind": "lint",
        "tool": "hlint",
        "status": "enforced",
        "carrier": "offchain `nix run .#lint` — CI job 'Off-chain lint'",
        "note": "bound to the checker's own discovered extent: every Cabal "
        "hs-source-dirs stanza of singular-registry.cabal (visited "
        "recursively, as the checker's find does) plus the two "
        "direct-GHC naming sources — the same discovery "
        "offchain/nix/checks.nix performs — minus the 13 HLint debt "
        "directories (see hlint-offchain-debt). An offchain source "
        "outside that visited extent fails the inventory instead of "
        "being claimed as enforced.",
    },
    "hlint-offchain-debt": {
        "kind": "lint",
        "tool": "hlint",
        "status": "pending",
        "owner": "#278 S3",
        "note": "the 13 directories excluded by #264 (journey and its nine "
        "sub-stanza dirs, naming/test, naming/drift, update-terminal) "
        "carry the baseline hint debt: 218 hints at #264 intake, 214 "
        "re-measured at cc6ea00 (offchain/nix/checks.nix). Debt is "
        "retained here as pending work, not converted to green.",
    },
    "hlint-conformance": {
        "kind": "lint",
        "tool": "hlint",
        "status": "pending",
        "owner": "#278 S3/S4",
        "note": "every Haskell source under conformance/, whatever component "
        "owns it (the Cabal stanzas and the #80 evaluation spike "
        "today); no HLint carrier covers this tree yet.",
    },
    "aiken-check-onchain": {
        "kind": "lint",
        "tool": "aiken check",
        "status": "enforced",
        "carrier": "registry.yml job 'Run the onchain Aiken suite as a flake "
        "check' (onchain nix flake check → aiken-check)",
        "note": "unit and property suite over the onchain validators, "
        "enforced and refused cases together.",
    },
    "aiken-check-naming": {
        "kind": "lint",
        "tool": "aiken check",
        "status": "enforced",
        "carrier": "registry.yml job 'Naming validators build, refuse, and "
        "match their pinned identity' (naming-onchain nix flake "
        "check)",
        "note": "unit and property suite over the naming validators.",
    },
    "lean-static": {
        "kind": "lint",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "lake build plus the theorem-debt reconciliation are semantic "
        "carriers, not lint; no Lean linter/style checker is adopted "
        "yet. S4 must adopt a policy (an explicit enforced style "
        "policy if no linter fits).",
    },
    "nix-lint": {
        "kind": "lint",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "flake evaluations and builds are build carriers, not lint.",
    },
    "python-lint": {
        "kind": "lint",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "the Python tools execute inside CI carriers (model check, "
        "coverage gate, docs preparation); execution is not lint.",
    },
    "shell-lint": {
        "kind": "lint",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "scripts execute inside CI carriers; the only shellcheck "
        "reach today is actionlint's embedded-shell checking of "
        ".github/workflows/conformance.yml alone.",
    },
    "js-lint": {
        "kind": "lint",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "the simulator corpus, gate and browser carriers exercise "
        "these modules functionally; functional execution is not a "
        "JavaScript linter.",
    },
    "html-simulator-lint": {
        "kind": "lint",
        "tool": "simulator gate + browser check",
        "status": "enforced",
        "carrier": "CI jobs 'Simulator corpus parity and controls' and "
        "'Simulator browser checks' (nix run .#simulator-check / "
        ".#browser-check)",
        "note": "functional DOM, story and corpus-parity checks over the "
        "shipped page — a behavioral check, not an HTML style linter.",
    },
    "html-docs-template-lint": {
        "kind": "lint",
        "tool": "mkdocs strict build + docs check",
        "status": "enforced",
        "carrier": "CI job 'Rendered documentation' (nix run .#docs-check; "
        "mkdocs build --strict in just ci)",
        "note": "the theme override is validated by the strict site build "
        "and the rendered-site checks.",
    },
    "css-lint": {
        "kind": "lint",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "the stylesheet is hashed into the shipped page by "
        "simulator/build.mjs and exercised by the browser check; no "
        "CSS checker is adopted.",
    },
    "workflow-yaml-lint": {
        "kind": "lint",
        "tool": "yq parse + actionlint",
        "status": "enforced-partial",
        "carrier": "conformance.yml job 'Workflow parses, lints clean, owned "
        "docs page bound': yq-go parses every .github/workflows/"
        "*.yml; actionlint (with shellcheck) runs over "
        "conformance.yml ONLY",
        "note": "actionlint over the other four workflow files is pending "
        "#278 S4 (which must re-check actionlint findings #191/#248).",
    },
    "just-lint": {
        "kind": "lint",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "a justfile parses whenever `just` loads its tree's recipes; "
        "no dedicated check covers all four files' embedded shell.",
    },
    # ---- format policies ---------------------------------------------------
    "fourmolu-offchain-active": {
        "kind": "format",
        "tool": "fourmolu",
        "status": "enforced",
        "carrier": "offchain `nix run .#lint` — CI job 'Off-chain lint', "
        "and the whole-tree `just format-check` inside "
        "`just ci` (CI job 'Development shell build')",
        "note": "the committed house fourmolu.yaml at the repository "
        "root (issue #278 S2), passed explicitly so a missing "
        "configuration fails loudly; the #264 A-003 source fence "
        "is removed and the extent is the checker's own "
        "manifest-discovered set — every Cabal hs-source-dirs "
        "stanza of singular-registry.cabal plus the two direct-GHC "
        "naming sources — with no directory exclusions. An offchain "
        "source outside that visited extent fails the inventory "
        "instead of being claimed as enforced.",
    },
    "fourmolu-conformance": {
        "kind": "format",
        "tool": "fourmolu",
        "status": "enforced",
        "carrier": "conformance `nix run .#format-check` — CI job "
        "'Conformance Haskell format check' (conformance.yml), "
        "and the whole-tree `just format-check` inside `just ci`",
        "note": "the same committed house fourmolu.yaml, over the "
        "Conformance Cabal extent plus the #80 evaluation spike "
        "harness, discovered from the manifests at check time with "
        "no exclusions; the conformance lock is byte-identical to "
        "offchain's, so both checks resolve the same pinned "
        "Fourmolu.",
    },
    "aiken-fmt": {
        "kind": "format",
        "tool": "aiken fmt",
        "status": "pending",
        "owner": "#278 S4",
        "note": "hand-written validators; `aiken fmt --check` is not a CI carrier yet.",
    },
    "aiken-fmt-generated": {
        "kind": "format",
        "tool": "aiken fmt (via the generator)",
        "status": "enforced",
        "carrier": "registry.yml job 'Cage vectors match the generator' "
        "(offchain just vectors-check: generator output formatted "
        "with the pinned Aiken, diffed against the committed file)",
        "note": "the generated vectors file is never hand-formatted; the "
        "freshness check enforces the formatted generator output.",
    },
    "lean-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "no Lean formatter is adopted (candidate: lake fmt); S4 "
        "rules the policy.",
    },
    "lean-fmt-mirror": {
        "kind": "format",
        "tool": "mirror parity (not a formatter)",
        "status": "enforced",
        "carrier": "CI job 'Simulator corpus parity and controls' "
        "(simulator/mirror-check.mjs: byte equality with lean/, "
        "both directions)",
        "note": "the simulator's Lean mirror is regenerated from lean/, never "
        "formatted independently; parity is what the carrier "
        "enforces.",
    },
    "nix-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
    },
    "python-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
    },
    "shell-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
    },
    "js-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
    },
    "html-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4 ruling",
        "note": "no general HTML formatter is adopted; the issue requires an "
        "explicit enforced style policy rather than a false coverage "
        "claim.",
    },
    "css-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4 ruling",
        "note": "no general CSS formatter is adopted; explicit style policy pending.",
    },
    "workflow-yaml-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
    },
    "just-fmt": {
        "kind": "format",
        "tool": "none adopted",
        "status": "pending",
        "owner": "#278 S4",
        "note": "candidate: `just --fmt`; not a carrier yet.",
    },
    "page-build-generated": {
        "kind": "format",
        "tool": "page build identity (not a formatter)",
        "status": "enforced",
        "carrier": "CI job 'Simulator corpus parity and controls' "
        "(simulator/build.mjs --check: the committed index.html "
        "must equal the page rebuilt from its sources)",
        "note": "simulator/index.html is generated; freshness, not "
        "independent formatting, is the enforced policy.",
    },
}

# ---------------------------------------------------------------------------
# Code rules: ordered, first match wins. `pattern` is a path glob where `**`
# crosses directory boundaries and `*` does not. `family` must agree with the
# file's discovered family. Every rule must match at least one file (an inert
# rule fails the run) and every policy must be referenced (a dead policy
# fails the run).
# ---------------------------------------------------------------------------

# The onchain/ and offchain/ trees descend from a frozen upstream import.
# PROVENANCE.md is the authoritative citation surface for that import — the
# upstream repository, the transfer method and the frozen revision — and the
# rename gate permits the upstream product name only there and on its two
# sanctioned citation lines, so this note names the revision and points at
# PROVENANCE.md instead of restating the upstream name.
VENDOR_NOTE = (
    "descends from the frozen upstream import documented in "
    "PROVENANCE.md, the authoritative provenance record — see it "
    "for the upstream repository and transfer method — at frozen "
    "upstream revision 34a5bfbb8cca2cb1911b7060d0e61db28ba21e83; "
    "maintained in-repo since"
)

CODE_RULES: list[dict] = [
    {
        "id": "aiken-vectors-onchain",
        "family": "aiken",
        "pattern": "onchain/validators/cage_vectors.ak",
        "lint": "aiken-check-onchain",
        "format": "aiken-fmt-generated",
        "generated": True,
        "provenance": "generated by the offchain test-vectors executable and "
        "formatted with the pinned Aiken (offchain justfile "
        "`generate-vectors`, the only writer); freshness is "
        "enforced by registry.yml `vectors-check`",
        "note": VENDOR_NOTE,
    },
    {
        "id": "aiken-validators-onchain",
        "family": "aiken",
        "pattern": "onchain/validators/**/*.ak",
        "lint": "aiken-check-onchain",
        "format": "aiken-fmt",
        "generated": False,
        "note": VENDOR_NOTE,
    },
    {
        "id": "aiken-validators-naming",
        "family": "aiken",
        "pattern": "naming-onchain/validators/**/*.ak",
        "lint": "aiken-check-naming",
        "format": "aiken-fmt",
        "generated": False,
    },
    # Haskell. The #264 A-003 source fence (journey/verifier and
    # journey/retire-verify kept at intake bytes) is removed by #278 S2:
    # every offchain Haskell source — the formerly fenced verifier sources
    # included — is formatted under the house configuration, so they now
    # match the journey debt rule below like every other journey source.
    # Every offchain rule is restricted ("where": "haskell-checker-extent")
    # to the checker's own manifest-discovered extent — the Cabal
    # hs-source-dirs plus naming/test and naming/drift, visited recursively
    # exactly as offchain/nix/checks.nix does — so an enforced policy is
    # never claimed for a file the checker does not visit; anything else
    # under offchain/ hits the reject rule below and fails closed.
    # HLint debt directories: journey (root and every sub-stanza),
    # naming/test, naming/drift, update-terminal — the 13 #264 exclusions.
    {
        "id": "hs-offchain-debt-journey",
        "family": "haskell",
        "pattern": "offchain/journey/**/*.hs",
        "where": "haskell-checker-extent",
        "lint": "hlint-offchain-debt",
        "format": "fourmolu-offchain-active",
        "generated": False,
        "note": VENDOR_NOTE,
    },
    {
        "id": "hs-offchain-debt-naming-test",
        "family": "haskell",
        "pattern": "offchain/naming/test/**/*.hs",
        "where": "haskell-checker-extent",
        "lint": "hlint-offchain-debt",
        "format": "fourmolu-offchain-active",
        "generated": False,
        "note": VENDOR_NOTE,
    },
    {
        "id": "hs-offchain-debt-naming-drift",
        "family": "haskell",
        "pattern": "offchain/naming/drift/**/*.hs",
        "where": "haskell-checker-extent",
        "lint": "hlint-offchain-debt",
        "format": "fourmolu-offchain-active",
        "generated": False,
        "note": VENDOR_NOTE,
    },
    {
        "id": "hs-offchain-debt-update-terminal",
        "family": "haskell",
        "pattern": "offchain/update-terminal/**/*.hs",
        "where": "haskell-checker-extent",
        "lint": "hlint-offchain-debt",
        "format": "fourmolu-offchain-active",
        "generated": False,
        "note": VENDOR_NOTE,
    },
    {
        "id": "hs-offchain",
        "family": "haskell",
        "pattern": "offchain/**/*.hs",
        "where": "haskell-checker-extent",
        "lint": "hlint-offchain-active",
        "format": "fourmolu-offchain-active",
        "generated": False,
        "note": VENDOR_NOTE,
    },
    # A reject rule: an offchain Haskell source NO checker-visited component
    # directory contains is a finding, never a row — the stable diagnostic
    # names the boundary. Reject rules fire only on violating trees, so the
    # happy path never references them; control c7 proves this one live.
    {
        "id": "hs-offchain-outside-checker-extent",
        "family": "haskell",
        "pattern": "offchain/**/*.hs",
        "reject": "haskell source outside every checker-visited component "
        "directory (the offchain lint discovers its extent from "
        "singular-registry.cabal hs-source-dirs plus naming/test and "
        "naming/drift; add the component to the Cabal manifest or map "
        "an explicit pending policy)",
    },
    {
        "id": "hs-conformance",
        "family": "haskell",
        "pattern": "conformance/**/*.hs",
        "lint": "hlint-conformance",
        "format": "fourmolu-conformance",
        "generated": False,
        "note": "every Haskell source under conformance/, whatever component "
        "owns it (the Cabal stanzas and the #80 evaluation spike "
        "harness today)",
    },
    # Lean — the simulator mirror first (byte-bound to lean/, never formatted
    # independently), then every other Lean source.
    {
        "id": "lean-simulator-mirror",
        "family": "lean",
        "pattern": "simulator/formal/**/*.lean",
        "lint": "lean-static",
        "format": "lean-fmt-mirror",
        "generated": True,
        "provenance": "byte mirror of the canonical lean/ sources, regenerated "
        "by the mirror procedure; simulator/mirror-check.mjs "
        "enforces two-directional byte equality in CI",
    },
    {
        "id": "lean-all",
        "family": "lean",
        "pattern": "**/*.lean",
        "lint": "lean-static",
        "format": "lean-fmt",
        "generated": False,
        "note": "lean/ (lakefile.toml srcDir), conformance/lean/DriverTransport "
        "(compiled into the Conformance driver transport), and "
        "tools/axioms.lean (compiled by the model build)",
    },
    {
        "id": "nix-all",
        "family": "nix",
        "pattern": "**/*.nix",
        "lint": "nix-lint",
        "format": "nix-fmt",
        "generated": False,
    },
    {
        "id": "python-all",
        "family": "python",
        "pattern": "**/*.py",
        "lint": "python-lint",
        "format": "python-fmt",
        "generated": False,
    },
    {
        "id": "shell-all",
        "family": "shell",
        "pattern": "**/*.sh",
        "lint": "shell-lint",
        "format": "shell-fmt",
        "generated": False,
    },
    {
        "id": "javascript-all",
        "family": "javascript",
        "pattern": "**/*.mjs",
        "lint": "js-lint",
        "format": "js-fmt",
        "generated": False,
    },
    {
        "id": "javascript-generic",
        "family": "javascript",
        "pattern": "**/*.js",
        "lint": "js-lint",
        "format": "js-fmt",
        "generated": False,
    },
    # HTML — the generated shipped page first, then its source templates,
    # then the docs theme override.
    {
        "id": "html-simulator-generated",
        "family": "html",
        "pattern": "simulator/index.html",
        "lint": "html-simulator-lint",
        "format": "page-build-generated",
        "generated": True,
        "provenance": "generated by simulator/build.mjs from page-template.html, "
        "page-body.html, page.css, the .mjs modules and the "
        "corpora; build.mjs --check enforces freshness in CI",
    },
    {
        "id": "html-simulator-sources",
        "family": "html",
        "pattern": "simulator/*.html",
        "lint": "html-simulator-lint",
        "format": "html-fmt",
        "generated": False,
    },
    {
        "id": "html-docs-template",
        "family": "html",
        "pattern": "overrides/*.html",
        "lint": "html-docs-template-lint",
        "format": "html-fmt",
        "generated": False,
    },
    {
        "id": "css-simulator",
        "family": "css",
        "pattern": "**/*.css",
        "lint": "css-lint",
        "format": "css-fmt",
        "generated": False,
    },
    {
        "id": "workflow-yaml",
        "family": "workflow-yaml",
        "pattern": ".github/workflows/*.yml",
        "lint": "workflow-yaml-lint",
        "format": "workflow-yaml-fmt",
        "generated": False,
    },
    {
        "id": "just-taskfiles",
        "family": "just",
        "pattern": "**/justfile",
        "lint": "just-lint",
        "format": "just-fmt",
        "generated": False,
        "note": "task-runner files carrying embedded shell recipes; the "
        "embedded shell is checked only where a carrier executes it",
    },
]

# ---------------------------------------------------------------------------
# Non-code artifact classes: ordered, first match wins. Generated classes
# carry provenance and the policy that keeps them fresh.
# ---------------------------------------------------------------------------

NONCODE_CLASSES: list[dict] = [
    {
        "id": "lean-mutation-evidence",
        "pattern": "lean/insert-absent-mutations.json",
        "note": "recorded results of the bounded insert-absent mutation campaign",
    },
    {
        "id": "lean-model-export",
        "pattern": "lean/*.json",
        "generated": True,
        "provenance": "generated by the Lean corpus/driver executables and "
        "exported through tools/check_model.py; the model check "
        "(just model, CI job 'model') enforces freshness",
        "note": "corpora and theorem-debt manifests",
    },
    {
        "id": "simulator-mirror-json",
        "pattern": "simulator/formal/*.json",
        "generated": True,
        "provenance": "byte mirrors of the lean/ theorem-debt exports; "
        "simulator/mirror-check.mjs enforces parity in CI",
    },
    {
        "id": "simulator-corpus-copy",
        "pattern": "simulator/corpus.json",
        "generated": True,
        "provenance": "byte copy of lean/corpus.json embedded in the shipped "
        "page; mirror-check.mjs enforces the equality",
    },
    {
        "id": "simulator-identity",
        "pattern": "simulator/identity.json",
        "generated": True,
        "provenance": "generated by simulator/identity.mjs (bound file hashes); "
        "simulator/build.mjs verifies it before building",
    },
    {
        "id": "speech-companion",
        "pattern": "**/*.speech.json",
        "note": "author-curated speech bound to its page's exact hash by "
        "tools/stamp_speech.py; the presentation checks enforce the "
        "binding",
    },
    {
        "id": "script-identity",
        "pattern": "**/script-identity.json",
        "generated": True,
        "provenance": "generated by the script-identity-regen recipes from a "
        "fresh blueprint build; the script-identity CI checks "
        "compare every validator both directions",
    },
    {
        "id": "release-config",
        "pattern": "{.release-please-manifest.json,release-please-config.json}",
        "note": "release-please configuration",
    },
    {
        "id": "formatter-config",
        "pattern": "fourmolu.yaml",
        "note": "the one house Fourmolu configuration (issue #278 S2), read "
        "explicitly by every Haskell format entrypoint — the offchain "
        "lint app, the conformance format-check app and the root just "
        "format/format-check recipes; the root-anchored pattern means "
        "a second per-tree fourmolu.yaml stays unclassified and fails "
        "closed, because per-tree divergence is exactly what the one "
        "configuration forbids",
    },
    {
        "id": "lake-lock",
        "pattern": "lake-manifest.json",
        "generated": True,
        "provenance": "generated by lake from lakefile.toml and lean-toolchain; "
        "the model build consumes it",
    },
    {
        "id": "lock-files",
        "pattern": "**/*.lock",
        "generated": True,
        "provenance": "generated by their tools (nix flake lock, aiken); "
        "committed and pinned, never hand-edited",
    },
    {
        "id": "markdown",
        "pattern": "**/*.md",
        "note": "documentation, specifications and readmes; checked by the "
        "docs build and presentation carriers, not code lint",
    },
    {
        "id": "json-data",
        "pattern": "**/*.json",
        "note": "fixtures, receipts, planning records, preprod evidence and other data",
    },
    {
        "id": "text-artifacts",
        "pattern": "**/*.txt",
        "note": "version pin, evidence rows and text fixtures",
    },
    {"id": "tsv-artifacts", "pattern": "**/*.tsv", "note": "tabular harness data"},
    {
        "id": "log-artifacts",
        "pattern": "**/*.log",
        "note": "recorded command output (evidence)",
    },
    {
        "id": "diff-patch-inputs",
        "pattern": "**/*.{diff,patch}",
        "note": "harness inputs applying or reverting deltas; never executed as code",
    },
    {
        "id": "key-material",
        "pattern": "**/*.{skey,opcert}",
        "note": "devnet genesis delegate key fixtures (data; the executable "
        "bit is upstream noise, not a script signal)",
    },
    {"id": "license-texts", "pattern": "**/LICENSE"},
    {
        "id": "gitignore-files",
        "pattern": "**/.gitignore",
        "note": "read by this inventory's walk (fail-closed subset) and by Git",
    },
    {
        "id": "lean-toolchain-pin",
        "pattern": "lean-toolchain",
        "note": "pinned Lean toolchain",
    },
    {
        "id": "mkdocs-config",
        "pattern": "mkdocs.yml",
        "note": "site configuration; validated by the strict docs build",
    },
    {
        "id": "cabal-manifests",
        "pattern": "**/{*.cabal,cabal.project}",
        "note": "Cabal package manifests; parsed by the builds and by this "
        "inventory (hs-source-dirs discovery)",
    },
    {
        "id": "lake-manifest-toml",
        "pattern": "lakefile.toml",
        "note": "Lake package manifest; parsed by this inventory (srcDir discovery)",
    },
    {
        "id": "aiken-manifests",
        "pattern": "**/aiken.toml",
        "note": "Aiken package manifests marking the two on-chain component roots",
    },
]

CODE_EXTENSIONS = {
    "hs": "haskell",
    "ak": "aiken",
    "lean": "lean",
    "nix": "nix",
    "py": "python",
    "sh": "shell",
    "mjs": "javascript",
    "js": "javascript",
    "html": "html",
    "css": "css",
}

SHEBANG_FAMILIES = {
    "bash": "shell",
    "sh": "shell",
    "dash": "shell",
    "ksh": "shell",
    "zsh": "shell",
    "python3": "python",
    "python": "python",
}

# Extensions that carry no code signal but are recognized artifact data;
# a shebang on one of these is a finding, not a script.
KNOWN_NONCODE_EXTENSIONS = {
    "md",
    "json",
    "txt",
    "tsv",
    "log",
    "diff",
    "patch",
    "skey",
    "opcert",
    "lock",
    "yml",
    "yaml",
    "toml",
    "cabal",
    "project",
    "gitignore",
    "speech",
}


class InventoryError(Exception):
    """Fatal environment/usage problem (exit 2)."""


@dataclass
class Finding:
    path: str
    reason: str

    def render(self) -> str:
        return f"{self.reason}: {self.path}"


# ---------------------------------------------------------------------------
# Glob matching: `**` spans directories, `*` stays inside one segment.
# ---------------------------------------------------------------------------


def _compile_glob(pattern: str) -> tuple[tuple[str, ...], bool]:
    parts = tuple(pattern.split("/"))
    for part in parts:
        if "**" in part and part != "**":
            raise InventoryError(f"bad glob in registry: {pattern}")
    return parts, "**" in parts


def glob_match(pattern: str, relpath: str) -> bool:
    parts, _ = _compile_glob(pattern)
    path = PurePosixPath(relpath).parts

    def match(pi: int, qi: int) -> bool:
        if qi == len(parts):
            return pi == len(path)
        seg = parts[qi]
        if seg == "**":
            if match(pi, qi + 1):
                return True
            return pi < len(path) and match(pi + 1, qi)
        if pi == len(path):
            return False
        return _fnmatch_seg(seg, path[pi]) and match(pi + 1, qi + 1)

    return match(0, 0)


def _fnmatch_seg(seg: str, name: str) -> bool:
    # segment-local wildcard: translate '*' and '?'-free literal
    import fnmatch

    return fnmatch.fnmatchcase(name, seg)


# ---------------------------------------------------------------------------
# .gitignore subset (fail-closed on anything the walker cannot honor)
# ---------------------------------------------------------------------------


class GitignoreSyntaxError(InventoryError):
    pass


@dataclass
class IgnorePattern:
    anchored: bool
    dir_only: bool
    segments: tuple[str, ...]

    def _match_path(self, parts: tuple[str, ...]) -> bool:
        if self.anchored:
            return len(self.segments) == len(parts) and all(
                _fnmatch_seg(s, n) for s, n in zip(self.segments, parts)
            )
        # Unanchored patterns are single-segment names (git's rule).
        return _fnmatch_seg(self.segments[0], parts[-1])

    def match_dir(self, parts: tuple[str, ...]) -> bool:
        """The pattern selects this directory. A dir-only pattern matches
        directories only; any other pattern matches files and directories
        alike, as git does."""
        return self._match_path(parts)

    def conceals(self, parts: tuple[str, ...]) -> bool:
        """The pattern hides the file at `parts` — by matching the file
        itself or a directory above it. A dir-only pattern never matches a
        file directly; it conceals through an ancestor directory."""
        for i in range(1, len(parts) + 1):
            if self.dir_only and i == len(parts):
                continue
            if self._match_path(parts[:i]):
                return True
        return False


def parse_gitignore(path: Path, base_rel: str) -> list[IgnorePattern]:
    patterns: list[IgnorePattern] = []
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.rstrip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("!"):
            raise GitignoreSyntaxError(
                f"unsupported .gitignore negation at {path}:{lineno}: {raw}"
            )
        for ch in "?[]\\":
            if ch in line:
                raise GitignoreSyntaxError(
                    f"unsupported .gitignore syntax at {path}:{lineno}: {raw}"
                )
        dir_only = line.endswith("/")
        body = line[:-1] if dir_only else line
        anchored = body.startswith("/")
        if anchored:
            body = body[1:]
        if not body:
            raise GitignoreSyntaxError(f"empty .gitignore pattern at {path}:{lineno}")
        # git anchors any pattern with an interior '/' (after stripping a
        # leading one); unanchored patterns are single-segment names.
        if "/" in body:
            anchored = True
        segments = tuple(body.split("/"))
        if not anchored and len(segments) > 1:
            raise GitignoreSyntaxError(
                f"unsupported .gitignore pattern at {path}:{lineno}: {raw}"
            )
        patterns.append(
            IgnorePattern(anchored=anchored, dir_only=dir_only, segments=segments)
        )
    return patterns


# ---------------------------------------------------------------------------
# Component manifests (discovery inputs; never a frozen file list)
# ---------------------------------------------------------------------------


@dataclass
class Manifests:
    haskell_dirs: set[str] = field(default_factory=set)
    lean_dirs: set[str] = field(default_factory=set)
    aiken_dirs: set[str] = field(default_factory=set)


def _read(root: Path, rel: str) -> str:
    p = root / rel
    if not p.is_file():
        raise InventoryError(f"manifest failure: required manifest missing: {rel}")
    return p.read_text(encoding="utf-8")


def parse_manifests(root: Path) -> Manifests:
    m = Manifests()
    # Cabal: every hs-source-dirs field of every stanza, plus the two
    # direct-GHC naming sources the offchain lint also adds literally
    # (naming/test and naming/drift compile with the dev-shell GHC outside
    # any Cabal stanza — offchain/nix/checks.nix documents the same pair).
    cabal_files = [
        "offchain/singular-registry.cabal",
        "conformance/conformance.cabal",
        "conformance/coverage/evaluation/spike.cabal",
    ]
    for rel in cabal_files:
        text = _read(root, rel)
        found = False
        for line in text.splitlines():
            stripped = line.strip()
            if re.match(r"^[A-Za-z0-9-]+:", stripped):
                if stripped.lower().replace(" ", "").startswith("hs-source-dirs:"):
                    value = stripped.split(":", 1)[1]
                    for d in re.split(r"[,\s]+", value.strip()):
                        if not d:
                            continue
                        found = True
                        base = str(PurePosixPath(rel).parent)
                        full = f"{base}/{d}" if base != "." else d
                        m.haskell_dirs.add(str(PurePosixPath(full)))
        if not found:
            raise InventoryError(
                f"manifest failure: no hs-source-dirs parsed from {rel}"
            )
    m.haskell_dirs |= {"offchain/naming/test", "offchain/naming/drift"}
    for d in sorted(m.haskell_dirs):
        if not (root / d).is_dir():
            raise InventoryError(
                f"manifest failure: declared Haskell source directory missing: {d}"
            )
    # Lake: srcDir names the Lean source root.
    lakefile = _read(root, "lakefile.toml")
    mo = re.search(r'^\s*srcDir\s*=\s*"([^"]+)"', lakefile, re.MULTILINE)
    if not mo:
        raise InventoryError("manifest failure: no srcDir parsed from lakefile.toml")
    m.lean_dirs.add(str(PurePosixPath(mo.group(1))))
    for d in sorted(m.lean_dirs):
        if not (root / d).is_dir():
            raise InventoryError(
                f"manifest failure: declared Lean source directory missing: {d}"
            )
    # Aiken: each aiken.toml marks a component root; aiken discovers its
    # sources under validators/ and tests/ by convention.
    for rel in sorted(_walk_names(root, "aiken.toml")):
        base = str(PurePosixPath(rel).parent)
        for sub in ("validators", "tests"):
            d = f"{base}/{sub}" if base != "." else sub
            if (root / d).is_dir():
                m.aiken_dirs.add(d)
    if not m.aiken_dirs:
        raise InventoryError("manifest failure: no Aiken component root found")
    return m


def _walk_names(root: Path, name: str) -> list[str]:
    out: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != ".git"]
        if name in filenames:
            out.append(str(Path(dirpath, name).relative_to(root)))
    return sorted(out)


# ---------------------------------------------------------------------------
# Tree walk
# ---------------------------------------------------------------------------


def _tracked_files(root: Path) -> set[str] | None:
    """The tracked file set when the root is a Git repository, else None.

    In a checkout, an ignore-matched path is skipped ONLY when it is not
    tracked: gitignore governs untracked working-tree noise, while a
    tracked file — including a force-added source — is repository content
    and must never be concealed. In a Git-free source (Nix flake store
    copy, control scratch export) there is no noise to skip and no oracle
    to tell noise from source, so ignore rules are inert there.
    """
    if not (root / ".git").exists():
        return None
    import subprocess

    try:
        proc = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-z"], capture_output=True, check=True
        )
    except FileNotFoundError as exc:
        raise InventoryError(
            "a Git repository is present but the git tool is unavailable — "
            "the tracked set cannot be established and ignore rules cannot "
            "safely skip anything; refusing to guess"
        ) from exc
    except subprocess.CalledProcessError as exc:
        detail = exc.stderr.decode("utf-8", "replace").strip() if exc.stderr else ""
        raise InventoryError(f"git ls-files failed: {detail}") from exc
    return {p for p in proc.stdout.decode("utf-8", "surrogateescape").split("\0") if p}


def walk_tree(root: Path) -> tuple[list[tuple[str, bool, bool]], str]:
    """Walk the tree and return (sorted (relpath, is_executable,
    has_no_extension) rows, context). `.git` is always skipped. Ignore
    patterns apply only in a Git checkout and only to UNTRACKED paths; the
    .gitignore files are parsed in every context so unsupported syntax
    fails closed everywhere."""
    tracked = _tracked_files(root)
    context = "git-checkout" if tracked is not None else "git-free"
    tracked_prefixes: set[str] = set()
    if tracked is not None:
        for t in tracked:
            parts = t.split("/")
            for i in range(1, len(parts)):
                tracked_prefixes.add("/".join(parts[:i]))
    out: list[tuple[str, bool, bool]] = []

    def concealed(
        rel: str, stack: list[tuple[str, list[IgnorePattern]]], is_dir: bool
    ) -> bool:
        parts_full = tuple(rel.split("/"))
        for base, patterns in stack:
            bparts = tuple(base.split("/")) if base else ()
            if parts_full[: len(bparts)] != bparts:
                continue
            parts = parts_full[len(bparts) :]
            if not parts:
                continue
            for p in patterns:
                if p.match_dir(parts) if is_dir else p.conceals(parts):
                    return True
        return False

    def rec(
        dirpath: Path, rel: str, stack: list[tuple[str, list[IgnorePattern]]]
    ) -> None:
        dirpath = Path(dirpath)
        gi = dirpath / ".gitignore"
        if gi.is_file():
            stack = stack + [(rel, parse_gitignore(gi, rel))]
        for entry in sorted(os.scandir(dirpath), key=lambda e: e.name):
            if entry.name == ".git":
                continue
            erel = f"{rel}/{entry.name}" if rel else entry.name
            if entry.is_dir(follow_symlinks=False):
                # Prune an ignore-matched directory only when no tracked
                # file lives under it.
                if (
                    tracked is not None
                    and concealed(erel, stack, True)
                    and erel not in tracked_prefixes
                ):
                    continue
                rec(entry.path, erel, stack)
            else:
                # everything that is not a directory is inventoried as a
                # file; a tracked symlink is data nobody classified and
                # must fail closed rather than slip past the walk
                if (
                    tracked is not None
                    and concealed(erel, stack, False)
                    and erel not in tracked
                ):
                    continue
                mode = entry.stat(follow_symlinks=False).st_mode
                out.append((erel, bool(mode & stat.S_IXUSR), "." not in entry.name))

    rec(root, "", [])
    return sorted(out), context


# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------


def read_shebang(root: Path, rel: str) -> str | None:
    try:
        with open(root / rel, "rb") as fh:
            head = fh.readline(120)
    except OSError as exc:
        raise InventoryError(f"cannot read {rel}: {exc}") from exc
    if not head.startswith(b"#!"):
        return None
    text = head[2:].decode("utf-8", "replace").strip()
    if " " in text:
        text = (
            text.split(" ", 1)[1]
            if text.startswith("/usr/bin/env")
            else text.split(" ", 1)[0]
        )
    return text.rsplit("/", 1)[-1] or None


def classify(
    root: Path, files: list[tuple[str, bool, bool]], manifests: Manifests
) -> tuple[list[dict], list[Finding]]:
    rows: list[dict] = []
    findings: list[Finding] = []
    for rel, executable, no_ext in files:
        ext = (
            None
            if no_ext or "." not in PurePosixPath(rel).name
            else PurePosixPath(rel).suffix.lstrip(".").lower()
        )
        family = None
        attribution = None
        shebang = read_shebang(root, rel)
        sb_family = None
        if shebang is not None:
            if shebang not in SHEBANG_FAMILIES:
                findings.append(
                    Finding(rel, f"unknown interpreter in shebang ({shebang})")
                )
            else:
                sb_family = SHEBANG_FAMILIES[shebang]
        if ext in CODE_EXTENSIONS:
            family = CODE_EXTENSIONS[ext]
            if sb_family is not None and sb_family != family:
                findings.append(Finding(rel, "shebang/extension family conflict"))
                continue
        elif PurePosixPath(rel).parts[:2] == (".github", "workflows") and ext in (
            "yml",
            "yaml",
        ):
            family = "workflow-yaml"
        elif PurePosixPath(rel).name == "justfile":
            family = "just"
        elif sb_family is not None:
            if ext in KNOWN_NONCODE_EXTENSIONS:
                findings.append(Finding(rel, "shebang on a non-code artifact"))
                continue
            family = sb_family
            attribution = "shebang"
        else:
            # Known artifact extensions resolve to their class first; only
            # extensions nobody recognizes may be attributed to a component
            # family through its manifest-declared source directories.
            cls = _first_class(rel)
            if cls is not None:
                rows.append(
                    {
                        "path": rel,
                        "kind": "noncode",
                        "class": cls["id"],
                        "generated": bool(cls.get("generated")),
                    }
                )
                continue
            if ext is None or ext not in KNOWN_NONCODE_EXTENSIONS:
                family, attribution = _manifest_attribution(rel, ext, manifests)

        if family is not None:
            rule = _first_code_rule(family, rel, manifests)
            if rule is not None and rule.get("reject"):
                findings.append(Finding(rel, rule["reject"]))
                continue
            if rule is None:
                why = f"unmapped {family} source"
                if attribution == "manifest":
                    why += (
                        f" (nonstandard extension .{ext} inside a "
                        f"declared component source directory)"
                    )
                elif attribution == "shebang":
                    why += " (discovered by shebang)"
                findings.append(Finding(rel, why))
                continue
            rows.append(
                {
                    "path": rel,
                    "kind": "code",
                    "family": family,
                    "lint": rule["lint"],
                    "format": rule["format"],
                    "generated": bool(rule.get("generated")),
                    "rule": rule["id"],
                }
            )
            continue

        cls = _first_class(rel)
        if cls is not None:
            rows.append(
                {
                    "path": rel,
                    "kind": "noncode",
                    "class": cls["id"],
                    "generated": bool(cls.get("generated")),
                }
            )
            continue
        if ext is None and executable:
            findings.append(
                Finding(rel, "unknown executable file (no extension, no shebang)")
            )
            continue
        detail = (
            f"unclassified file (unknown extension .{ext})"
            if ext
            else "unclassified file (no extension)"
        )
        findings.append(Finding(rel, detail))
    return rows, findings


def _manifest_attribution(
    rel: str, ext: str | None, manifests: Manifests
) -> tuple[str | None, str | None]:
    """Attribute a file no other signal classified to a component family
    through its manifest-declared source directories. Only files whose
    extension is unknown to every table reach this point."""
    parts = PurePosixPath(rel).parts
    for d in sorted(manifests.haskell_dirs, key=len, reverse=True):
        if parts[: len(d.split("/"))] == tuple(d.split("/")):
            return "haskell", "manifest"
    for d in sorted(manifests.lean_dirs, key=len, reverse=True):
        if parts[: len(d.split("/"))] == tuple(d.split("/")):
            return "lean", "manifest"
    for d in sorted(manifests.aiken_dirs, key=len, reverse=True):
        if parts[: len(d.split("/"))] == tuple(d.split("/")):
            return "aiken", "manifest"
    return None, None


def _under_any_dir(rel: str, dirs: set[str]) -> bool:
    parts = PurePosixPath(rel).parts
    for d in dirs:
        dp = tuple(d.split("/"))
        if parts[: len(dp)] == dp:
            return True
    return False


def _rule_applies(rule: dict, rel: str, manifests: Manifests) -> bool:
    if not glob_match(rule["pattern"], rel):
        return False
    where = rule.get("where")
    if where is None:
        return True
    if where == "haskell-checker-extent":
        # The file sits inside a component directory the offchain checker
        # itself discovers and visits (recursively, like its find).
        return _under_any_dir(rel, manifests.haskell_dirs)
    raise InventoryError(f"unknown where predicate in registry: {where}")


def _first_code_rule(family: str, rel: str, manifests: Manifests) -> dict | None:
    for rule in CODE_RULES:
        if rule["family"] == family and _rule_applies(rule, rel, manifests):
            return rule
    return None


def _first_class(rel: str) -> dict | None:
    for cls in NONCODE_CLASSES:
        if _class_match(cls["pattern"], rel):
            return cls
    return None


def _class_match(pattern: str, rel: str) -> bool:
    # class patterns may use {a,b} alternation at any segment
    m = re.fullmatch(r"([^{}]*)(?:\{([^}]*)\})?(.*)", pattern)
    if not m or "{" in m.group(1) + (m.group(3) or ""):
        raise InventoryError(f"bad class pattern in registry: {pattern}")
    prefix, alts, suffix = m.group(1), m.group(2), m.group(3) or ""
    if alts is None:
        return glob_match(pattern, rel)
    return any(glob_match(f"{prefix}{a}{suffix}", rel) for a in alts.split(","))


# ---------------------------------------------------------------------------
# Registry self-checks
# ---------------------------------------------------------------------------


def self_check(rows: list[dict]) -> list[str]:
    problems: list[str] = []
    matched_rules = {r["rule"] for r in rows if r["kind"] == "code"}
    matched_classes = {r["class"] for r in rows if r["kind"] == "noncode"}
    for rule in CODE_RULES:
        if rule.get("reject"):
            # A reject rule fires only on a tree that violates it, so the
            # happy path never references it; control c7 proves it live on
            # every CI run instead of the clean tree doing so.
            continue
        if rule["id"] not in matched_rules:
            problems.append(
                f"inert rule: {rule['id']} ({rule['pattern']}) matched no file"
            )
    for cls in NONCODE_CLASSES:
        if cls["id"] not in matched_classes:
            problems.append(
                f"inert class: {cls['id']} ({cls['pattern']}) matched no file"
            )
    used: set[str] = set()
    for rule in CODE_RULES:
        if rule.get("reject"):
            continue
        used.update((rule["lint"], rule["format"]))
    for pid in sorted(POLICIES):
        if pid not in used:
            problems.append(f"policy never referenced: {pid}")
    for pid in sorted(used):
        if pid not in POLICIES:
            problems.append(f"rule references undefined policy: {pid}")
    for pid, p in POLICIES.items():
        if p["status"] in ("enforced", "enforced-partial") and not p.get("carrier"):
            problems.append(f"policy {pid} claims enforcement without a carrier")
        if p["status"] == "pending" and not p.get("owner"):
            problems.append(f"policy {pid} is pending without an owning slice")
    return problems


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------


def summarize(rows: list[dict], context: str) -> dict:
    code = [r for r in rows if r["kind"] == "code"]
    noncode = [r for r in rows if r["kind"] == "noncode"]
    fam = {}
    for r in code:
        fam[r["family"]] = fam.get(r["family"], 0) + 1
    lint_stat = {}
    fmt_stat = {}
    for r in code:
        lint_stat[POLICIES[r["lint"]]["status"]] = (
            lint_stat.get(POLICIES[r["lint"]]["status"], 0) + 1
        )
        fmt_stat[POLICIES[r["format"]]["status"]] = (
            fmt_stat.get(POLICIES[r["format"]]["status"], 0) + 1
        )
    classes = {}
    for r in noncode:
        classes[r["class"]] = classes.get(r["class"], 0) + 1
    return {
        "context": context,
        "files": len(rows),
        "code": len(code),
        "noncode": len(noncode),
        "families": dict(sorted(fam.items())),
        "lint_status": dict(sorted(lint_stat.items())),
        "format_status": dict(sorted(fmt_stat.items())),
        "generated_code": sorted(r["path"] for r in code if r["generated"]),
        "classes": dict(sorted(classes.items())),
    }


def render_report(rows: list[dict], root: Path, context: str) -> str:
    s = summarize(rows, context)
    lines = []
    lines.append(
        f"code inventory: {s['files']} files discovered and mapped "
        f"({s['code']} code, {s['noncode']} non-code) under {root}"
    )
    lines.append(
        "discovery context: "
        + (
            "git checkout — ignore rules skip untracked noise only; "
            "tracked files are never concealed"
            if context == "git-checkout"
            else "git-free source — ignore rules inert; every present file is "
            "repository source"
        )
    )
    lines.append("families: " + ", ".join(f"{k} {v}" for k, v in s["families"].items()))
    lint = s["lint_status"]
    fmt = s["format_status"]
    lines.append(
        "lint policies over code files: "
        + ", ".join(f"{k} {v}" for k, v in lint.items())
        + "  (pending rows are debt owned by #278 S2-S4, not coverage)"
    )
    lines.append(
        "format policies over code files: "
        + ", ".join(f"{k} {v}" for k, v in fmt.items())
    )
    if s["generated_code"]:
        lines.append("generated code rows: " + ", ".join(s["generated_code"]))
    lines.append(
        "non-code classes: " + ", ".join(f"{k} {v}" for k, v in s["classes"].items())
    )
    # The two #264 extents, reported independently as the issue requires.
    hs = [r for r in rows if r["kind"] == "code" and r["family"] == "haskell"]
    active = [r for r in hs if r["lint"] == "hlint-offchain-active"]
    debt = [r for r in hs if r["lint"] == "hlint-offchain-debt"]
    fmt_active = [r for r in hs if r["format"] == "fourmolu-offchain-active"]
    fmt_conf = [r for r in hs if r["format"] == "fourmolu-conformance"]
    conf = [r for r in hs if r["lint"] == "hlint-conformance"]
    lines.append(
        f"haskell extents reported independently: hlint active {len(active)} "
        f"files / debt-pending {len(debt)} files (13 #264 directories) / "
        f"conformance-pending {len(conf)} files; fourmolu house-config "
        f"active {len(fmt_active)} offchain files / {len(fmt_conf)} "
        f"conformance files, no exclusions"
    )
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def export_tree(root: Path, rows: list[dict], dest: Path) -> None:
    dest.mkdir(parents=True, exist_ok=True)
    for r in rows:
        src = root / r["path"]
        out = dest / r["path"]
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, out)


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument(
        "--root",
        default=".",
        help="tree root to inventory (default: current directory)",
    )
    ap.add_argument(
        "--json", action="store_true", help="emit machine-readable rows on stdout"
    )
    ap.add_argument(
        "--export-tree",
        metavar="DIR",
        help="after a complete inventory, copy every mapped file "
        "into DIR (used by the controls; the copy carries no "
        ".git, proving the walk needs none)",
    )
    args = ap.parse_args(argv)

    root = Path(args.root).resolve()
    if not root.is_dir():
        print(f"inventory: root is not a directory: {root}", file=sys.stderr)
        return 2
    try:
        manifests = parse_manifests(root)
        files, context = walk_tree(root)
        if not files:
            print("inventory: discovered an empty extent — refusing", file=sys.stderr)
            return 1
        rows, findings = classify(root, files, manifests)
    except (InventoryError, GitignoreSyntaxError) as exc:
        print(f"inventory: {exc}", file=sys.stderr)
        return 2

    problems = self_check(rows)
    exit_code = 0
    for f in findings:
        print(f"inventory: unmapped or unknown file — {f.render()}", file=sys.stderr)
        exit_code = 1
    for p in problems:
        print(f"inventory: registry problem — {p}", file=sys.stderr)
        exit_code = 1

    if args.json:
        print(
            json.dumps(
                {
                    "root": str(root),
                    "summary": summarize(rows, context),
                    "rows": sorted(rows, key=lambda r: r["path"]),
                },
                indent=2,
                sort_keys=True,
            )
        )
    else:
        print(render_report(rows, root, context))

    if exit_code == 0 and args.export_tree:
        try:
            export_tree(root, rows, Path(args.export_tree))
        except OSError as exc:
            print(f"inventory: export failed: {exc}", file=sys.stderr)
            return 2
    if exit_code != 0:
        print(
            f"inventory: FAILED — {len(findings)} unmapped/unknown files, "
            f"{len(problems)} registry problems",
            file=sys.stderr,
        )
    else:
        print("inventory: PASS — every discovered file is mapped")
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
