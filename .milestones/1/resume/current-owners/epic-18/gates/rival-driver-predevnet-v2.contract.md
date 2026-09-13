# Rival driver predevnet gate v2

This versioned owner gate supersedes v1 for GREEN admission. V1 and its genuine
missing-module RED remain frozen evidence. V2 retains the complete v1 source,
denominator and shared-runtime requirements and adds the two checks omitted by
the owner from v1.

In addition to all v1 requirements:

- build both `exe:retirement-rows` and `exe:rival-driver-predevnet-check` in the
  same invocation and print SHA-256 identities for both resulting executables;
- execute the offline check once without `RIVAL_OFFLINE_ONLY` and once with
  `RIVAL_OFFLINE_ONLY=0`; each invocation must exit nonzero and emit the exact
  marker `RIVAL_OFFLINE_ONLY=1 required`;
- require the exact later ledger command file to be executable and
  `bash -n` clean before hashing it.

The normal controlled check still runs only with `RIVAL_OFFLINE_ONLY=1` and a
definitely absent socket. It must emit exactly the 22 cases and five mutants
listed in v1. As in v1, GREEN is offline driver evidence and a consolidated
source/build handback only. It does not authorize a node, transaction
submission, devnet run, compositor advance, acceptance, commit, push, merge or
release.
