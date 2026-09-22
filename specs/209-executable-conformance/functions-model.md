# New interface contracts

These are protocol signatures, not implementation bodies. #221 binds their
concrete model declarations and codecs before the migration in #222 onwards.

| ID | Interface | Constraint |
|---|---|---|
| F01 | runSurface(surface: SurfaceIdentity, scenario: Scenario) -> IO DriverResult | Uses existing model law/observations; structured refusal distinct from execution failure. |
| F02 | loadScenario(corpus: BoundCorpus, scenarioId: ScenarioId) -> Either BindingError Scenario | Validates revision/digests and theorem bindings; no code-side scenario invention. |
| F03 | observeBoundary(context: ExecutionContext, executed: ExecutedOperation) -> IO (Either ObservationError ConcreteObservation) | Uses actual outputs/queries and lookup-only identities; fails for missing/unallocated observations. |
| F04 | compareBoundary(expected: DriverResult, observed: ConcreteObservation) -> Either BoundaryDifference Agreement | Covers the entire declared observable boundary and success/refusal; differences name model fields. |
| F05 | executeScenario(context: ExecutionContext, scenario: Scenario) -> IO ExecutionReceipt | Preserves connected state and identity history, checks each step and records real evidence. |

Existing theorem/clause type safety and shared execution/rendering survive this
migration. Haskell type variables stay 3–4 letters. Changed concrete signatures
are recorded by the ticket owner before dependent implementation begins.
