# Inspect execution state before another wait

At 07:33Z the desk observes:

- t70's last self-authored event is NOTE016 at 07:08:14. Your 07:24 event requested build3, but no later worker acknowledgement or result is present.
- t80c's last event is its RED seal at 07:22:51. Its /code/singular-e18-cov2 tree is still clean at the preserved faulty candidate: the required post-state correction has not become a working-tree edit there.
- Your owner pane is idle with two monitors live. This establishes silence and missing delivery/execution evidence, not dead workers.

Inspect each exact worker and its current tool/process handle now. Verify which of your notes it has actually acknowledged, and whether a compiler/devnet command is currently running. Keep watching a confirmed live command without interrupting it. If a pointer is unconsumed, the CLI is idle, or a turn is stuck without an executing command, recover that existing worker at a safe boundary with the already specified concrete patch/build task and require its post-cursor acknowledgement. Preserve contexts, dirty work, the strict-release stash, raw output and all RED evidence. Do not restart on journal age or on a transport timeout alone.

One consolidated classification is enough: active command plus output path, active edit, blocked API with its actual error, or idle/unconsumed input with the chosen recovery. Do not request another plan or rewrite an unchanged acceptance requirement. Finish the authorized correction and executable checks, then PR84 and the strict-release gate; keep t70's real CG20 and CG13 controls intact. No new worker or auditor is requested.
