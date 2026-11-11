# Validation and reproducible benchmarks

The test harness uses Python's standard library and synthetic loopback responses only. It never contacts the live niconico API. OpenSSL is used solely to create temporary test certificates.

## Latest optimization measurements

[Opt-in connection reuse](CONNECTION-REUSE.md) records separate local OpenSSL/Mbed TLS validation and HTTP/verified-HTTPS A/B evidence. The native CI and 55/49-test results below refer to their explicitly identified historical revisions, not the new pool changes.

[JSON and sorting optimization results](PERFORMANCE.md) compare the current implementation against the unchanged V baseline on the same toolchain. Six synthetic workloads show median wall-time reductions of 6.6–30.2%; these are not new Go or live-API comparisons. Raw samples, ablation, isolated sorting and validation limits are retained.

## Commands

```sh
V=/path/to/v/v scripts/build.sh
/path/to/v/v fmt -verify src
/path/to/v/v -cc gcc -d use_openssl test src
python3 -m py_compile tests/loopback.py tests/integration.py scripts/benchmark.py scripts/build_reference.py
python3 tests/integration.py --binary bin/v-nico-list
```

Use `--only <substring>` for a focused integration check. Every subprocess and the streaming read watchdog have bounded waits. The fixture records actual requests, timestamps, peak active requests and per-target peaks. Timing assertions allow scheduling tolerance while checking dispatch intervals, backoff, Retry-After, slot release and timeout/cancellation responsiveness. The suite supplies enough work to exercise concurrency bounds rather than merely checking a single request succeeds.

The integration contracts include user/mylist endpoint and header shapes, full JSON schema/empty arrays, target/global ordering, URL matching quirks, args/file/stdin, strict/best-effort precedence, removed flags, repeated mixed shorthand overrides, filters at UTC boundaries, deduplication, unordered streaming, known/unknown totals, parallel partial prefixes, retry timing, global pacing, adaptive cooldown/growth, metrics/logfile separation, invalid JSON/UTF-8/duplicate names/timestamps, redirects, HTTP proxies, CONNECT authentication, certificate/hostname verification, chunking, gzip and decoded-body limits. POSIX SIGINT is skipped on Windows; other contracts run natively there.

## Unchanged Go baseline

```sh
python3 scripts/build_reference.py --source /path/to/go-nico-list --output bin/go-nico-list-reference
python3 tests/integration.py --binary bin/go-nico-list-reference --profile go-reference
```

The builder checks the baseline commit, generates only a temporary launcher, and uses the exported command constructor's `BaseURL` injection point. It does not edit the reference checkout. `--go /path/to/go` chooses a compiler; `GOCACHE`, `GOMODCACHE` and `GOPATH` default to external temporary cache directories if unset. Module integrity verification stays enabled. Toolchain selection defaults to local, so a too-old compiler fails explicitly.

The Go profile excludes the three tests that force loopback traffic through a proxy: Go's standard `ProxyFromEnvironment` intentionally bypasses loopback even with empty `NO_PROXY`. These V-specific tests check its documented proxy behavior; exclusion does not imply Go proxy support is missing. It also excludes five V-specific overflow regressions covering tiny positive rates, near-maximum intervals, HTTP/HTTPS timeouts and enormous Retry-After seconds/dates. The pinned Go baseline's overflow bugs are not compatibility requirements. Other behavioral tests use identical fixtures and assertions.

The overflow tests prove the first request actually dispatched, observe a bounded interval with no second dispatch, then interrupt the process and require prompt successful-empty cancellation. The near-maximum timeout test also requires a normal response to succeed. They do not wait for the enormous duration to expire. These POSIX SIGINT boundary cases are skipped on Windows.

## Process benchmark

```sh
python3 scripts/benchmark.py \
  --binary v=bin/v-nico-list \
  --binary go=bin/go-nico-list-reference \
  --targets 12 --pages 5 --latency-ms 10 --repetitions 5 \
  --output /tmp/nico-benchmark.json
```

Repeat with `--format lines` to include normal line output and its flushing cost; use `--latency-ms 0` for a startup/processing-heavy case or retain 10 ms for a delayed-response case. Keep those scenarios in separate output files.

Each binary receives one warmup plus the requested measured repetitions against freshly started identical servers. The current harness alternates forward/reverse binary order each repetition; historical reports below used the previous per-binary order. Defaults generate 12 targets, 5 pages of 100 items per target and 10 ms server delay per response. Both use fixed `-T4 -P4 -H8`, one attempt and JSON output. The script checks the exact expected ID sequence and identical complete JSON payloads across runs/binaries before recording wall time, request count, observed HTTP peak, output bytes, result/binary SHA-256 and platform/Python metadata. Line-output runs compare the exact ID sequence. It reports the full samples and median/min/max, with no pass/fail speed threshold.

Wall time includes process startup, transport, decoding, filtering, sorting and output capture. The Python server and local scheduler contribute noise. It does not measure peak RSS, CPU cycles, connection pooling benefit on a real network, live API limits, sustained adaptive tuning or Windows performance. A faster synthetic sample is not a production speed claim. CI runs only a small benchmark smoke case.

The fixture listen backlog is 128 and accepted sockets use TCP_NODELAY. This avoids imposing a five-socket Python backlog or Nagle/delayed-ACK penalties on small responses sent over reused Go connections. Both binaries use exactly the same server settings.

## Published-source validation

The reviewed source at [`f693080`](https://github.com/sh4869221b/v-nico-list/commit/f69308085c09e07154458ccecc2dad5c2c635c34) passed [native Linux and Windows CI](https://github.com/sh4869221b/v-nico-list/actions/runs/42152349163). Both jobs passed all four V unit files, containing 31 test functions. Linux passed **55/55 integration tests** in 20.513 s and the benchmark smoke check. Windows built with MSVC and Mbed TLS and passed **49 tests, with 6 POSIX SIGINT cases skipped**, in 25.463 s. [CI metadata](provenance/github-actions.json), [Linux excerpt](provenance/github-actions-linux.txt), and [Windows excerpt](provenance/github-actions-windows.txt) retain the observations.

Initial Windows execution exposed CRLF checkout formatting, compressed dispatch gaps after uneven connection setup, and cancellation waits that depended on local socket shutdown waking a readiness wait. The fixes preserve LF checkout, pace actual GET writes after setup, and poll TCP reads through the Mbed TLS handshake/read callbacks. Certificate and hostname verification remain enabled. [Original Windows failures](provenance/windows-before-fix.txt) and a controlled no-wakeup experiment ([before](provenance/cancel-no-wakeup-before.txt), [after](provenance/cancel-no-wakeup-after.txt)) are retained. New contracts exercise input-error cancellation during a delayed TLS response and a stalled handshake.

Fresh Linux production builds passed **55/55** with OpenSSL in 20.537 s and with Mbed TLS in 20.780 s. [Recorded commands, hashes and environment](provenance/post-ci-validation.json), [OpenSSL log](provenance/post-ci-integration-openssl.txt), and [Mbed TLS log](provenance/post-ci-integration-mbedtls.txt) describe the exact runs. The OpenSSL production binary SHA-256 is `4c5f20d029db658e1e877c6261e262ca658b9f50cf166264379c3e805865f562`; the Mbed TLS binary is `a1cff9e7727721c8078f7545a4f1a623f283b5ce0458f8f501f8eecacd86f206`. Some successful raw logs include fixture disconnect tracebacks when a test deliberately cancels or rejects a connection; the unittest results remain successful.

The unchanged Go reference's first run passed 46, failed the adaptive-growth assertion, and skipped 8. Its budget reacted to observed latency by dropping from 8 to 4 before growing to 5, whereas that contract requires growth beyond 8. The [initial failure](provenance/post-ci-integration-go-first-run.txt) is preserved. Three focused repeats passed, and one full rerun passed **47 with 8 exclusions** in 14.129 s ([log](provenance/post-ci-integration-go.txt)). This suggests timing sensitivity in that adaptive comparison; it is not evidence of an unconditional first-run pass. Both new TLS cancellation cases passed on the initial Go run. The Go checkout and binary were unchanged.

After builds and tests stopped, the four benchmark scenarios were repeated with one warmup and five measurements per binary, the same 12 targets × 5 pages × 100 items and fixed concurrency. All 40 measured samples made 60 requests and returned the expected 6,000 IDs; complete JSON results matched. The common ID-sequence hash remains `ae845394ed60f78467e2ee13915c099d1d6d7d5ebcca3437895d3b3e1ca5ac8b`.

| Output / server delay | V median | Go median | V / Go | Raw samples |
| --- | ---: | ---: | ---: | --- |
| JSON / 0 ms | 167.850 ms | 57.405 ms | 2.924× | [JSON](provenance/post-ci-benchmark-json-0ms.json) |
| JSON / 10 ms | 195.153 ms | 116.667 ms | 1.673× | [JSON](provenance/post-ci-benchmark-json-10ms.json) |
| Lines / 0 ms | 163.696 ms | 50.894 ms | 3.216× | [JSON](provenance/post-ci-benchmark-lines-0ms.json) |
| Lines / 10 ms | 198.089 ms | 120.795 ms | 1.640× | [JSON](provenance/post-ci-benchmark-lines-10ms.json) |

**V remains slower in every measured scenario.** These local synthetic results do not demonstrate a speedup, measure live niconico throughput, or characterize Windows performance. No live API run or published release binary validation has been performed.

## Initial Linux validation

On 2026-11-06, Linux x86-64 (kernel 6.18.57), Python 3.12.14, V `0.5.2 6701135`, GCC 14.2.0 and OpenSSL 3.5.7 were used. The Go launcher used Go 1.27.1 with `GOTOOLCHAIN=local` (the reference requires at least 1.27.0 and requests toolchain 1.27.3). Full machine/compiler metadata, commands, harness hashes and binary hashes are in [linux-validation.json](provenance/linux-validation.json).

Before the Windows transport corrections, source `f637e59` passed **53/53 integration contracts** in 20.673 s: [V log](provenance/linux-integration-v.txt). The unchanged Go reference passed **45 contracts, with 8 documented exclusions** (3 proxy-loopback and 5 V-specific overflow regressions), in 14.060 s: [Go log](provenance/linux-integration-go.txt). The reference checkout remained clean. Python syntax compilation and CI YAML parsing also passed. The initial unit/format checks are recorded separately in [linux-unit-tests.txt](provenance/linux-unit-tests.txt).

The overflow regressions were first run against the old `7796bd44…` binary. The initial four-method run failed 11 subcases; the additional HTTPS timeout case also failed. Near-maximum minimum-interval checks already passed. [Expected failing output](provenance/overflow-before-fix.txt) retains the exact old binary hash and commands. All five regression methods passed on the corrected build. This initial unit suite contained **29 functions across 4 files**, with format and Python/shell/CI syntax checks also passing.

Initial V binary SHA-256: `260525d3fdcaf882d87cc503a4f2404f14e0dc7757b8b9f83892865717261fda`. The following historical benchmark reports use this binary and Go reference binary `550beae026272f5df6f8ea89540d0ee7340773cbadd12df9b8eda00de29e805a`.

All four benchmark scenarios used 12 targets × 5 pages × 100 items, fixed `-T4 -P4 -H8`, one warmup and five measured repetitions per binary. Builds/tests were not running during measurement. Every sample made 60 requests and returned the expected 6,000 IDs. Complete JSON payloads matched between binaries; the common ID-sequence SHA-256 across all formats/scenarios was `ae845394ed60f78467e2ee13915c099d1d6d7d5ebcca3437895d3b3e1ca5ac8b`.

| Output / server delay | V median | Go median | V / Go | Raw samples |
| --- | ---: | ---: | ---: | --- |
| JSON / 0 ms | 180.416 ms | 62.926 ms | 2.867× | [JSON](provenance/benchmark-json-0ms.json) |
| JSON / 10 ms | 211.842 ms | 122.426 ms | 1.730× | [JSON](provenance/benchmark-json-10ms.json) |
| Lines / 0 ms | 170.428 ms | 54.636 ms | 3.119× | [JSON](provenance/benchmark-lines-0ms.json) |
| Lines / 10 ms | 196.046 ms | 117.465 ms | 1.669× | [JSON](provenance/benchmark-lines-10ms.json) |

**V was slower in every measured scenario. A performance improvement over the Go baseline has not been demonstrated.** These are local synthetic process measurements, not live niconico throughput, CPU/RSS comparisons or Windows results. They do not isolate the cost of the transport, scheduler, parsing or output code.

At the initial measurement stage only Windows C generation had been checked. Native Windows verification and the later production measurements are recorded above.
