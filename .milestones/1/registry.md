# Singular M1 contract registry

Snapshot 2026-10-09T07:26:45Z.

contract:   the request format between the registry and every application
parties:    singular (defines the request: token, owner, key, edge, deposit, submission time, destination address and datum); applications (open datum now, cardano-keri next) supply the approval asset and whatever datum they choose
invariant:  a request is foldable by any party from chain data alone; the registry never interprets the datum
enforced:   cage and request validators on chain; the two-actor devnet journey in CI (PR 421). The datum-size promise to folders is explicitly NONE by ruling of 2026-10-09: the application decides.

contract:   the application boundary of the command line
parties:    singular registry commands; the open-datum executable; ckeri
invariant:  the registry executable carries no application code; application binaries link the Singular library and accept its flag group unchanged
enforced:   NONE until issue 528 lands; today twelve registry CLI modules import the open-datum package

contract:   request admission (tag, bond, forfeit)
parties:    singular request policy and validators; every application's booking
invariant:  a request exists only with a Singular-minted tag; every tagged request has an exit; untagged outputs are anyone's
enforced:   NONE until issue 529 lands

contract:   fold batch capacity
parties:    the fold builder; folders; the protected-rejection rule
invariant:  the fold selects a batch that fits the measured capacity under preprod parameters and names what it leaves
enforced:   NONE; the CI fold-budget regression runs with devnet parameters (ten times preprod's memory). Issue 530.

contract:   Lean as behavioral authority for every layer
parties:    lean/, onchain/, offchain/, conformance/
invariant:  code that contradicts clear Lean is repaired; ambiguity is escalated as a user story
enforced:   constitution; model-check, simulator-check and conformance rows in CI

contract:   cardano-keri as the first external application
parties:    singular library; cardano-keri (ckeri commands, checkpoint validator)
invariant:  ckeri registers and convicts through the registry's request and fold; parked and reopen are application-output transitions the registry never sees
enforced:   NONE; ckeri does not link the Singular library yet. The stub in issue 528 is the first check.

contract:   CLI-managed local state (#485) and the public replay checkpoint (#493)
parties:    #485 managed state (wallet partitions); #493 replay cache; every replaying command
invariant:  wallet partitions hold only a wallet's own journal and pending files; a public replay partition holds only data derived from public chain history, is never an authority and is deletable at no cost; an address-free inspect creates or scans no wallet file
enforced:   #485's control (no local state for an address-free inspect) until #493 replaces it with a no-wallet-file control (desk A-003 to e522, 2026-10-09)
