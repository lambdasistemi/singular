# Reusable theorem and clause structure

The operator requested that `theorem` and `clause` belong to a reusable library
and that type variables have three or four letters. The registration story now
imports both combinators from `Conformance.Story.Specification`.

```haskell
theorem
    :: Theorem thm
    -> TheoremStory thm act res
    -> Story act res

clause
    :: String
    -> LeanCheck act thm obs
    -> Story act obs
    -> TheoremStory thm act obs
```

`thm` identifies the theorem, `act` its interpreter vocabulary, `obs` the checked
observation and `res` the program result. The generic structure knows no registry
actions or Cardano identities. A domain binding supplies a `Theorem thm` and a
`LeanCheck act thm obs` containing the interpreter action that checks `obs`.
The domain interpreter resolves the theorem's declaration and verifies that the
check names that same declaration before running the clause. These Haskell
indices enforce pairing; the adapter proof and real comparison still establish
the checked behavior.

The registration binding supplies `registrationDelivery` using the
`CheckRegistrationDelivery` instruction. Its existing backend runs the Lean
oracle, normalizes actual output and queried holdings through the same per-run
identity maps, and compares them. Renderer and backend traverse the action,
theorem and clause structures; the renderer also visits the check instruction.

## Checks of the boundary

The valid registration example compiles. A controlled replacement of
`insertActiveRow` with `otherTheorem :: Theorem OtherTheorem`, leaving the
registration check unchanged, fails compilation with `Couldn't match type
InsertActive with OtherTheorem`. Replacing the registration action with
`pure (1 :: Int)` in a story whose registration handle is `String` also fails
compilation. These controls use the same imports and otherwise identical source.

Two committed appendix examples use arithmetic actions instead of registry
actions. One passes the first clause's observed result into a second clause and
requires both checks to run. The other deliberately expects nine after
incrementing one and requires failure before the following action runs.

The public suite passed 133 appendix examples and both live chapters. The
[book](../BOOK.md) records this run, with working-tree basis
`46d5d35616b0601d11e6ad6e0cf4dfbf0ad62743`. Registration delivery agreed with
executable Lean in transaction
`ed0f946688bb5327e3cf2f1a8e57c612274f69bbd6ac6405443fdc24da5ac034`.
The connected retirement consumed the token from its own preceding registration
in transaction `076145ed10975a6d328816a4b37797de963c9ba862d3b22089ff8449f8aa7db9`.
A second real registration deliberately presented the wrong known policy to
the check, keeping quantity one. It failed at the Lean comparison (expected
policy 2, observed policy 1), exit 1. [Both structured observations](generic-run.json)
preserve the actual chain result separately from the deliberately altered input.
The type checks alone do not establish chain behavior or whole-model coverage.

## Remaining text anchors

`conjuncts` still contains literal fragments of Lean statements. Retirement's
`linkedTo` instruction validates their presence in the source before its
registration and retirement actions, and prints them when rendering the book.
The appendix also checks their presence and association with a statement.
These strings are not executable Lean checks. Registration's new delivery clause
does not consume them. Removing the retirement and batch text anchors requires
replacing their current checks with executable Lean comparisons first; that work
is not included in this generic-library extraction.
