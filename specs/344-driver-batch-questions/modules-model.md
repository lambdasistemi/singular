# Keep the driver the only translator

As a maintainer, I want the batch questions inside the existing driver, transport and story responsibilities.

## Responsibilities

```mermaid
flowchart LR
  MO[Singular.Model] -->|Laws, unchanged| DR[Singular.Driver]
  ST[Singular.Statements] -->|Preservation proofs| DR
  DR -->|Surface and answers| TR[DriverTransport]
  DR -->|Corpus| consumer-resolution[check_model and constitution table]
  SL[Story language] -->|Batch instructions| EX[Live executor]
  EX -->|Questions| TR
```

The model owns the laws and stays unchanged. The driver owns the batch questions, their outcomes and observation extents; nothing outside it composes `foldBatch`, `obligations` or `settle` into an answer. The transport only carries questions. The story language owns the instructions; the executor owns submission and the question it asks. Dependencies keep this direction.
