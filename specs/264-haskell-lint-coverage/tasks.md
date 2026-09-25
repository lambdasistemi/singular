# Ticket tasks

As a contributor, I can review the configuration, formatting and verification
as distinct pieces of one maintenance change.

## Work items

- [x] T264-01 Record the active component/source inventory, exclusions, public exports and command names at intake and candidate.
- [x] T264-02 Remove the duplicate Cabal dependency declarations without changing component interfaces.
- [x] T264-03 Expand the existing lint command to active source directories and prove its rejection with a malformed file in a newly included directory.
- [x] T264-04 Review any required layout-only source changes separately and verify their semantic stability.
- [x] T264-05 Add the classified supported off-chain component build carrier and its CI job; inventory every Cabal component, reject unclassified additions and omitted-classification drift, and preserve distinct #172, #282 and #283 unverified rows with their evidence limits.
- [x] T264-06 Run the applicable active CI commands and new carrier, record actual results, and preserve any remaining gap.
- [x] T264-07 Publish the separate formatter, HLint, inventory and component-build extents; map every retained lint and format gap to final epic integration #278.
- [x] T264-08 Document contributor commands, source/component discovery and current check boundaries in the site navigation with speech coverage.
- [x] T264-09 Demonstrate that the inventory rejects an unknown component and that failure of a selected included component makes the carrier red; restore every control mutation byte-for-byte.
- [x] T264-10 Forward-correct current release and consumer instructions under operator A-011; distinguish verified commands from retained legacy commands and state that already published archives are unchanged.
- [x] T264-11 Enforce the corrected availability with `check_release.py` on the assembled on-chain archive; execute a checksum-valid negative control through the active archive build boundary.
- [x] T264-12 Classify `deployment-attach-check.sh` against required workflows and the carrier closure; preserve any required RED dependency and all #172/#282/#283 repair ownership.
- [x] T264-13 Obtain a fresh independent gate and exact-candidate audit, then run the complete exact-head gate and observe pushed-head CI before ticket handback.

These checked items record the implemented and reviewed #264 slice, including
its bounded 10-built/9-unverified carrier and the corrected contributor guide.
The `b69ecca` Gate S v11 and pushed-head CI, followed by the `e276bab`
documentation correction's Gate S v12 and exact-head CI, completed on the old
main base `2ae29b0`. Main then advanced to `80eba16` with a new accepted Lean
revision. The rebased candidate requires fresh model-bound review, Gate S and
exact pushed-head CI before another ticket handback; the previous receipts are
historical. Epic #272 still needs #278 for all-code lint and format coverage,
and #172, #282 and #283 retain the unverified command repairs.
