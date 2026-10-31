# Functions for retiring the legacy command layer

Issue 486, remainder. Removed signatures only; no new function.

- The needed-references function of the open-datum program drops its three booking branches and its fold-flag guards; its
  result for every remaining command is unchanged.
- The common-switches list drops the fold switch; the registry parser and the open-datum parser read the remaining
  switches exactly as before.
- Outlay and plan helpers with no production caller are deleted as the compiler shows; the production outlay and refusal
  helpers keep their signatures.
