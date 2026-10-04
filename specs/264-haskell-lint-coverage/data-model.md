# Data and state model

As a registry user, I receive the same transaction and wire behavior after
this maintenance change. No domain field, relationship, validation rule,
state transition, or encoding is changed.

## Preserved state and evidence

| ID | Invariant | Severity |
| --- | --- | --- |
| public-exported-module-set-executable-names-equal | Public exported module set and executable names equal the intake baseline. | ADVISORY |
| layout-source-edits-preserve-signatures-strictness-imports | Layout-only source edits preserve signatures, strictness, imports and behavior. | BLOCKING if an edit reaches chain state, money or signature; otherwise ADVISORY |
| lint-command-rejects-malformed-source-in-newly | The lint command rejects malformed source in a newly included active directory and passes after it is removed. | ADVISORY |
| affected-component-builds-missing-ci-coverage-remains | Every affected component builds; missing CI coverage remains reported as a gap. | ADVISORY |

There is no new data abstraction or altered Lean obligation. Source and build
checks support maintenance claims only; they do not establish transaction
behavioral correspondence.
