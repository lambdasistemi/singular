# Modules: who knows what a configuration output is

Issue 799. Follows [the plan](plan.md). Fields are in [the data model](data-model.md) and signatures in
[the functions model](functions-model.md).

## Responsibilities

| Module | Responsibility after this change |
| --- | --- |
| Fold library (`Singular.State.Fold`) | discovery accounts for requests and for holders that look like requests; it asks the application description whether an output is configuration and holds no other idea of it |
| Open datum fold description (`Singular.Application.OpenDatum.Requests.Fold`) | answers the question for open datum from the request address and the configuration decoding that the booking reader uses |
| Command line state commands | unchanged: they print the skipped list the library returns |

## Dependency direction

The open datum package depends on the fold library; the library depends on no application. The new question lives in the
description record the library already owns, so no new module and no new dependency edge appears. The configuration
decoding stays where it is, in the open datum records module.
