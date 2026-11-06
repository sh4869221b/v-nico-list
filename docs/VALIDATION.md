# Validation and reproducible benchmarks

The test harness uses Python's standard library and synthetic loopback responses only. It never contacts the live niconico API. OpenSSL is used solely to create temporary test certificates.

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

The Go profile excludes the three tests that force loopback traffic through a proxy: Go's standard `ProxyFromEnvironment` intentionally bypasses loopback even with empty `NO_PROXY`. These V-specific tests check its documented proxy behavior; exclusion does not imply Go proxy support is missing. Other behavioral tests use identical fixtures and assertions.

## Process benchmark

```sh
python3 scripts/benchmark.py \
  --binary v=bin/v-nico-list \
  --binary go=bin/go-nico-list-reference \
  --targets 12 --pages 5 --latency-ms 10 --repetitions 5 \
  --output /tmp/nico-benchmark.json
```

Repeat with `--format lines` to include normal line output and its flushing cost; use `--latency-ms 0` for a startup/processing-heavy case or retain 10 ms for a delayed-response case. Keep those scenarios in separate output files.

Each binary receives one warmup plus the requested measured repetitions against freshly started identical servers. Defaults generate 12 targets, 5 pages of 100 items per target and 10 ms server delay per response. Both use fixed `-T4 -P4 -H8`, one attempt and JSON output. The script checks the exact expected ID sequence and identical complete JSON payloads across runs/binaries before recording wall time, request count, observed HTTP peak, output bytes, result/binary SHA-256 and platform/Python metadata. Line-output runs compare the exact ID sequence. It reports the full samples and median/min/max, with no pass/fail speed threshold.

Wall time includes process startup, transport, decoding, filtering, sorting and output capture. The Python server and local scheduler contribute noise. It does not measure peak RSS, CPU cycles, connection pooling benefit on a real network, live API limits, sustained adaptive tuning or Windows performance. A faster synthetic sample is not a production speed claim. CI runs only a small benchmark smoke case.

The fixture listen backlog is 128 and accepted sockets use TCP_NODELAY. This avoids imposing a five-socket Python backlog or Nagle/delayed-ACK penalties on small responses sent over reused Go connections. Both binaries use exactly the same server settings.

## Recorded runs

On 2026-11-06, Linux x86-64 (kernel 6.18.57), Python 3.12.14, V `0.5.2 6701135`, GCC 14.2.0 and OpenSSL 3.5.7 were used. The Go launcher used Go 1.27.1 with `GOTOOLCHAIN=local` (the reference requires at least 1.27.0 and requests toolchain 1.27.3). Full machine/compiler metadata, commands, harness hashes and binary hashes are in [linux-validation.json](provenance/linux-validation.json).

The frozen V production binary passed **48/48 integration contracts** in 14.690 s: [V log](provenance/linux-integration-v.txt). The unchanged Go reference passed **45 contracts, with 3 documented proxy-loopback exclusions**, in 14.321 s: [Go log](provenance/linux-integration-go.txt). The reference checkout remained clean. Python syntax compilation and CI YAML parsing also passed. Native unit/format checks are recorded separately in [linux-unit-tests.txt](provenance/linux-unit-tests.txt).

Final V binary SHA-256: `7796bd447fb1b1e2b4b39075e11e102f556f27ede8cb3cbe4812e1236558bc24`. The benchmark reports all use this binary and Go reference binary `550beae026272f5df6f8ea89540d0ee7340773cbadd12df9b8eda00de29e805a`.

All four benchmark scenarios used 12 targets × 5 pages × 100 items, fixed `-T4 -P4 -H8`, one warmup and five measured repetitions per binary. Builds/tests were not running during measurement. Every sample made 60 requests and returned the expected 6,000 IDs. Complete JSON payloads matched between binaries; the common ID-sequence SHA-256 across all formats/scenarios was `ae845394ed60f78467e2ee13915c099d1d6d7d5ebcca3437895d3b3e1ca5ac8b`.

| Output / server delay | V median | Go median | V / Go | Raw samples |
| --- | ---: | ---: | ---: | --- |
| JSON / 0 ms | 164.085 ms | 55.243 ms | 2.970× | [JSON](provenance/benchmark-json-0ms.json) |
| JSON / 10 ms | 191.093 ms | 119.755 ms | 1.596× | [JSON](provenance/benchmark-json-10ms.json) |
| Lines / 0 ms | 165.834 ms | 51.002 ms | 3.252× | [JSON](provenance/benchmark-lines-0ms.json) |
| Lines / 10 ms | 194.282 ms | 119.953 ms | 1.620× | [JSON](provenance/benchmark-lines-10ms.json) |

**V was slower in every measured scenario. A performance improvement over the Go baseline has not been demonstrated.** These are local synthetic process measurements, not live niconico throughput, CPU/RSS comparisons or Windows results. They do not isolate the cost of the transport, scheduler, parsing or output code.

Windows CI is prepared but has not run natively. Windows C generation, if recorded by the review, is not native Windows build/execution verification. No live API run or published release binary validation has been performed.
