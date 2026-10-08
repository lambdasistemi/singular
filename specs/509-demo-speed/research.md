# Faster confirmation, measured on a private ledger

As a demo operator, I want a transaction that has reached the ledger to be
noticed promptly, without multiplying requests when a transaction stays missing.

The shared confirmation loop now waits one second before its first retry, then
two, four, and at most five seconds. Previously every retry waited five seconds.
The original proposal to poll every second was rejected by a compiled load
control: it made 301 output queries in a five-minute missing-output scenario.
Backoff makes 63 in the same deterministic control. Exact-output identity,
deadline calculation, wall-clock cancellation, and provider-failure distinctions
are retained.

The private confirmation recorder now links the threaded runtime required by
its HTTP server. Its smoke run records 12 actual signed payment submissions and
confirmations, two missing-output timeout controls, the wrong-network refusal,
ten individual follow-on timings, and the provider's raw query trace. This is
harness evidence, not a conformance claim for the registry journeys.

## Measured results

The raw receipts completed with exit zero on both revisions. Values below are
computed from those receipts; machine-readable values and hashes are in
[measurements.json](measurements.json).

| Measurement | Before | After | Interpretation |
| --- | ---: | ---: | --- |
| First signed payment submission and confirmation | 5.1169 s | 1.1170 s | 3.9998 s saved, 78.2% less time; both made two exact-output queries |
| All 12 successful submission/confirmation sections | 11.4452 s | 2.4903 s | 8.9549 s saved, 78.2% less time in these sections |
| Ten subsequent confirmations, total | 6.2004 s | 1.2261 s | Baseline sample 9 needed a retry; all candidate samples were visible immediately |
| Whole smoke, including deliberate timeout waits | 320.37 s | 313.67 s | 6.70 s saved, 2.09%; the five-minute negative control remains |
| CPU, user plus system | 36.03 s | 34.72 s | Observed once; not a general CPU saving claim |
| Peak process RSS reported by GNU time | 278712 KiB | 281084 KiB | Not simultaneous aggregate memory across all child processes |
| Retained run files, logical bytes at collection | 922096 | 957957 | Evidence size; not peak disk use |
| All traced provider queries | 224 | 232 | 3.6% more; includes both timeout controls and preparation |
| Five-minute missing-output queries | 60 | 62 | Bounded increase rather than continuous one-second polling |
| Finite-deadline missing-output queries | 24 | 27 | Starts earlier after the faster successful work; deadline unchanged |

The first payment needed exactly two output queries on each revision, making
its four-second saving the clearest comparison. The baseline's ninth follow-on
payment also retried (5.2137 seconds); every candidate follow-on payment was
already visible at its first query. The larger aggregate difference therefore
includes differing initial visibility, and is not a repeatable speedup estimate.

One pair, sequential on the same shared host, candidate first and baseline
second, GHC 9.12.3 and Cabal `-O0`.
Builds are outside the timings. Both use warm build/dependency caches, the same
locked cardano-node 10.7.0, 0.1-second slots, and private generated genesis.
Host load differed: initial one-minute load was 18.92 for the baseline and 13.80 for the candidate;
other builds and checks were active. CPU/RSS differences are descriptive only.
Peak disk, total simultaneous process-tree RSS, public-provider latency and
whole-demo wall time were not measured. These timings do not establish a whole-demo speedup.

## Revision binding and reproduction

Before: `23964e667fa278b2027d0c05169c0f5e0e9233cb` from `main`, plus
only the identical recorder instrumentation and threaded-runtime repair.
After: `4c52082711b98acea5797b620f3057a55e5d963b`, also based directly on
that `main` revision. Source patches, binary hashes and receipt hashes are retained.
The final code commit `69120979` differs from the measured candidate only in
provider-test formatting; production and recording code are byte-identical.

The original `b70e978a` proposal, the inherited #437-based research branch and
its earlier measurements remain preserved as research evidence. They are not
the source of the table above and are not included in the delivery ancestry.

From each revision's `offchain/` directory, with an unused absolute output path:

```bash
nix develop --quiet --no-write-lock-file --command cabal build -O0 local-services-record
node=$(nix build --quiet --no-write-lock-file --no-link --print-out-paths .#cardano-node)
mkdir -p "$run/tmp"
LOCAL_SERVICES_CONFIRMATION_PROBE=smoke LOCAL_SERVICES_OUTPUT="$run/receipt" \
  TMPDIR="$run/tmp" PATH="$node/bin:$PATH" \
  /run/current-system/sw/bin/time -v -o "$run/time.txt" timeout 600 \
  dist-newstyle/build/x86_64-linux/ghc-9.12.3/singular-registry-0.1.0.0/x/local-services-record/noopt/build/local-services-record/local-services-record \
  > "$run/run.log" 2>&1
```

For the before revision, copy the candidate's
`offchain/test/local-services-record/ConfirmationSmoke.hs` and add only
`ghc-options: -threaded` to its `local-services-record` executable stanza.
Do not copy the production confirmation implementation. The ten sample records
contain trace offsets, so their query counts can be recovered without guessing.

Raw evidence remains at
`/srv/lanes/singular-e371/demo-speed-results/{main-baseline-smoke,delivery-smoke}`;
each contains source identity/patch, binary hash, exit, time, host load, and
the recorder's full trace and receipts. Earlier failed and synthetic runs remain
separate. No secret or public-chain transaction was used.

Both measured workloads and GNU time recorded exit zero. The baseline
non-login shell also exited zero. After the candidate receipts were saved, its
login shell reported exit 127 because its system logout script read an unset
variable under `set -u`. That teardown failure is separate from the completed
workload; it is not represented as a successful outer shell invocation.

## Demo inventory and remaining opportunities

Inventory investigated on `bb134add` and its `offchain/flake.nix` entry
points; the delivery branch changes only shared confirmation and its recorder
and tests on `main`. The legacy journey findings below remain research gaps,
not newly verified journey outcomes on the delivery branch.

| Surface | Finding and disposition |
| --- | --- |
| `confirmTransaction`, used through `capConfirm` / `awaitTransaction` | Implemented and measured at the actual private HTTP/ledger boundary |
| `register-rows`, `recovery-rows`, `retirement-rows` | Compile fails at the removed `registerConsumerImpl`; recovery also lacks package declarations. Their local 2-to-1-second polling proposals were withdrawn |
| `naming-rows` | Compiles; private-ledger pilot rejects `setup-claims` under the pinned application validator before the named rows. Local polling proposal withdrawn; no speedup claimed |
| `journey`, `li01`, `li-refusals`, `insert-active`, `update-terminal` | Use shared confirmation; no measured whole-run saving claimed |
| `repair-rows` | Its 12-second sleep covers an actual processing window; left intact |
| Private facade startup/archive and devnet horizon checks | Already poll at 20/100 ms; left intact |
| Protocol-parameter and history reads | Caching needs a freshness contract; no cache or trust changes made |
| Runtime `-N`, build reuse and concurrency | Potential future measurements; no runtime-capability or parallelism change shipped |
| `tools/demo1*`, CLI backend, root flake and #437 repairs | Remain with their existing owner; untouched |

These are concrete remaining coverage gaps, not passing journey results.
The complete four-journey closure criterion remains unfulfilled; a scope
question was sent to the operator. The operator requested an explanation of
the API removal; no narrowed scope has been approved.

The API removal was intentional in #157, commit
`9cba521fdf244b12bf508ad83c01b193866411cd`: the pinned consumer script and its
mandatory withdrawal were removed, so its stake-registration builder was
deleted. The approved design is in `specs/157-cage-registry-mode/spec.md`.
The stale runner calls are unfinished migration work, tracked by open
[#283](https://github.com/lambdasistemi/singular/issues/283) for register rows
and [#172](https://github.com/lambdasistemi/singular/issues/172) for the derived
consumers and journeys. These commands are not declared retired. A dummy
compatibility alias would conceal the missing migration. The naming pilot's
validator rejection has not been shown to have the same cause.

## Appendix: model mapping and harness verification limits

Lean revision: `bb9c21fa9f09eafb0cf8b69ee2ab3cd010762713`; the measurement and
delivery trees have unchanged model files. `Singular.admittedExitStep`,
`Singular.admittedTxOfExit`, `Singular.retractAdmission` and `Singular.inPhase2`
retain their transitions, signatures and validity rules. This patch observes
the exact transaction output; it does not construct or submit different bodies,
change recipients, custody, token identity, witnesses, or admission. Concrete
transaction identity is outside the model's observation vocabulary; no new
model/ledger equivalence claim is made by a timing result.

The provider control detects both slow first retry and excessive missing-output
traffic. It preserves the exact deadline while checking observation within the
existing five-second polling granularity, rather than requiring the old loop's
accidental overshoot. Added controls keep backend, conflicting-output,
wrong-missing-reference and released-session failures distinct and immediate.

The inherited measurement tree's aggregate was red: 1081 examples, 29 failures,
11 pending, in recovery/CLI integration; root `just ci` reached its documentation
check and failed on missing #437 narration clips. Those failures are not waived.
The isolated delivery tree's full suite passed: 1029 examples, zero failures,
11 pre-existing pending. This does not fill the legacy journey gaps above.
