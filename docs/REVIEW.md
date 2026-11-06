# Implementation review

Reviewed on 2026-11-06. Astra planned and reviewed the port; GPT-6.1 Sol implemented the CLI/domain/control, HTTP transport, tests and documentation. The baseline is go-nico-list commit `6638228b9acfa6256805f5e57bdd75f4ca80e084`. Its MIT copyright notice is retained.

## Review outcome

No unresolved implementation findings remain from this review. This is a reviewed Linux implementation with the explicit compatibility boundaries in [COMPATIBILITY.md](COMPATIBILITY.md), not a claim of identical internals, diagnostics, performance or verified execution on every platform.

The review checked CLI parsing and explicit concurrency overrides, JSON shape and strict decoding, source/input ordering, Unicode and malformed input, filtering and numeric sorting, ordered partial page results, adaptive supply accounting, global pacing, retry deadlines, verified TLS and CONNECT, bounded HTTP/gzip framing, cancellation, output failures and native integer widths.

Corrections included preserving fixed HTTP overrides in adaptive mode, distinguishing successful-status body failures from retryable transport errors, draining closed V channels correctly, handling EOF and short stdin reads, keeping unordered output memory free of unused result/deduplication collections, preserving missing versus negative totals, propagating input/output cancellation, using atomic cancellation and a size_t output length, and retaining the summary when JSON output fails.

The final pass also reproduced and fixed overflow for tiny positive rates, extreme Retry-After values and near-maximum HTTP timeouts. Waits and monotonic deadlines now saturate safely; wall-clock duration arithmetic avoids overflowing intermediates. The new regression cases failed the preceding binary and passed the corrected one. This deliberately fixes defects beyond the pinned Go baseline rather than preserving them.

## Executed checks

- Final production binary: SHA-256 `260525d3fdcaf882d87cc503a4f2404f14e0dc7757b8b9f83892865717261fda`.
- V unit tests: 29 functions across 4 files; final-source rerun passed all 4 files. See [unit log](provenance/linux-unit-tests.txt).
- V integration tests: 53 passed against synthetic loopback HTTP/HTTPS/proxy servers.
- The retained integration log includes a Python fixture `BrokenPipeError` during the hostname-mismatch rejection test: the client closes the rejected TLS connection, and the fixture's read reports the disconnect. That test and the complete suite passed; the raw log is preserved.
- Same integration suite against the unchanged Go baseline: 45 passed; 3 documented proxy-loopback differences and 5 additional V overflow regression methods skipped.
- Formatting, Python compilation, shell syntax and workflow YAML checks passed.
- Windows C generation completed on the final source. No native Windows compiler/executable test or GitHub Actions run was available; the prepared native Windows job remains unverified.
- Four five-sample process benchmarks checked identical results. V took 1.67–3.12 times the Go median in these workloads. Full measurements and limitations are in [VALIDATION.md](VALIDATION.md).

Both the existing Go working tree and the separately cloned reference working tree remained clean. No live niconico requests or load tests were performed. The source repository excludes binaries, toolchains, caches and generated test certificates.

## Remaining boundaries

V's synchronous DNS/TCP dial can delay cancellation until that phase returns. There is no HTTP connection pool or HTTP/2, HTTPS-scheme proxies are unsupported, and diagnostics differ from Go. Additional encoded-body/framing/JSON-depth bounds are documented. These are known implementation differences, not passing claims for untested behavior.
