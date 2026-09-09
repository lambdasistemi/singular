# Executable design candidate

Singular S1 makes the registry design executable as a logical Lean model and a separately authored browser simulation. This is a **creation candidate**: theorem and inversion statements are deliberately admitted with `sorry`. Building the model checks that the definitions and statements elaborate; it does not prove the statements or accept the design.

## What to review

Follow a representative from a certified pending Insert into an application output, through an application state change, and into a pending retirement or Delete request. While it is pending, the registry remains `Active` but the representative is unavailable to the application. Completion burns it and changes the map. A pending Insert has no representative and requires a separately authorized Withdraw action to cancel it.

The [playable simulation](simulation.md) exposes manual actions and finite model examples. The [model ledger](model-ledger.md) maps each protocol requirement and scenario to modeled behavior, conditions, abstractions or omissions. The [theorem inventory](theorems.md) records the exact admitted statement surface. The [mutation proposals](mutants.md) describe candidate fault coverage; they are not an independent audit result.

The same published candidate includes the [executable Lean source](../model/Singular/Model.lean), [admitted statements](../model/Singular/Statements.lean) and [exported finite corpus](../model/corpus.json). Their identity belongs to this candidate, independently of whether its proofs have been completed.

## Reading the boundary

The model uses logical identities and authenticated state instead of Cardano bytes and MPF proofs. Application authorization is an explicit contract boundary. Recognizing the configured issuer does not establish that an arbitrary application's policy implements the semantics it claims. The [decisions ledger](decisions.md) separates adopted requirements from proposed executable abstractions and unresolved construction choices.

The simulation is a separate author's transcription of the frozen Lean interface. Its [clarity record](LEAN-CLARITY.md) preserves what the formal artifacts did and did not communicate. Finite trace agreement and interactive checks provide bounded creator evidence. They cannot establish universal correspondence, an independent statement audit, proof completeness or ledger deployment conformance.

## Candidate status

The repository carries no deployed Singular validator, completed proof campaign, accepted statement audit or production release. The proof holes are intentional and individually inventoried. The requested review surface is the draft PR and its exact candidate preview; later proof and independent audit stages remain separate work.

Separate blind Fable and Muse source reviews preceded simulator authoring and both recommended proceeding. Their source reasoning did not execute an audit or prove the model. The resulting corpus refinements preserve the reviewed model and statement definitions. A general whole-transition terminal-custody theorem remains an explicit statement-coverage gap in the model ledger.

The original [protocol specification](../specs/protocol/spec.md) remains the behavioral authority. Its statements about unexecuted obligations describe the adopted specification baseline; executable coverage introduced in this candidate is tracked in the model ledger rather than inferred from a successful documentation build.
