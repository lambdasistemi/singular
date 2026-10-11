# A conformance run owns its temporary files

As a conformance operator, I can finish, fail or cancel a suite without leaving
TMPDIR pointing at a deleted directory or deleting another run's files.

- Preserve the exact originally set or absent TMPDIR on success, synchronous
  failure and cancellation. Remove only the directory this lifetime allocated.
- Allocate a fresh directory on every use; preserve a sibling node directory.
- Allocate one explicit owner at executable startup, shared by all sessions.
  Reject nested and overlapping use of that owner before environment effects.
  The callback must join its children before returning; unrelated environment
  mutation while the owner is active is unsupported.
- Keep the existing node entry point isolated. Public CLI, Lean law, script
  identities, row semantics and receipt schema stay unchanged.

Lean binding: `de34300540223ccedf1ca85216b131fd09a148b4` from
`conformance/model-revision`; active Singular.Model law, compatibility Singular.M1
and Singular.Driver judgments. This resource lifetime has no model transition.
Constitution 1.14.0 applies; existing uncovered rows remain uncovered.
