# Implementation review

Reviewed on 2026-11-06. Astra planned and reviewed the port; GPT-6.1 Sol implemented the CLI/domain/control, HTTP transport, tests and documentation. The baseline is go-nico-list commit `6638228b9acfa6256805f5e57bdd75f4ca80e084`. Its MIT copyright notice is retained.

## Review outcome

No unresolved implementation findings remain from this review. This is a reviewed Linux implementation with the explicit compatibility boundaries in [COMPATIBILITY.md](COMPATIBILITY.md), not a claim of identical internals, diagnostics, performance or verified execution on every platform.

The review checked CLI parsing and explicit concurrency overrides, JSON shape and strict decoding, source/input ordering, Unicode and malformed input, filtering and numeric sorting, ordered partial page results, adaptive supply accounting, global pacing, retry deadlines, verified TLS and CONNECT, bounded HTTP/gzip framing, cancellation, output failures and native integer widths.

Corrections included preserving fixed HTTP overrides in adaptive mode, distinguishing successful-status body failures from retryable transport errors, draining closed V channels correctly, handling EOF and short stdin reads, keeping unordered output memory free of unused result/deduplication collections, preserving missing versus negative totals, propagating input/output cancellation, using atomic cancellation and a size_t output length, and retaining the summary when JSON output fails.

## Executed checks

- Final production binary: SHA-256 `7796bd447fb1b1e2b4b39075e11e102f556f27ede8cb3cbe4812e1236558bc24`.
- V unit tests: 23 functions across 3 files; final-source rerun passed all 3 files. See [unit log](provenance/linux-unit-tests.txt).
- V integration tests: 48 passed against synthetic loopback HTTP/HTTPS/proxy servers.
- The retained integration log includes a Python fixture `BrokenPipeError` during the hostname-mismatch rejection test: the client closes the rejected TLS connection, and the fixture's read reports the disconnect. That test and the complete suite passed; the raw log is preserved.
- Same integration suite against the unchanged Go baseline: 45 passed; 3 explicitly documented proxy-loopback differences skipped.
- Formatting, Python compilation, shell syntax and workflow YAML checks passed.
- Windows C generation completed on the final source. No native Windows compiler/executable test or GitHub Actions run was available; the prepared native Windows job remains unverified.
- Four five-sample process benchmarks checked identical results. V took 1.60–3.25 times the Go median in these workloads. Full measurements and limitations are in [VALIDATION.md](VALIDATION.md).

Both the existing Go working tree and the separately cloned reference working tree remained clean. No live niconico requests or load tests were performed. The source repository excludes binaries, toolchains, caches and generated test certificates.

## Remaining boundaries

V's synchronous DNS/TCP dial can delay cancellation until that phase returns. There is no HTTP connection pool or HTTP/2, HTTPS-scheme proxies are unsupported, and diagnostics differ from Go. Additional encoded-body/framing/JSON-depth bounds are documented. These are known implementation differences, not passing claims for untested behavior.
