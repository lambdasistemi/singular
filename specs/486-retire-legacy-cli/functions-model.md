# Functions for retiring the legacy command layer

Issue 486, remainder. Removed signatures only; no new function.

- The needed-references function of each program is deleted with its export. It had no caller outside its own tests, and
  with the booking branches gone it returned the empty set for every command.
- The common-switches list drops the fold switch; the registry parser and the open-datum parser read the remaining
  switches exactly as before.
- Outlay and plan helpers with no production caller are deleted as the compiler shows; the production outlay and refusal
  helpers keep their signatures.
