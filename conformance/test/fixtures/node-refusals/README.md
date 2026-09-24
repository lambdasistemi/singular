# Node refusal inputs

Source: `A2-failed-probe-live.log`, captured on 2026-09-24 with cardano-node
10.7.0. Log SHA256:
`ea4f1eb4bb404fea5ac0e65fdc7ef5295043dd0d70ad9e243d8e27a9e04a3f09`.
The run used ff88707130ee083ebdf51c0542aa266a23ee4f20 plus the frozen change
subsequently committed as de190651c43a202a78f52a9e517801f3fa235825.

- `budget.txt`: complete node-log rejection from line 69, with the outer
  log string quoting decoded. The full serialized script/context is retained
  to reproduce the diagnostic-volume defect. SHA256
  `87bda11beadcd23b6117ab80dcdfd1c8c005ffacdc1ca557ad52caef14d46c7c`.
- `submit-prefix.txt`: exactly the 4000 characters after `nodeRejection=`
  and before ` declared=` on line 93. SHA256
  `0032e3a48db8dd1146672f7ec1749772e710671024c7fd1b3f28b25ea0a1e1f5`.
- `script-evaluation.txt`: the error field from that line's measured-purpose
  JSON, decoded as text. SHA256
  `2c3c11e03842a3d6c40e26b284a90ab84bd699690ddab08f0fecbecd587abe90`.

The old formatter discarded the ordinary submitted script error's suffix.
It cannot be recovered from these inputs. `Conformance.Fixture.NodeRejection`
therefore constructs a **ledger-constructed** failure using the real Conway
and consensus error constructors and their `Show` instances. Its script/header
and debug bytes come from the node-log budget failure; its CEK cause comes from
the observed evaluation. `Trace: fixture-guard` is deliberately synthetic. The
test requires all 4000 saved prefix characters to match the generated value
before using it to exercise the formatter. It does not claim that the generated
suffix or named trace was returned by the live node.

The formatter tests require both the failure constructor and the cause in the
300-character saved reason and the 4000-character step reason, with script
payloads omitted. Live confirmation of repaired output belongs to the full
conformance gate.
