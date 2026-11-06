# Implementation review

Reviewed on 2026-11-06. Astra planned and reviewed the port; GPT-6.1 Sol implemented the CLI/domain/control, HTTP transport, tests and documentation. The baseline is go-nico-list commit `6638228b9acfa6256805f5e57bdd75f4ca80e084`. Its MIT copyright notice is retained.

## Review outcome

No unresolved implementation findings remain from this review. The reviewed source `f693080` passed native Linux and Windows CI, with the explicit compatibility boundaries in [COMPATIBILITY.md](COMPATIBILITY.md). This is not a claim of identical internals, diagnostics or performance, or verification on other platforms.

The review checked CLI parsing and explicit concurrency overrides, JSON shape and strict decoding, source/input ordering, Unicode and malformed input, filtering and numeric sorting, ordered partial page results, adaptive supply accounting, global pacing, retry deadlines, verified TLS and CONNECT, bounded HTTP/gzip framing, cancellation, output failures and native integer widths.

Corrections included preserving fixed HTTP overrides in adaptive mode, distinguishing successful-status body failures from retryable transport errors, draining closed V channels correctly, handling EOF and short stdin reads, keeping unordered output memory free of unused result/deduplication collections, preserving missing versus negative totals, propagating input/output cancellation, using atomic cancellation and a size_t output length, and retaining the summary when JSON output fails.

The final pass also reproduced and fixed overflow for tiny positive rates, extreme Retry-After values and near-maximum HTTP timeouts. Waits and monotonic deadlines now saturate safely; wall-clock duration arithmetic avoids overflowing intermediates. The new regression cases failed the preceding binary and passed the corrected one. This deliberately fixes defects beyond the pinned Go baseline rather than preserving them.

Native Windows execution then exposed CRLF checkout conversion, pacing compressed by uneven connection setup, and cancellation blocked in socket readiness waits. Sol reproduced the latter two conditions independently on Linux; Astra reviewed the fixes and the C callback ABI, context ownership, certificate/hostname verification, deadlines and cleanup. The final write gate retains existing admission and spaces redirect GETs too. TCP polling and Mbed TLS I/O callbacks keep handshake and read cancellation observable without retrying a failed TLS context or closing a socket from the watchdog. `.gitattributes` preserves LF, and partial compiler clones retain all three exact pins; a fresh bootstrap succeeded. Before/after evidence is linked in [VALIDATION.md](VALIDATION.md).

## Executed checks

- Final Linux OpenSSL production binary: SHA-256 `4c5f20d029db658e1e877c6261e262ca658b9f50cf166264379c3e805865f562`. The separate Mbed TLS build and all commands/hashes are in [post-ci-validation.json](provenance/post-ci-validation.json).
- V unit tests: 31 functions across 4 files, passed with both backends locally and in native Linux/Windows CI. See the [CI evidence](provenance/github-actions.json).
- Final Linux production integration: 55 passed with OpenSSL and 55 with Mbed TLS against synthetic loopback HTTP/HTTPS/proxy servers.
- Some retained successful integration logs include Python fixture disconnect tracebacks during deliberate cancellation/TLS rejection; the relevant tests and complete suites passed. Raw output is preserved.
- Unchanged Go baseline: initial adaptive-growth assertion failed once; three focused repeats and one complete rerun passed. The complete rerun passed 47 with the same 8 documented exclusions. The original failure is retained and the timing-sensitive comparison is disclosed in [VALIDATION.md](VALIDATION.md).
- Formatting, Python compilation, shell syntax and workflow YAML checks passed.
- [Native CI run 42152349163](https://github.com/sh4869221b/v-nico-list/actions/runs/42152349163) passed on both operating systems. Linux passed all 55 integration tests and the benchmark smoke check; Windows built with MSVC, passed 49 tests and skipped 6 POSIX signal contracts.
- Four final five-sample process benchmarks checked identical results. V took 1.64–3.22 times the Go median in these workloads. Full measurements and limitations are in [VALIDATION.md](VALIDATION.md).

Both the existing Go working tree and the separately cloned reference working tree remained clean. No live niconico requests or load tests were performed. The source repository excludes binaries, toolchains, caches and generated test certificates.

## Remaining boundaries

V's synchronous DNS/TCP dial can delay cancellation until that phase returns. Prolonged blocked-write cancellation was not independently characterized. There is no HTTP connection pool or HTTP/2, HTTPS-scheme proxies are unsupported, and diagnostics differ from Go. Additional encoded-body/framing/JSON-depth bounds are documented. These are known implementation differences and test boundaries.
