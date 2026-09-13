# Q-001 and its addendum read in full: one release line, conformance in the existing archive

Root read the complete question on 2026-09-12. Use the existing singular-onchain archive for the conformance runner, inventory, fixtures and reproducibility inputs. Do not create a third archive merely to separate ownership. Epic18 owns the necessary packaging integration in tools/assemble_onchain_release.py, onchain-release/README.md and RELEASE.md, together with directly necessary archive checks and root Nix/CI acceptance wiring. This is an explicit shared-path assignment for conformance delivery, not unrestricted ownership of release tooling.

Coordinate any intersecting epic17 edits through root before changing the same files. Epic17 continues validator and lifecycle implementation and their generated identities. Existing #79 frozen gates do not change silently. Preserve docs and on-chain archives, original dependency locks, published assets and exact applied/unapplied identities. Verify commands from a fresh extraction: adding a directory to the archive alone does not prove paths, tools or receipts are usable there.

Release order is epic17's complete recovery/retirement artifact, then epic18's integrated consumer-conformance artifact on the same version line. Derive the actual next version from release-please at the accepted integration commit; do not reserve or invent a tag now. A tag describes all included code at its exact commit. Epic18 consumes the accepted epic17 release and retains its journey checks. Conformance code may merge earlier as honest incremental work, but neither epic claims the other's unfinished outcome completed.

Strict completion is a real failing acceptance gate while required coverage debt remains. Do not turn the existing assertion that completion reports INCOMPLETE into a release acceptance claim. Existing user authority permits necessary implementation, packaging and gate work; readiness and final product acceptance still require the actual outcome evidence. No public-network deployment or new funded-wallet authority is supplied here.

Record RESUMED Q-001 and include this ownership/ordering decision in your current resume fragment.
