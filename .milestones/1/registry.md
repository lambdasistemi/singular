# Singular M1 contract registry

Snapshot 2026-10-28T17:00Z (main d69ab005 plus later merges; release 0.17.0, pre-release). Rows changed by the registry without pinned policies (#731) are restated; the 2026-10-09 wording of a changed row is kept under "was".

contract:   the fold between the Singular state and an application
parties:    Singular, one state validator per application, `state(application policy)`: genesis, and the fold that, per change, consumes the application's approval for exactly that change, checks the key's trie proof, and mints or burns one token for the key; applications (open datum now, cardano-keri next) own the request, its approval, its spending phases and all money
invariant:  a pending registration or termination is foldable by anyone from chain data alone; Singular routes no money and moves nothing else under the state policy; the registry never interprets the application's datum
enforced:   the state validator and the open-datum validator on chain; the packaged create, register, update and terminate journey, the registration and termination refusals on a devnet, and the conformance devnet rows in hosted CI. The independent two-actor journey and the negative host were retired with the old command line; porting them is #764.
was:        the request format between the registry and every application; enforced by the request validators and the two-actor devnet journey (PR 421)

contract:   the application boundary of the command line
parties:    `singular` (registry create, wallet create, address and sign, submit); the `open-datum` executable (create, insert, fold, reclaim, cleanup, update, terminate); ckeri
invariant:  the registry executable carries no application code; application binaries link the Singular library and accept its flag group unchanged
enforced:   package dependency direction since #528 (closed 12 October): the open-datum package depends on the Singular library and its command-line component, and the Singular packages do not depend on open datum. No separate hosted gate is named.
was:        NONE until issue 528 lands

contract:   request admission (tag, bond, forfeit)
parties:    retired
invariant:  retired on 2026-10-26: requests belong to the application and carry its approval token; Singular mints no request tag and has no rejection
enforced:   not applicable; #529 and #498 closed as not planned

contract:   fold batch capacity
parties:    the fold builder; folders
invariant:  the folder knows from measurement how large a batch the target network accepts, for registrations, terminations and mixed batches
enforced:   NONE; measured limits are #746. General capacity work (#530) is in the tooling milestone.

contract:   Lean as behavioral authority for every layer
parties:    lean/, onchain/, offchain/, conformance/
invariant:  code that contradicts clear Lean is repaired; ambiguity is escalated as a user story
enforced:   constitution; model-check, simulator-check and conformance rows in CI

contract:   the ledger assumption behind the history guarantees
parties:    the Singular state model (#741); the M1 release (#747)
invariant:  the history guarantees (a live token exists exactly when the key's leaf is active; a burn happens only in a terminating fold; no re-mint after termination) assume Cardano's script-execution rule
enforced:   NONE by decision of 2026-10-26: published as a stated limit of the M1 release; the ledger-level proofs (#676, #679, #680) are in the assurance milestone

contract:   cardano-keri as the first external application
parties:    singular library and model; cardano-keri (ckeri commands, checkpoint validator)
invariant:  ckeri registers and terminates through the application's requests and the Singular fold; parked and reopen are application-output transitions the registry never sees
enforced:   model level only: cardano-keri's Lean is pinned to the merged Singular main (cardano-keri PR 484, 28 October). ckeri does not link the Singular library yet, and the KERI-shaped stub journey was retired with the old command line (#764).

contract:   CLI-managed local state (#485) and the public replay checkpoint (#493)
parties:    #485 managed state (wallet partitions); #493 replay cache (moved to the tooling milestone); every replaying command
invariant:  wallet partitions hold only a wallet's own journal and pending files; a public replay partition holds only data derived from public chain history, is never an authority and is deletable at no cost
enforced:   not re-established for the 0.17.0 commands; the earlier control belonged to the old line's address-free inspect, which has no successor until #744
