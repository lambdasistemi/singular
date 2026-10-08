# Fresh recovery results

Permanent broad ref: `preserve/m2-registry-extensions` at
`4301c45d201430fea46080999f5eb8a332a9c8a3`, tree `90a40e60677b326deca23fdce3d6b488be03b5de`.
Its integrated source is the manifest's exact `23964e667fa278b2027d0c05169c0f5e0e9233cb` baseline.
The source snapshot and 22 candidate refs were fetched over HTTPS into an empty
independent repository with no local object alternates.

The [fresh Git receipt](evidence/verification.json) records exit 0;
its [stdout](evidence/verification.stdout) identifies all 22 exact candidate
SHA/tree/ref ancestry checks and 930 baseline/broad blob comparisons.
The [fetch receipt](evidence/fresh-fetch.json) records actual commands and exits;
[publication](evidence/publication.json) records the create-only atomic push
with an empty expected old value for every target, including concurrent creation
protection. No permanent target was advanced or overwritten.

The one fresh `nix run --quiet .#model-check` completed in
19.989 seconds with exit 0, at the broad commit above.
[Command, revision and hashes](evidence/model.json),
[complete stdout](evidence/model.stdout) and [stderr](evidence/model.stderr)
are retained. The recovered checkout remained clean.
The checker reported 46 generic, 7 naming, 9 lifecycle and 5 wire exact identities
using only the standard axioms; 38 corpus, 24 naming and 21 lifecycle rows;
17 single driver scenarios and 12 batch rows. Those are this model check's
reported extent, not validator, consumer or connected ledger acceptance.
No other expensive check was run and no hosted check was rerun.

This evidence is permanently retained separately at
`preserve/m2-evidence/4301c45d-recovery-v2`; the broad ref remains frozen.
To retrieve it after the README's fresh fetch, run:

`git checkout --detach origin/preserve/m2-evidence/4301c45d-recovery-v2`

Then verify the original manifest snapshot with:

`bash specs/504-m2-preservation/verify.sh origin/preserve/m2-registry-extensions`

The current verifier additionally checks the exact manifest blob binding and
each census row claimed retained/reachable. Its final receipt is in the worker
handback/PR because a commit cannot contain its own creation receipt.
[retention-ledger.json](retention-ledger.json) records the exact permanent refs,
owner and cleanup policy for epic507/M1 to consume before independent acceptance.

Remaining limits are consolidated in the README: unclassified histories and
raw owner receipts need original-owner disposition; dirty work stays excluded;
#179/#211 and delete-edge outcomes remain unmet; PR508 stays unmerged and held;
no hosting enforcement is established. No existing release tag/artifact moved.
The evidence-ref commit adds only recovery documentation and receipts, so the
model result stays bound to the unchanged permanently retained broad snapshot.

The original evidence ref `preserve/m2-evidence/4301c45d-recovery` remains
unchanged at `5d7ddb07d0c92d5389c96948555a5add3abaccb2`. The final forward
record uses explicit `-` placeholders for empty census ref fields so its
whole-candidate whitespace check passes; source/ref identities do not change.
The original broad snapshot and its model execution remain unchanged.
