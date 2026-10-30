# Modules: where the bound is set

Issue 334. Follows [the plan](plan.md).

| Module | Responsibility after this change |
| --- | --- |
| Open datum holding builders (`Requests.Holding`) | the update and the termination booking set the window they are valid in, as the booking builder does |
| Registry creation path | the creation transaction sets its window from the acquired view |
| Recovery reconciliation (`Singular.CLI.Reconcile`) | unchanged: it reads the upper bound a body carries and declares exclusion or death once the tip passes it |

## Dependency direction

The builders read the time conversion of the session they are given; they gain no new dependency. The command layer already
chooses the lower and upper slots for the booking; it chooses them for the other builders through the same helper rather
than a second copy.
