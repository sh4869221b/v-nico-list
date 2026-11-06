# Design

The port separates command/input/output decisions from API collection and transport. [COMPATIBILITY.md](COMPATIBILITY.md) defines runtime boundaries; [VALIDATION.md](VALIDATION.md) describes observed evidence.

| File | Responsibility |
| --- | --- |
| `src/config.v` | Flag parsing/defaults, explicit concurrency tracking, duration/date/config validation |
| `src/main.v` | Input sources, target scheduling, aggregate results, JSON/line output, summary and exit precedence |
| `src/domain.v` | Target matching, strict JSON values, user/mylist page decoding, RFC 3339 timestamps, filtering and numeric ID comparison |
| `src/client.v` | Page fetching, retry orchestration, first-page discovery and ordered pagination results |
| `src/control.v` | Shared admission, dispatch pacing, adaptive feedback, metrics, structured logging and streaming deduplication |
| `src/transport.v` | Bounded HTTP/1.1 framing, verified TLS, HTTP proxies/CONNECT, redirects, gzip and request deadlines |
| `src/tls.v`, `src/native_tls.h` | Cancellable TCP reads and Mbed TLS I/O callbacks during handshake and record reads |
| `src/native.h` | Signal/cancellation flag and checked flushed stdout writes |

## Command lifecycle

The main thread validates configuration, creates per-command control state and starts an input producer. Positional arguments are followed by file/stdin lines; file/stdin use bounded raw reads, and input events distinguish a present empty positional argument from EOF. The scheduler admits target workers according to the fixed target limit or adaptive budget, while continuing to collect completed results. It does not preallocate a worker pool from the full possible input size.

Buffered modes aggregate per-target results. Default output sorts combined IDs numerically; JSON additionally sorts target records by type and numeric target ID. JSON with `--no-sort` restores input order for combined items. Per-target IDs preserve page order. Unsorted line output writes completed target batches as they arrive and shares one deduplication map when requested. All JSON strings are validated before stdout encoding so invalid UTF-8 cannot leave partial JSON.

Output errors stop scheduling and trigger shared cancellation. Input read failures do the same, even under best-effort mode. Signals set the native atomic cancellation flag; workers and waits observe it. Fetch cancellation/deadline results follow the Go baseline's successful-empty convention. Input/output errors and strict invalid inputs still determine their documented exit precedence.

## Collection and request admission

Each target fetches page 1 before deciding whether later pages may run concurrently. Missing totals and fixed page concurrency 1 use sequential natural termination. Known totals allow bounded parallel page scheduling. Completed pages are retained by page number; the earliest failed, empty or 404 page determines the committed prefix. Higher completed pages never jump across a failed lower page.

Target workers, page schedulers and retries share one command control object. A short mutex protects admission counters, the next permitted dispatch time and adaptive state. Requests commit rate permission and HTTP admission together; a queued request cannot carry an old pacing grant across an adaptive cooldown. Admission remains occupied through response body handling and is released before retry waits. Pending target/page supply contributes to adaptive demand rather than requiring idle workers to exist in advance.

Adaptive mode starts with HTTP/worker budget 8, or a smaller positive explicit HTTP cap. Explicit settings independently fix the selected layer. Healthy supplied windows may increase the budget; sustained latency/retry pressure decreases it. A 429 establishes command-wide cooldown, and recovery dispatches are paced. State belongs to one command and does not persist or issue probe requests. Decision history is bounded; timing and diagnostics differ from Go's runtime.

When a rate or minimum interval is configured, a second gate spaces actual GET writes after connection setup, including redirects. This prevents uneven DNS/TCP/TLS setup time from compressing separately admitted requests into a burst. The gate checks cancellation and the request deadline, and anchors the next write after the preceding write completes. Neither control mutex stays locked during network I/O; existing admission and HTTP-cap accounting remain in place.

## Transport and bounded parsing

Transport uses V TCP/TLS with explicit certificate/hostname verification. HTTP proxy absolute-form requests and HTTPS CONNECT are selected from inherited environment settings, with explicit NO_PROXY matching. Each connection has an I/O watchdog for cancellation/deadlines and closes after one request. Redirects share the same attempt deadline and re-evaluate the destination/proxy settings.

Plain TCP reads use short deadline slices and recheck the command cancellation flag. The default Mbed TLS backend uses those reads through callbacks installed before the handshake, retaining V's certificate configuration and hostname verification. This also handles systems where local socket shutdown does not wake an existing readiness wait. One request thread owns the TLS context throughout; the watchdog never closes or mutates it, and fatal TLS errors are not retried on the same context. OpenSSL retains V's connector. Final cleanup belongs to the transport owner.

Headers/framing, encoded gzip, decoded response bytes and JSON nesting are bounded separately. Gzip expands through a callback that refuses bytes beyond the 8 MiB successful-body limit. Strict JSON parsing rejects duplicate object names, malformed UTF-8 and invalid numbers; typed page conversion validates the API fields and timestamps before filtering. The initial synchronous DNS/TCP dial remains an explicit cancellation/timeout boundary described in the compatibility notes.

## Diagnostics and verification

Machine-readable data belongs only on stdout. Structured log events go to stderr or the requested logfile, with operational summary/progress on stderr. The metrics event contains aggregate counters/statuses/timings and optional adaptive state, excluding request URLs and response content. It does not promise the Go `httptrace` schema.

Focused V unit tests check parsing/control/transport helpers. Python black-box contracts exercise the executable against real loopback HTTP/TLS sockets, including timing, concurrency, malformed data and early shutdown. An unchanged Go reference launcher validates common fixture expectations. Benchmarks use the same fixture and verify result equality before comparing wall times; they support no live-service performance claim.
