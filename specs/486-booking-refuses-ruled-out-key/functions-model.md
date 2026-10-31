# Functions: signatures that change

Issue 486. Follows [the data model](data-model.md).

- a function in the open datum registration command that takes the reader's answer for a key and returns either nothing or the
  refusal to raise; it is pure, so each answer of the table is checked without a chain.
- two constructors of the open datum request refusal type, one for an active key and one for a terminated key, each carrying the
  key as the person typed it, and their rendering in the one place refusals are rendered.

Unchanged: the key reader and its answers, the booking builder and its arguments, the fold, and every other refusal.
