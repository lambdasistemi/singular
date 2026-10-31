# Modules for retiring the legacy command layer

Issue 486, remainder. Changed responsibilities only; no module is added. Dependency direction is unchanged: the open-datum
program depends on the registry command library, which names no application.

| Module | Change |
| --- | --- |
| the registry command parser | loses the fold value, the entry and fold argument records, the entry mode and the create record; keeps registry inspect, registry create, wallet and submit |
| the registry command runner | loses the arm that refused the fold value |
| the shared flag list | loses the fold switch from the common switches |
| the outlay module | loses the booking, update and fold outlay helpers when the compiler shows no remaining production caller |
| the plan module | loses any helper with no production caller; keeps the JSON reader and the refusal helpers the production commands call |
| the open-datum parser | loses the three booking values, their re-exports and their branches in the needed-references function |
| the open-datum runner | loses the three arms that refused the booking values |

Candidates in the last two rows are confirmed by the compiler, not named here; the census in [the gate](gate.md) lists
what was found.
