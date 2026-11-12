# Bounded line output

This report records the original batching change. The later
[output-lock isolation](LARGE-RESULTS.md) keeps these batches but removes stdout
writes from the HTTP-control mutex; the measurements below remain historical.

Line output batches complete records into at most 32 KiB, rather than flushing
stdio for every ID. The final batch is written at each target completion, so
`--no-sort` still delivers completed targets without waiting for other targets.
JSON output is unchanged. In this original change, the control mutex still serialized target
output, deduplication, and counts; no new lock order or unbounded queue was added.
A slow stdout consumer could still block that mutex at this stage.

The native helper returns the accepted byte prefix after looping over short
writes. Counts use logical record-end offsets, not newline counts: IDs may contain
LF, CR, NUL, or Unicode. A failed write marks output failure, cancels requests,
and only counts complete accepted records. These are bytes accepted by the OS,
not a durability guarantee or proof that a downstream reader processed them.
IDs over 32 KiB use the existing single-record fwrite/fflush path. The batch
buffer is capped at 32 KiB; endpoint storage is bounded by the number of records
that fit in that buffer (at most 32,768 one-byte records).

The pinned V runtime's `vlib/builtin/builtin_windows.c.v` calls
`set_stream_binary_mode(C.stdout)` from `builtin_init` (lines 302–303), which
calls `_setmode(fd, _O_BINARY)` (lines 68–72). `_write` preserves that existing
binary descriptor mode. Native Windows CI remains required: Linux tests do not
substitute for a Windows executable run.

## Evidence

Baseline: `b9e211725eb125b8ce7f80a8a8e530b94d27423d`.
Linux production builds with the repository's pinned V compiler and gcc.
One warmup per binary and alternating old/new execution; no concurrent
project builds/tests during measurement. Raw samples are in
`provenance/bounded-output/output.json` and `provenance/bounded-output/cli.json`.

Output-only harness: construct and emit one million IDs / 10,000,000 bytes,
including process startup and ID construction. Temporary-file output uses the
normal OS page cache, without fsync; it is not a durable-storage benchmark.
Seven measured runs per sink:

| Sink | Baseline median | Batched median | Reduction |
| --- | ---: | ---: | ---: |
| Null | 195.6 ms | 111.5 ms | 43.0% |
| Pipe | 332.8 ms | 124.0 ms | 62.8% |
| Temporary file | 335.9 ms | 142.6 ms | 57.6% |

Pipe/file outputs match exactly, SHA-256
`d6781172358e9b6637cd8155894860a4677294db9198b0faf45d9e50e848301b`.
This isolates a useful output-path improvement; it does not establish a general
CLI or live-API speedup.

Full CLI, 12 targets × 20 pages × 100 IDs, zero-delay loopback, five repetitions:
baseline median 316.3 ms; batched 344.6 ms (+8.9%). Samples overlap substantially
and HTTP/process work dominates; this run shows no end-to-end improvement.
Outputs and 240 request counts match. Do not extrapolate the output-only gain.

A separate isolated confirmation with the same CLI parameters and ten measured
repetitions produced 308.44 ms baseline vs 311.65 ms batched (+1.04%). Its raw
samples are in `provenance/bounded-output/cli-confirmation.json`; the original
five-run results are retained. Neither run establishes an end-to-end speedup,
and the smaller second difference does not prove the first difference was only
noise. The demonstrated benefit is confined to the output-heavy harness.

Reproduce the output harness (Linux, Python standard library):

```sh
V=/path/to/pinned/v VMODULES=/path/to/vmodules python3 scripts/benchmark-output.py \
  --baseline b9e211725eb125b8ce7f80a8a8e530b94d27423d --output output-benchmark.json
```

The helper builds a temporary harness from baseline Git source and the current
working source, replacing only the entry point. It runs the same 1M-ID harness,
checks exact output bytes, and records compiler/source/binary identities.

Reproduce the full CLI comparison after building both revisions:

```sh
python3 scripts/benchmark.py --binary old=/path/to/baseline/v-nico-list \
  --binary new=bin/v-nico-list --format lines --targets 12 --pages 20 \
  --latency-ms 0 --repetitions 5 --output cli-benchmark.json
# Repeat with --repetitions 10 for the confirmation run.
```

## Validation

- Format verification and all four V unit-test files passed (35 test functions).
- Full Linux integration suite: 57/57 passed, including target-completion
  streaming and broken-stdout cancellation.
- New batch-boundary/URL/dedupe/40-KiB-ID test and deterministic partial-file-write
  test also pass the baseline binary. They preserve contracts during optimization,
  rather than demonstrate a pre-existing correctness bug.
- Partial output ends mid-record after a successful batch and includes an earlier
  ID containing LF/NUL/CR/Unicode; expected count uses logical byte endpoints.
- Windows native execution is not performed in this Linux workspace.
