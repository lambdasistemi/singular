# Functions for reading a key from the registry address

Issue 744. New and changed signatures only, as proposals the commit owner may rename to the Lean vocabulary before the
slice that creates them. Records are in [the data model](data-model.md).

| Function | Arguments | Result | Constraints and effects |
| --- | --- | --- | --- |
| a session read of the served network | the session | the network magic, or a read failure | one provider call; no other read precedes it in the reader |
| a total of query work | the trace events of one session | per-read and total calls, rows and bytes | pure |
| application of a state policy | the release table, the state policy | an application identity, or unknown | pure |
| read a key | the session, the release table, the reading request | a conclusion or a refusal, with the query work | one asset query when live; the state and trie reads only when no live token is found; no submission |
| render a reading | a conclusion or a refusal, the output format | human text or JSON | pure |
