# JSON and sorting optimization measurements

This change reduces repeated work in JSON parsing and numeric ID sorting. It does **not** change request scheduling, concurrency defaults, pacing, retries, 429 handling, cancellation, transport, output buffering or the CLI schema.

- JSON strings without escapes use the bytes already scanned and UTF-8-validated, instead of decoding the same string again. Escaped strings still use the strict decoder.
- Each JSON object uses its existing value map to reject duplicate decoded names, including names whose first value is null. The extra names map and a page-level map clone are removed.
- Sorting computes the existing normalization key once per ID, then preserves the original length/key/full-ID ordering. Short IDs, nonnumeric suffixes, leading zeros and uint64 overflow retain their previous behavior. This needs an additional O(number of IDs) array of keys; peak RSS was not measured.

## Process A/B results

Baseline: unchanged commit `491059714a9a67c2bd8c867a3eb57d6e37b9a223`. Candidate: the JSON and cached-sort changes in this revision. Both were freshly built with the repository's pinned V `0.5.2 6701135`, GCC and `-d use_openssl -prod` on the same Linux host. [Environment, source and binary hashes](provenance/performance-20261111/environment.json).

Each scenario has one warmup and **10 measurements per binary**, alternating forward/reverse binary order. No builds or tests ran during these measurements. Both use `-T4 -P4 -H8 --retries=1 --no-progress --http-metrics`; JSON scenarios also use `--json`. The server is synthetic HTTP loopback, not niconico. The measured wall time includes startup, HTTP, parsing, sorting, encoding/output and capture.

| Workload | Baseline median | Candidate median | Wall-time reduction | Samples |
| --- | ---: | ---: | ---: | --- |
| 6,000 IDs, JSON, 0 ms response delay | 116.918 ms | 102.235 ms | 12.6% | [JSON](provenance/performance-20261111/json-0ms.json) |
| 6,000 IDs, JSON, 10 ms | 150.607 ms | 140.637 ms | 6.6% | [JSON](provenance/performance-20261111/json-10ms.json) |
| 6,000 IDs, lines, 0 ms | 107.847 ms | 92.416 ms | 14.3% | [JSON](provenance/performance-20261111/lines-0ms.json) |
| 6,000 IDs, lines, 10 ms | 148.481 ms | 135.474 ms | 8.8% | [JSON](provenance/performance-20261111/lines-10ms.json) |
| 6,000 IDs, extended JSON payload, 0 ms | 898.055 ms | 832.538 ms | 7.3% | [JSON](provenance/performance-20261111/extended-json-0ms.json) |
| 60,000 IDs, JSON, 0 ms | 1,109.835 ms | 774.774 ms | 30.2% | [JSON](provenance/performance-20261111/large-json-0ms.json) |

The ordinary scenarios have 12 targets × 5 pages × 100 items; the large scenario has 50 pages per target. All **120 measured process runs** returned the exact expected ID sequence and request count (60 or 600). Complete JSON payloads matched between binaries. Extended responses include known fields, nested unknown objects, long descriptions, quotes and escaped Unicode/surrogate pairs; Python's fixture encoder escapes non-ASCII characters. Raw UTF-8 strings are covered by unit tests.

These are sample medians, not statistical guarantees. Ranges overlap in several short workloads; all individual samples are retained. Aggregate `decode_ns` decreased in each scenario, but it sums elapsed time across concurrent page workers, including their scheduling/GC waits. It is **not CPU time** and must not be subtracted from wall time to construct a phase breakdown. `http_peak` is the fixture's observed handler activity and can include the short interval after a response has reached the client but before handler cleanup.

### Isolating the changes

A separate 9-repeat, 6,000-ID / JSON / 0-ms [ablation](provenance/performance-20261111/ablation-json-0ms.json) measured baseline 106.972 ms, JSON-only 90.342 ms, and JSON+sort 95.033 ms. JSON-only changes reduced the median in that run; the small process benchmark **did not isolate an additional wall-time benefit from sorting**. Its forward/reverse ordering keeps the middle variant in the middle, so the two-binary measurements above are preferred for the complete change.

The [isolated sort benchmark](provenance/performance-20261111/sort.json) measures a deterministic permutation of numeric IDs, with one warmup per process and nine alternating samples. It copies the production `domain.v` / `config.v` from each checkout without editing it, calls the old comparator or the new `sort_ids`, and verifies every output ID. Timing includes key construction, sort and copy-back, excluding input cloning, process startup and assertions.

| IDs | Original comparator | Cached keys | Ratio |
| --- | ---: | ---: | ---: |
| 6,000 | 11.601 ms | 1.636 ms | 7.1× |
| 60,000 | 175.617 ms | 19.792 ms | 8.9× |

This explains the CPU-side reason to retain cached keys, without presenting the microbenchmark ratio as whole-program speedup. Actual input order and ID shape affect the result.

## Reproduce

Build both checkouts with the same pinned toolchain, saving each binary separately:

```sh
V=/path/to/pinned-v/v scripts/build.sh
python3 scripts/benchmark.py \
  --binary baseline=/path/to/baseline/bin/v-nico-list \
  --binary candidate=bin/v-nico-list \
  --repetitions 10 --latency-ms 0 --http-metrics \
  --output /tmp/json-0ms.json
```

Repeat with `--latency-ms 10`, `--format lines`, `--payload extended`, or `--pages 50`, keeping each scenario in its own output file. The existing defaults and output checks remain available; diagnostics and extended payloads are opt-in. No Go binary was rebuilt or remeasured for this change, so the historical Go comparison in [VALIDATION.md](VALIDATION.md) is not a measurement of this candidate.

```sh
python3 scripts/benchmark_sort.py \
  --source baseline=/path/to/baseline --source candidate=. \
  --v /path/to/pinned-v/v --repetitions 9 --output /tmp/sort.json
```

The sort script defaults to GCC; use `--cc msvc` for a native MSVC toolchain. This recorded sort run is Linux-only. Configure V's writable module cache (`VMODULES`) if required by your environment.

## Validation and boundaries

The new unit cases cover raw Unicode/empty strings, legal escapes and surrogate pairs, all raw JSON control bytes, invalid UTF-8/escapes, duplicate null/empty/escaped names, independent nested objects, mylist total precedence and invalid shadowed totals. Cached sorting is compared against the original comparator over edge cases and a deterministic 12,000-ID corpus. The complete suite now has 35 unit functions in four files.

Local format and Python syntax checks passed. All 35 unit functions passed ([log](provenance/performance-20261111/unit-tests.txt)). Final full integration runs passed **55/55 with OpenSSL** in 19.427 s ([log](provenance/performance-20261111/integration-openssl.txt)) and **55/55 with Mbed TLS** in 19.228 s ([log](provenance/performance-20261111/integration-mbedtls.txt)). Native Windows execution is delegated to the pull request CI, not claimed from these Linux runs. One initial OpenSSL integration run failed the fixture's exact HTTP-peak assertion (3 observed handlers for an H2 cap). Transport and admission code are unchanged; the same focused contract passed on both baseline and candidate afterward. The [original failure log](provenance/performance-20261111/integration-initial.txt) is retained rather than counted as a pass. Three further focused runs each on baseline and candidate all passed ([log](provenance/performance-20261111/cap-repeats.txt)). Server handler cleanup occurs after response flush, so handler overlap can exceed actual client in-flight work; this is a possible measurement race, not a proven explanation of that specific sample. The test assertion was not relaxed. See the retained reruns for final outcomes.

These measurements do not establish live API throughput, Go superiority, Windows performance, peak memory, real-network TLS or connection-pool benefits. Output batching and connection reuse remain separate follow-up work. They were deliberately not combined with these CPU changes because output error/count behavior, stale connections, proxy/TLS identity, watchdog lifetime and Windows cancellation need independent tests.
