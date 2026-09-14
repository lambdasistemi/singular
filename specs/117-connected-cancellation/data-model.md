# Data constraints

D01: pending registration associates an Insert request with its naming claim and
approval, and authenticates the proposal's committed refund address. The accepted
model is NamingLifecycle.cancelNamingClaim at the revision in spec.md.
D02: cancellation consumes the approval and claim, disposes of the associated
request under the existing generic lifecycle, and preserves records/root.
D03: four-field NamingDatum and current InsertApproval lack that refund/request
association. Exact representation and any authorization change await an operator
ruling; no format is chosen by this planning record.
