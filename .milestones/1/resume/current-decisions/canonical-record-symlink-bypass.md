# Canonical record still permits external substitution at 66da177

Root independently replayed NOTE030 against frozen git archive 66da177f495aea95f26978e9bb45812b3d89d92f. The explicit --record bypass IS fixed: committed incomplete exits 1 and external override exits 3 with unbound release input. A clean sufficient committed regular record exits 0.

However the canonical record path is loaded through the filesystem without binding its resolved contents to committed candidate bytes. A committed symlink at conformance/coverage/record/record.json pointing to an external file leaves HEAD and git status unchanged while that external file changes:

- external contents are valid incomplete record: exit 1 INCOMPLETE;
- external contents are sufficient record: exit 0 COMPLETE.

Same fixture HEAD, same command, clean status for both; only the external target bytes change. This is a proven remaining input-binding defect, not another required auditor or a product coverage result. Do not convert it into mere absence/debt or declare input binding complete on the strength of refusing --record.

Full preserved evidence: /tmp/singular-release-binding-893ez2us/candidate.tar, source/, fixture/, result.json, result-v2.json, sufficient-record.json, incomplete-record.json and all per-run stdout/stderr. result-v2.json is the isolated valid-schema control: the first probe's incomplete record omitted discoveredPopulation and returned malformed-record exit3, and is retained rather than overwritten. v2 fixes that setup error and yields 1 versus 0 through the same canonical symlink. Root pointer: handoffs/release-binding-probe-path.txt.

Complete the already required candidate-input binding for the canonical path too: require the authoritative record and every input capable of changing the completion decision to be approved tracked candidate content; reject external or ignored/untracked resolution, including symlink parents. A regular canonical record committed in the candidate is the simple valid case. Bind bytes to the declared commit or read approved regular blobs from it; a clean working tree alone does not bind ignored files or symlink targets. Do not silently redirect an escaped path and then read its external bytes.

Consolidate the repair with the publication wiring through the current worker. Retain a sufficient positive control, honest incomplete debt control, explicit override refusal, and this exact tracked-symlink substitution control. Check ignored canonical input/parent-path escape as part of the same input-class repair rather than waiting for separate findings. No changes to Lean, no project conformance credit, and #80 remains open.
