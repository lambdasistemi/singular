# Data and state model

As a registry user, I receive the same transaction and wire behavior after
this maintenance change. No domain field, relationship, validation rule,
state transition, or encoding is changed.

| ID | Invariant | Severity |
| --- | --- | --- |
| I264-1 | Public exported module set and executable names equal the intake baseline. | ADVISORY |
| I264-2 | Layout-only source edits preserve signatures, strictness, imports and behavior. | BLOCKING if an edit reaches chain state, money or signature; otherwise ADVISORY |
| I264-3 | The lint command rejects malformed source in a newly included active directory and passes after it is removed. | ADVISORY |
| I264-4 | Every affected component builds; missing CI coverage remains reported as a gap. | ADVISORY |

There is no new data abstraction or altered Lean obligation. Source and build
checks support maintenance claims only; they do not establish transaction
behavioral correspondence.
