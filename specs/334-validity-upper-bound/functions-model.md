# Functions: signatures that change

Issue 334. Follows [the data model](data-model.md).

The window arguments the booking builder already takes (a lower and an upper slot) become arguments of the update builder, the
termination booking builder and the creation builder, or are computed inside them from the session they already receive. The
choice between the two follows the surrounding builders and is recorded in the commit owner's decision record; the plan fixes
only that no builder gains a second source of time.

Unchanged: the reconciliation functions, the bundle and journal records, and every refusal.
