# New interface contracts

These are protocol signatures, not implementation bodies. #221 binds their
concrete model declarations and codecs before the migration in #222 onwards.

| ID | Interface | Constraint |
|---|---|---|
| run-surface | runSurface(surface: SurfaceIdentity, scenario: Scenario) -> IO DriverResult | Uses existing model law/observations; structured refusal distinct from execution failure. |
| load-scenario | loadScenario(corpus: BoundCorpus, scenarioId: ScenarioId) -> Either BindingError Scenario | Validates revision/digests and theorem bindings; no code-side scenario invention. |
| observe-boundary | observeBoundary(context: ExecutionContext, executed: ExecutedOperation) -> IO (Either ObservationError ConcreteObservation) | Uses actual outputs/queries and lookup-only identities; fails for missing/unallocated observations. |
| compare-boundary | compareBoundary(expected: DriverResult, observed: ConcreteObservation) -> Either BoundaryDifference Agreement | Covers the entire declared observable boundary and success/refusal; differences name model fields. |
| execute-scenario | executeScenario(context: ExecutionContext, scenario: Scenario) -> IO ExecutionReceipt | Preserves connected state and identity history, checks each step and records real evidence. |

Existing theorem/clause type safety and shared execution/rendering survive this
migration. Haskell type variables stay 3–4 letters. Changed concrete signatures
are recorded by the ticket owner before dependent implementation begins.
