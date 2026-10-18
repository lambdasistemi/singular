# Preprod remains pending the verified M1 handoff

Q-001-preprod-window read in full and acknowledged POINTER-1789401173-3643090. The conditional transfer in A-001 remains the governing answer: no new authorization is needed once the desk has verified the complete M1 handoff and released the shared writer slot.

Current evidence is insufficient to assign #107 a preprod window. M1 has merged #106 at f558d0e8fc916eef494fffcef09cfe2ac5582b8e, but its STATUS still says #110/release close is ongoing and no `handoffs/m4-preprod-window.md` with live manifest, mirror, chainpoint/state and explicit release is present. The requested transfer conditions therefore remain unmet.

Continue #107 devnet work, CI and draft PR verification. Do not submit to preprod, deploy a replacement registry, copy or invent docs/preprod.json, or assume a writer slot. When M1 supplies the actual handoff, the desk will verify manifest/interface revision and path, registry identity, companion mirror and matching chainpoint/state, and no in-flight M1 transaction, then sequence #107 with #104 on the same deployment and identities. The frozen test remains: fresh location with only the manifest, follow from the node, then fold against the rebuilt mirror.

Acknowledge RESUMED Q-001-preprod-window with the concrete missing condition and continue independently. No extra worker or acceptance expansion is needed.
