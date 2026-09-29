# Insertion carries the envelope: protected control, arbitrary payload

Three operator answers from 29 September 2026 settle what an application insertion delivers and what the datum it carries may contain. The model on this branch is bound to root main a0770318, where a delivered output carries a datum only when its request names one, and where a fold that delivers nothing describes no destination output ([#304](../304-destination-row-presence/ruling.md)).

## Alice's inserted token carries her envelope

As Alice, I want my inserted token's application output to carry its envelope inline, so that my chosen payload and protected controller, registry, key and deposit fields are present where I will update or terminate it.

- **Operator answer, verbatim:** "isn't it obvious from story 1 ?" This is a clarification of the existing story, not a new optional behaviour.
- **What was wrong:** an insertion request's datum flag defaults to naming none, and the application's booking did not require it. The registry would then deliver the token with no datum, while the application recorded an envelope.
- **Now:**
  - A booking whose request names no datum is refused `app-envelope-datum`.
  - The fold's selection refuses a pending insertion naming none, `fold-envelope-datum`, before the registry folds anything.
  - A reached insertion's registry holding carries its datum inline (`insertion_holding_inline`).
  - Termination is unchanged: it names no destination, the root describes no destination output for it, and the token it burns is spent from the output carrying the inline envelope.

## The initial key value

- **Operator answer, verbatim:** "Initial key value".
- **Meaning:** an application's approval policy is where the value first assigned to an inserted key is validated. This application is permissive about it: every valid Plutus payload is admitted, with no initial-value predicate and no fixed initial payload.
- **What is still validated:** the protected envelope (version, controller, registry, key, deposit) and the destination and datum binding.
- **What does not change:** the generic registry, its genesis configuration and its commitment. The registry commits a key's lifecycle; the payload lives in the application's envelope.

## Protected envelope, arbitrary payload

- **Operator answer, verbatim:** "Keep the protected envelope with arbitrary payload".
- **The datum's shape:** the complete application datum has a required shape — the protected control (controller key, registry state asset, active policy, key and deposit) beside a payload. The payload is any valid Plutus data, with no required fields.
- **What an update may change:** the payload only. The controller key is a control field, so a payload update cannot change it, and it cannot change the token, the contract or the deposit floor.
- **What this rules out:** the datum is not an arbitrary unrestricted value, and the controller and deposit are not moved outside it.
