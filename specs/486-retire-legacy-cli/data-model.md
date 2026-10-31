# Data for retiring the legacy command layer

Issue 486, remainder. Types removed; none added; no wire format, receipt or file format changes.

- Removed command values: the singular program's fold value, and the open-datum program's insert, update and terminate
  booking values.
- Removed argument records: the entry record with its fold flag, the fold record, and the create record with its entry mode.
- Kept: the state-create and state-fold records, the holding and booking records of the production commands, the inspect
  record, the wallet, sign and submit records.

Invariant: every constructor of a command type is produced by at least one command line the parser accepts.
