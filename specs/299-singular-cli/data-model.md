# Changed data decisions

DM299-COMMAND: command discriminant create/insert/terminate/inspect; public registry path, node socket, network magic, evidence path; key bytes for entry operations; explicit seed and private key-file input for create/write. Help and public identity preview have no submission effect. Validation distinguishes malformed key, unsafe/partial settings and inconsistent identity.

DM299-CONFIG: versioned public saved identity: network/magic, registry token and seed, chosen existing open application, compiled blueprint/script/policy identities, required references and public wallet binding. Configuration contains no signing secret. Existing config/state cannot be overwritten by create. DM299-STATE is stored separately.

DM299-STATE: versioned authenticated concrete trie state plus registry identity, commitment and last-known confirmation/chain point. The local state is usable only after commitment/identity agree with a fresh ledger query. Pending/partial outcomes remain distinct from confirmed state; mutation cannot silently reconcile stale/concurrent state.

DM299-RECEIPT: public command/registry/key/network/pin identity, actual submitted boot/publication/request/fold txids, confirmation points, current ledger state reference/datum/root, token/holding/burn/custody/payment observations, read/proof mechanism/freshness and attributable outcome. Observed ledger facts, locally derived proof and model expectations are separate. Missing fields/effects remain unknown/partial, never supplied from expectations. Receipts exclude secrets and cannot cause automatic resubmission.

DM299-ERROR: client validation/refusal, ledger acceptance/refusal, unavailable node, timeout, stale/concurrent identity/root and partial execution are distinguishable. Unobserved ledger reason remains unobserved.
