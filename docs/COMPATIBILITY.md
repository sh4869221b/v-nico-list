# Compatibility and transport boundaries

The target is the current Go CLI at [`6638228b9acfa6256805f5e57bdd75f4ca80e084`](https://github.com/sh4869221b/go-nico-list/tree/6638228b9acfa6256805f5e57bdd75f4ca80e084). This is a source port, with a different runtime and HTTP implementation. [VALIDATION.md](VALIDATION.md) records executed checks; a prepared CI job is not evidence that a platform passed.

## Preserved contracts

The current flag names/defaults, uppercase concurrency shorthands, repeated last-value semantics, explicit adaptive overrides, validation and removed-name rejection are covered by black-box tests. Input sources, partial URL extraction and user precedence, UTC date filtering, exclusive comment threshold, numeric ID sorting, deduplication, line/URL output, complete JSON arrays/schema and per-target errors follow the baseline.

Invalid inputs are skipped unless strict mode is enabled. Strict invalid-input failures precede best-effort handling. Successful targets and ordered successful page prefixes survive fetch errors. Input/output/configuration failures are not suppressed by best-effort mode. Buffered cancellation/deadline behavior follows the baseline: the affected target becomes a successful empty result.

The baseline's `--retries` name means maximum **total attempts**, including the initial attempt. The value must be at least 1. HTTP 200 and 404 are terminal; other HTTP statuses and non-deadline transport errors retry. Retry sleeps release admission; 100 ms exponential backoff is capped at 30 s, with longer 429 `Retry-After` delays honored. Every dispatch, including a retry, shares global pacing and the HTTP cap.

Page 1 precedes the remaining pages. Unknown totals always stay sequential to empty/404, including adaptive mode. Fixed page concurrency 1 also continues sequentially regardless of a known total. Parallel known-total scheduling respects page and HTTP limits and returns only the prefix before the earliest failed/terminating page, even if higher pages already completed. The three mylist total-count locations (`mylist.totalCount`, `mylist.totalItemCount`, `data.totalCount`) are supported in that priority order.

Adaptive state is per command. Explicit target/page/HTTP values fix only their layer, including values equal to defaults and an explicit uncapped HTTP value of 0. A 429 pauses new dispatches across the command and recovery is paced. Automatic worker admission uses HTTP feedback; tuning decisions can differ between runtimes and do not guarantee the fastest completion.

## HTTP and TLS

The port implements bounded HTTP/1.1 framing over V `net` and `net.ssl`. Linux builds select OpenSSL with certificate and hostname verification enabled. `SSL_CERT_FILE` supplies an alternate PEM root bundle; without it the TLS backend uses its configured default trust. A proxy tunnel retains verification against the origin hostname. There is no insecure-TLS option.

`HTTP_PROXY`/`HTTPS_PROXY` (or lowercase forms) select **HTTP** proxies; HTTPS origins use CONNECT. Proxy Basic credentials in the proxy URL apply to the proxy, not the tunneled origin. HTTPS proxy URLs, SOCKS, PAC and `ALL_PROXY` are unsupported. Uppercase values take precedence when nonempty. `NO_PROXY`/`no_proxy` supports wildcard `*`, domain suffixes, exact hosts, optional ports, IP literals and CIDRs. Unlike Go's automatic loopback bypass, V requires the applicable `NO_PROXY` exclusion if a proxy is set; the integration runner sets exclusions only for its loopback destinations. Preserve the deployment's proxy and root trust configuration.

Each request creates and closes its connection. There is no connection pool, keep-alive reuse or HTTP/2. These choices can affect throughput and differ from Go's standard transport. Redirects 301/302/303/307/308 resolve relative locations and share the attempt's deadline, with a ten-request redirect limit. Successful decoded bodies are limited to 8 MiB, including gzip expansion, before JSON parsing. Chunked and close-delimited bodies are supported. Encoded gzip bodies additionally have a 16 MiB bound; headers, cumulative chunk framing and trailers have separate 64 KiB bounds. Unsupported content encodings and ambiguous/invalid framing fail the request.

With `--rate-limit` or `--min-interval`, actual GET writes are spaced after connection setup as well as at admission. Redirect GETs share this final write gate. This deliberately prevents bursts after delayed setup and can add waiting within the attempt's timeout; it is stricter than pacing only before the transport call.

Resource/numeric limits are not identical to Go's. The port caps JSON nesting at 512 levels (Go accepts up to 10,000). CLI integer options use the native signed integer range and accept Go-style hexadecimal/octal prefixes. The port rejects nonfinite `--rate-limit` values, while the baseline only explicitly checks for negative values. Error text and acceptance at these resource/nonfinite boundaries can differ.

Extreme positive rate intervals, monotonic wait deadlines and 429 Retry-After delays saturate at the largest representable duration/deadline. They remain cancellable instead of wrapping into an immediate second request or silently disabling pacing. Near-maximum request timeouts use bounded wall-clock arithmetic. These are intentional overflow fixes beyond the pinned Go baseline; its comparison profile excludes the five corresponding V regression tests. An enormous positive rate interval still permits the initial request, then waits until cancellation.

Network I/O and gzip decoding check cancellation/deadlines. V's synchronous name resolution and initial TCP dial do not accept the request cancellation token; cancellation or `--timeout` can be delayed until that phase returns. The loopback tests exercise stalled HTTP/TLS reads and TLS handshakes, including programmatic cancellation from input/output errors. They do not establish bounded DNS/connect latency or prolonged blocked-write behavior on every operating system.

## Diagnostics and platform scope

Results, summary counters and stdout/stderr separation are compatibility contracts. Log wording/progress rendering, version text, detailed error strings and metrics fields are implementation-specific. HTTP metrics summarize the port's available counters, status counts, aggregate request/admission timings and adaptive decisions. They do not reproduce Go's `httptrace` connection-reuse, DNS/TLS phase timings or rolling timing percentiles. Consumers should not parse the Go-specific diagnostics schema from this port.

The runtime uses V, the selected TLS backend and Boehm GC; Python is needed only for validation/benchmarks. No Go toolchain is needed to build or run V. The optional baseline comparison launcher needs Go 1.27 or later and downloads the baseline's dependencies into external caches. Native Windows CI passed with MSVC and V's default Mbed TLS backend: 49 integration cases passed and 6 POSIX signal cases were skipped. Linux OpenSSL CI passed all 55 cases; local production builds also passed with both TLS backends. See [validation evidence](VALIDATION.md). No live API correctness/load run has been performed.
