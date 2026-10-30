# Functions for the 1.0 release from its installed artifacts

Issue 747. Only new or changed signatures, with explicit argument names. It follows [the data model](data-model.md).

| Function | Arguments | Result | Constraint or effect |
| --- | --- | --- | --- |
| serving answer | table: the packaged release table; observed: the registry's observed contract and release pair | a serving answer | total over every observation; the unknown case names no release; no effect |
| serving text | answer: a serving answer | the lines every command prints for it | the same answer gives the same lines in every command |
| refuse unserved | answer: a serving answer; command: the write command asked for | a refusal before anything is built, or continue | continues only for the case served by this release; no transaction is built for the other cases |
| fill table | table file, state blueprint, application blueprint, project directory, Singular release, application release, archive file | the table with the rows added | existing tool; adds rows, never edits a row |
| installed journey | bundle: the unpacked Linux bundle; scratch: a directory; verdicts: a directory | verdict table, creation measurement, receipt | runs on a path without Nix; exit 0 only when every verdict holds, 3 for a setup failure that is never a verdict |
| decision table | creation receipt, batch receipt | the page's table | every figure read from a receipt; an altered figure makes the check fail |
| compatibility record | table: the packaged release table | the page's rows | computed; a disagreement between the page and the table makes the check fail |
| limits present | notes: the release notes; pages: the documentation | pass or the missing limit | fails when any of the four stated limits is missing |
