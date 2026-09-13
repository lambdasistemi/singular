# NOTE-134 native compaction receipt

Observed by the epic owner after Pi's manual compaction completed at
`2026-09-13T00:47:53.946Z`.

- pane: `%994`; process PID `4182517`; start ticks `149071436`
- process command remained
  `/nix/store/iwgllsbcsalpqms30i4xn56dcpg99zdl-pi-0.84.4/libexec/pi/pi --provider zai --model glm-5.3-flash --thinking max --approve`
- cwd remained `/code/singular-e18-exec`; no child command was present
- same native session ID and file:
  `01a09695-c87b-725c-9576-c0d6e9231e3c`,
  `/home/paolino/.pi/agent/sessions/--code-singular-e18-exec--/2026-09-12T17-06-33-723Z_01a09695-c87b-725c-9576-c0d6e9231e3c.jsonl`
- session header remained version `3`, same ID and cwd; native file inode
  remained `5540768`
- Pi appended exactly one entry: type `compaction`, ID `440753a3`, parent
  `c071e56a` (the precompact last entry), `firstKeptEntryId=657be0be`,
  `tokensBefore=848760`, summary length `20232`
- compaction usage: input `674138`, output `10934`, reasoning `7014`, total
  tokens `685072`, cost `0.05329385`
- postcompact native history: `1,869` lines, `4,120,149` bytes, SHA-256
  `b227b1ccf63003bd004d25c0b0d1d262857cd086a4fea0cdf1ce851e5af7563e`
- immutable precompact snapshot remains `1,868` lines, `4,093,723` bytes,
  SHA-256
  `b8ce005a5242f3d4c280dd7402a8b8b1d2d26fdddccf742d30e70783d46172a9`
- Pi UI reported `Compacted from 848,760 tokens`; no `/new`, reset, fork,
  restart, model/provider/effort change, source edit or task execution occurred
  during the compaction boundary

Continuity passed. The only next input is the compact packet
`../inbox/NOTE-036-note134-compacted-one-file-resume.md`.
