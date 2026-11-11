# Combined parser validation

This combines the independently reviewed allocation changes and one-pass strict
escaped-string decoder. There are no new production optimizations in this stage.
Local branch `perf/parser-hot-paths` starts from allocation HEAD `caf41a8` and
cherry-picks escaped commits `6f4fe88` and `9e24b07` as `08a1b87` and
`2e491a6`. One mechanical insertion-point conflict was resolved by retaining
both helpers, unchanged. Byte-for-byte composition checks are recorded in
[composition.txt](provenance/parser-combined-20261111/composition.txt).

All performance measurements below are synthetic local Linux/GCC tests using V
`67011350d000d86c3fc2a925b505c590dbfdea88`, production compilation and Boehm GC.
They do not measure live Niconico, native Windows, Go, or physical RAM usage.
No builds or tests ran concurrently with timed measurements. Ratios are direct
ratios of medians from the same paired experiment, not products of stage ratios.
Sample ranges are descriptive, not confidence intervals.

## Decoder impact after allocation fixes

Nine alternating-order samples per fixture, each with 20 warmups and 250 timed
parses. Exact full JSON tree and Page checks precede measurement; every timed
sample verifies the final Page. ASCII and literal-Unicode cases are unescaped
controls. Unicode and escaped fixtures have identical decoded values.

| 100-item full fixture | Allocation-only ms | Combined ms (range) | Ratio | GC bytes change |
| --- | ---: | ---: | ---: | ---: |
| user-ascii-full-100 | 2.176 | 2.059 (1.943–2.288) | 1.06× | -0.00% |
| user-unicode-full-100 | 2.121 | 2.076 (1.975–2.340) | 1.02× | -0.00% |
| user-escaped-full-100 | 4.679 | 2.429 (2.128–3.120) | 1.93× | -23.19% |
| mylist-ascii-full-100 | 1.781 | 1.685 (1.531–2.121) | 1.06× | 0.00% |
| mylist-unicode-full-100 | 1.855 | 1.765 (1.658–2.340) | 1.05× | 0.00% |
| mylist-escaped-full-100 | 4.154 | 2.261 (2.055–2.497) | 1.84× | -23.18% |

Escaped pages improved materially (1.84–1.93×), with about 23.2% fewer cumulative
allocator bytes. There is no observed raw-path regression: all four control
medians are slightly faster, but their small differences are not an independent
optimization claim. Earlier decoder microbenchmarks found greater sparse-string
allocation; this combined full-page test does not negate that workload-specific
tradeoff. It does not cover every escape distribution.

## Original main versus combined

Original main is exactly `1f518b8385cbba51f1b57d6048de17b77d57fdbe`, tree
`c0e13139ed4556fcfa2e7e674eae574d06edf132`. Nine alternating samples, 10 warmups
and 25 timed parses per sample, reusing hashed exact binaries. The smaller batch
bounds the slow original parser. Combined sample durations in this comparison
are short; the longer preceding A/B supplies a separate stability check.

| 100-item full fixture | Main ms | Combined ms | Direct ratio | GC bytes reduction |
| --- | ---: | ---: | ---: | ---: |
| user-ascii-full-100 | 39.855 | 1.780 | 22.39× | 99.183% |
| user-unicode-full-100 | 38.457 | 1.755 | 21.91× | 99.183% |
| user-escaped-full-100 | 52.396 | 2.411 | 21.73× | 99.260% |
| mylist-ascii-full-100 | 38.442 | 1.719 | 22.37× | 99.181% |
| mylist-unicode-full-100 | 37.753 | 1.678 | 22.50× | 99.181% |
| mylist-escaped-full-100 | 53.502 | 2.174 | 24.62× | 99.259% |

GC figures are Boehm cumulative allocator-accounted bytes, including transient
allocation/reallocation and rounding. They are not allocation counts, retained
data, RSS, peak/live memory, or proof of equivalent CPU savings.

## Complete CLI: exact main versus combined

Fresh main and combined binaries use identical GCC `-prod -d use_openssl`
production flags. No API concurrency/rate settings changed. The existing
`scripts/benchmark.py` runs one warmup then seven alternating repetitions for
each of eight cases: four targets, three pages/target, 100 items/page, JSON or
lines, minimal or extended payload, and 0 or 10 ms response delay. The
`--payload extended` option is this driver's full metadata workload. Each
process verifies exact complete output against the independent expectation and
other binary, and exactly 12 HTTP requests. This is whole-process wall time
including startup, loopback HTTP, parsing, sorting and captured output.

| Payload / output / delay | Main median ms (range) | Combined median ms (range) | Ratio |
| --- | ---: | ---: | ---: |
| extended-json-0ms | 170.92 (145.32–180.03) | 36.67 (32.93–43.65) | 4.66× |
| extended-json-10ms | 188.19 (176.06–222.10) | 55.12 (53.42–62.53) | 3.41× |
| extended-lines-0ms | 174.04 (152.73–226.13) | 37.40 (31.85–42.04) | 4.65× |
| extended-lines-10ms | 177.74 (163.66–206.36) | 53.32 (46.66–59.48) | 3.33× |
| minimal-json-0ms | 27.98 (23.59–30.54) | 19.86 (17.61–41.34) | 1.41× |
| minimal-json-10ms | 44.22 (42.61–46.62) | 36.92 (34.64–40.59) | 1.20× |
| minimal-lines-0ms | 31.69 (29.75–32.52) | 22.08 (19.19–25.38) | 1.43× |
| minimal-lines-10ms | 47.66 (44.49–55.59) | 39.86 (36.27–45.40) | 1.20× |

These small loopback workloads support a real end-to-end improvement, strongest
with extended metadata. They do not identify the fraction of time spent in each
stage. Synthetic latency, local server behavior, startup and concurrent work
limit extrapolation. No CPU attribution is inferred by subtracting parse and CLI
times; no process CPU profile was collected.

## Conditional follow-on proposals

Defer all three from this PR:
- **Waiting/worker overhead:** admission polling and coordinator timeouts remain,
  but there is no measured material scheduling bottleneck. Changing wakeup and
  cancellation lifecycles without evidence adds risk. If large-target workloads
  become slow, first collect CPU/wakeup profiles while holding concurrency,
  response payloads and rate limits fixed.
- **Output-lock separation:** `emit_items` still holds the control mutex while
  bounded batches are emitted. These benchmarks capture stdout promptly and do
  not test a slow consumer, so they cannot establish contention. First instrument
  lock hold/wait and a deliberately throttled output sink; preserve bounded
  backpressure, deduplication, cancellation and partial-write accounting.
- **Typed direct parsing:** a generic tree still materializes unknown fields, but
  current parse-only cost is around 2 ms for these 100-item pages after removing
  the dominant known waste. No remaining tree-cost CPU profile establishes a
  priority. First profile parse CPU/allocations on representative sanitized
  payloads, then consider a strict differential prototype only if material.
  Unknown-field validation, duplicate names, Unicode, number grammar and dates
  must retain the same rejection semantics.

Recommended publication scope, if separately authorized: parser benchmark
infrastructure, accepted literal/array/date allocation changes, strict decoder
and contract tests, and measurement documentation. Do not add worker/output-lock
or direct-parser rewrites. Native Windows validation remains pending; Linux
MbedTLS is a second Linux backend check, not Windows validation.

## Reproduction and evidence

[Evidence directory](provenance/parser-combined-20261111) includes raw samples,
source/driver/compiler/binary hashes, exact-main source-tree identity, commands,
and validation logs. Retained binary manifests include their absolute local
paths; these are provenance, not portable download links. Production source
hashes, rather than a later documentation-only HEAD, identify measured code.

## Final correctness validation

On the unchanged combined production source:
- V format verification for src and parser harness: passed.
- Python fixture/type-equality tests: 2 passed; Python compilation checks passed.
- All V unit files: 8/8 passed with OpenSSL and 8/8 with Linux MbedTLS.
- Full CLI integration suite: 65/65 passed on each backend.
- Parser smoke: all six four-item fixtures, exact Page and full decoded tree,
  passed using the retained combined binary.
- CLI smoke: Linux MbedTLS passed; OpenSSL is covered by all eight full A/B cases.
- `git diff --check`: passed.

There were no test failures or measured regressions requiring a repeat. Native
Windows compilation and integration have not been run for this combined branch.
Nothing was pushed, published or merged remotely.
