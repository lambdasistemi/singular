# Functions: signatures that change

Issue 799. Follows [the data model](data-model.md).

## New

| Name | Arguments | Result | Constraint |
| --- | --- | --- | --- |
| application is-configuration | the output (a transaction output in the current era) | a truth value | pure, total |

## Changed behaviour, same signature

| Name | Change |
| --- | --- |
| discover pending requests | an output the description names as configuration is in neither returned list |
| open datum application | supplies the new field: true for an output at the request script address whose inline datum decodes as a configuration record |

## Unchanged signatures

The pending reader for named requests, the fold builders, the receipt rendering and the skip reasons.
