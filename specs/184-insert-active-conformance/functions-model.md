# #184 — functions model

## Runner entry point

| function | arguments | result | constraints |
|---|---|---|---|
| `runRegisterActiveKey` | `Env` | `IO ()` | Executes the complete register-active-key fold/refusal/control story in the current open-registry session and writes one complete receipt. |

## Receipt validation

| function | arguments | result | constraints |
|---|---|---|---|
| register-active-key edge validator | receipt path and `Receipt` | validated `Receipt` or error | Rejects missing or incomplete register-active-key edge evidence without changing validation for unrelated rows. |

## Existing boundaries retained

| boundary | retained contract |
|---|---|
| row dispatcher | Selecting `register-active-key` reaches `runRegisterActiveKey`; unknown rows still fail. |
| receipt encoder/decoder | The edge field remains optional at the outer receipt level for compatibility and complete when present. |
| generic-row command | The workflow invokes the packaged conformance runner and asserts its receipt directory after execution. |

## No new public production API

This ticket adds no validator, off-chain transaction-builder or Lean API.
Names local to the runner may vary; changing a published signature is a
planning challenge.
