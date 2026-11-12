# Large results and slow output

This follow-up starts from main `b0bfd057485c88d8a0caa71c6bbbffd92c4e103e`
(after PRs #1–4). It measures the remaining large-result retention and blocked
stdout concerns before deciding which production changes to keep.

## Measurement method

`scripts/benchmark_results.py` runs the actual production CLI against a local
HTTP fixture. It checks every output byte for sorted lines, every JSON field,
and contiguous, page-ordered target blocks for `--no-sort`. It also verifies the
exact request multiset. Synthetic IDs are unique across targets even above
1000 pages; each page deliberately returns IDs in descending order.

The workloads contain 60,000 or 300,000 IDs, with either 3 or 30 targets, 100 IDs
per page, and `-T4 -P4 -H8 --retries=1 --no-progress`. Concurrency, retry policy,
rate limits and connection-reuse defaults are not tuned. HTTP is loopback,
without TLS or injected response delay. Fast output goes to a temporary file,
without fsync. Slow output is a pipe drained in 4096-byte chunks at a configured
256 KiB/s, starting after 250 ms; sleep/scheduling overhead makes this a target
rate rather than an exact throughput guarantee.

Each sample uses a fresh process. Paired runs alternate binary order after one
warmup. The kernel's `wait4` provides per-CLI peak RSS and user/system CPU time.
A fresh, minimal native supervisor forks/execs the CLI, excluding the growing
Python fixture/validator's inherited pre-exec RSS floor. The supervisor itself
is not included. A sanity experiment with `/bin/true` demonstrates why direct
Python `wait4` is misleading: allocating 64 MiB in Python raised the apparent
child maximum from 17,388 to 82,924 KiB, while the supervisor measurement stayed
at 384 KiB. These are peak resident-set measurements, not allocator totals or
live-memory attribution.

Wall time covers process startup through exit; the slow sink's tail drain and
validation are outside that interval and are recorded separately. Server
completion timestamps follow response-body flush and handler completion; they
are not client parse/HTTP completion times. CPU sums can exceed wall time
because the CLI is multithreaded. No claim is made about live Niconico, Windows
performance, Go comparisons, or the percentage of CPU spent in any component.

Source/compiler/binary hashes, raw samples, commands, rejected trial patches,
and test evidence are retained in [provenance](provenance/large-results-20261112/).

## Result retention trial

The isolated trial moves sorted-line concatenation into the target-completion
loop and retains per-target arrays only for JSON. It leaves all JSON behavior
and `--no-sort` behavior unchanged. A new contract checks line/JSON parity with
out-of-order completion, repeated targets, invalid input, partial failure,
deduplication, URL rendering and best-effort status. Both baseline and trial pass.

**Decision: rejected.** The production retention path remains unchanged. The
trial passes compatibility but does not establish a reliable memory improvement.
The matrix used one warmup plus seven measured runs per binary/case, alternating
order (128 processes including warmups). All exact output and request checks passed.

Sorted-lines medians:

| IDs / targets | Baseline RSS MiB | Trial RSS MiB | Baseline wall ms | Trial wall ms |
| --- | ---: | ---: | ---: | ---: |
| 60,000 / 3 | 54.77 | 47.25 | 479.0 | 456.8 |
| 60,000 / 30 | 30.83 | 55.20 | 417.6 | 478.0 |
| 300,000 / 3 | 87.51 | 86.99 | 2268.7 | 2209.1 |
| 300,000 / 30 | 120.24 | 119.60 | 2545.5 | 2417.3 |

At 60,000 IDs / 30 targets, RSS rises 79.1% and median wall time rises 14.5%.
At 300,000 IDs the RSS changes are below 0.6%, despite small wall-time changes.
The apparent 60,000-ID / 3-target RSS improvement also occurs in the unchanged
JSON control (about 14% in both), so it cannot be attributed to result retention.
JSON control RSS changes range from approximately -19% to +6.7%; small RSS
differences here are not stable evidence of an optimization. No specific GC
mechanism or allocation hotspot is claimed from these process metrics.

`memory-only.patch`, `memory-manifest.json` and `memory-ab-*.json` preserve the
rejected experiment. `benchmark_results-memory-trial.py` is its exact harness;
the current harness subsequently gained exception-safe cleanup and verified
binary-manifest loading. Those changes do not alter the recorded normal-path
trial measurements. The baseline remains the comparator for the output fix.

## Output-control independence

The baseline holds the HTTP-control mutex while writing stdout. A full pipe
therefore blocks other targets' HTTP completion, admission, cancellation checks
and scheduling. The Linux regression fills a known-capacity pipe without
reading, then releases another target's gated response. Its next-page request
cannot arrive on baseline until stdout is drained. This uses events and pipe
occupancy, not a sleep chosen to manufacture a particular completion order.

The fix keeps whole-target output serialization and its dedupe/count/
error state on a separate mutex. A write failure takes the control mutex only
briefly to set the stop flag, then signals cancellation. Lock ordering is output
then control; there is no reverse acquisition. There is no new writer thread or
queue, and target concurrency continues to bound completed results waiting for
output. Final output-state reads occur only after every target worker reports
completion.

This does not make a permanently unread stdout pipe interruptible. It separates
HTTP progress from stdout backpressure; it does not promise prompt SIGINT exit
from a blocked native write. Logging still uses the control mutex, so blocked
stderr/logfile output is a separate limitation.

### Paired output-lock measurements

One warmup and five alternating measured repetitions per variant/mode; 144
fresh CLI processes including warmups. Every output and request check passed.
The 60,000-ID cases include sorted-lines, JSON and fast `--no-sort` controls;
the 300,000-ID cases include fast and slow `--no-sort` controls.

Slow-pipe medians (seconds and MiB):

| IDs / targets | Last server response, baseline → fix | CLI wall, baseline → fix | Peak RSS, baseline → fix |
| --- | ---: | ---: | ---: |
| 60,000 / 3 | 1.864 → 0.467 | 2.716 → 2.743 | 54.70 → 46.67 |
| 60,000 / 30 | 2.475 → 2.214 | 2.554 → 2.549 | 38.80 → 30.34 |
| 300,000 / 3 | 10.406 → 2.170 | 14.624 → 14.669 | 71.32 → 71.46 |
| 300,000 / 30 | 12.453 → 11.253 | 12.903 → 12.846 | 104.86 → 136.69 |

With 3 targets (all fit within `-T4`), final server response time falls 74.9%
at 60,000 IDs and 79.1% at 300,000 IDs. Fast-sink response controls stay near
0.42/0.41 seconds and 2.03/2.00 seconds respectively. With 30 targets, ordinary
target/output backpressure remains and final-response improvement is about 10%.
This is the intended bound, not an unbounded background fetch queue.

**Tradeoff:** at 300,000 IDs / 30 targets, slow-output peak RSS increases
from 104.86 to 136.69 MiB (+30.4%), while its fast-output control stays near
104.4–104.6 MiB. Allowing HTTP collection to advance while completed targets
wait for serialized output can retain more results at once. The source bounds
waiting targets by target concurrency, not by a fixed byte budget; arbitrary
large targets can still consume substantial memory. The measurement does not
prove how much of the RSS increase is live results versus GC/runtime behavior.

End-to-end slow-output wall changes range from -0.4% to +1.0% and remain
sink-bound. Fast/sorted/JSON controls do not establish a general throughput gain.
Some control RSS results also vary substantially, so there is no memory-reduction
claim for this fix. It is retained for demonstrated HTTP-control independence,
with the measured memory cost exposed for review.

The deterministic tests complement the timing: a deliberately full pipe cannot
prevent the other target from requesting its terminal page, and a broken pipe
releases both the current emitter and the target waiting to emit. Contiguous
whole-target output, cross-target deduplication, exact bytes and counts remain
validated. See `output-lock-summary.json` and raw samples for CPU, ranges,
per-target timing, binary manifests and canonical output hashes.

## Scope decisions

Worker reuse, notification-based HTTP admission and a typed-parser rewrite are
not included. Aggregate process CPU and wait times alone do not establish that
these more invasive changes are needed. Global concurrency, adaptive thresholds,
429 handling, timeouts, cancellation conventions and HTTP transport are unchanged.

## Local validation before publication

- V format verification and Python syntax checks passed.
- OpenSSL: 8/8 V unit files, 66/66 integration contracts, and 3/3 output-concurrency contracts passed.
- Linux MbedTLS: 8/8 V unit files, 66/66 integration contracts, and 3/3 output-concurrency contracts passed.
- The original baseline intentionally fails the two Linux gated full-pipe tests; its concurrent target-output/dedupe test passes. The candidate passes all three without relaxing the blocked-pipe condition.
- Parser fixture tests and parser/CLI/large-result benchmark smokes passed.
- Benchmark fixture/cleanup tests cover exact output, 300,000 unique IDs, timeout/interruption reaping, signal-before-child-publication, and `-P1` terminal pagination.
- Native Windows behavior is covered by the PR's Windows/MSVC CI, not by these local Linux runs. The two pipe-capacity tests are Linux-only; concurrent output/deduplication runs on both platforms. No Windows speed or RSS claim is made.

The workflow runs these contracts and tiny benchmark correctness smokes, never
a performance threshold. All recorded speed/RSS measurements are local Linux
observations, separate from the native-platform CI results reported on the PR.
