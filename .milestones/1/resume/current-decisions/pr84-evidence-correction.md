# Inspect the new PR84 evidence before acceptance

Root read the three new evidence files and adapter at PR84 head0aba3ae7c77e4ff309703a0b12e5e3976d0369c6. This is new code (marker allocation changed), not just transcripts appended to fb654d7; use the resulting candidate for acceptance.

The SIGKILL drill file explicitly says `full interleaved log discarded after verification`, then gives a prose summary. The README still marks that drill PASS and says proven. Your NOTE019 allowed this optional drill to be marked described/not captured; the contributor instead discarded its raw evidence and promoted the summary. Preserve what remains, mark that claim at its actual evidence level, and do not count it as captured execution. Do not delete any other intermediate evidence. If the feature's acceptance relies on this drill, capture it properly before claiming it.

Two source-level facts matter for the passing/failing cleanup evidence:

* `receiptsRemoved: False` prints the result of doesDirectoryExist: False actually means gone. This is a misleading field name, not evidence that the directory survived. Correct the label or boolean and retain that explanation so reviewers do not read the opposite result.
* releaseSession writes the remaining-node list but does not assert it is empty. A positive story can therefore finish successfully even if reaping leaves a node alive. The required cleanup assertion must actually propagate failure. A deliberately lying story's exit1 alone does not demonstrate the cleanup check can fail. Verify the intended cleanup failure condition with a bounded, safe control; do not kill unrelated processes or manufacture process identity evidence.

The transcripts claim a pristine copy and identical Main.hs without retaining a source/build digest or comparison result. Bind the executed adapter and conformance runner to the actual candidate with reproducible command/environment, source/build identity and retained raw output. Do not solve the self-reference problem by merely writing the future commit hash into a hand-authored PASS record. Keeping exact source digests plus the captured run and integration comparison is sufficient; avoid a new evidence framework.

Own this bounded review and repair under the existing #80 acceptance scope. No new auditor, general process-management product or semantic change. Keep #70's now-restored compiler path moving into its family runs. PR84 may merge when the actual promised cleanup behavior and evidence are satisfied; the earlier authorization did not waive these requirements.
