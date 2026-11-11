# Bounded HTTP/1.1 connection reuse

Connection reuse is **opt-in** with `--reuse-connections` (default `false`).
Without the flag the command retains its previous close-only behavior. Enable it
when reducing connection setup is useful and the stale-socket retry trade-off
below is acceptable. `--reuse-connections=false` disables it again.

When enabled, the command owns a shared idle pool, bounded to 16 sockets in total. Connections
idle for at least five seconds are discarded on the next checkout. All remaining
idle sockets close when the command ends. Active HTTP requests still obey the
existing admission/concurrency limits; idle sockets do not consume permits.

The pool key includes scheme, origin hostname/port, effective proxy URL (including
CONNECT routing and authentication), and `SSL_CERT_FILE` / `SSL_CERT_DIR` settings.
It never shares tunnels across origins. TLS verification remains enabled. Streams
have stable heap addresses because the native Mbed TLS callbacks retain their
address. Each request resets the stream and TCP deadlines and starts its own
watchdog; that watchdog is stopped and joined before the stream can be returned.

Only status-200 HTTP/1.1 responses with a completely consumed, validated
Content-Length or chunked body and successful representation decoding are eligible.
HTTP/1.0, close-delimited bodies, `Connection: close`, non-200 status bodies,
malformed bodies, extra bytes already buffered by the parser or decrypted application bytes
reported pending by the TLS backend,
timeouts and cancellation all discard the connection. Gzip is decoded and checked
before return. Unsolicited bytes arriving after this check are not proactively
polled; no transport can guarantee a peer will remain open after checkout.

## Stale connections and retries

There is deliberately no hidden reconnect/resend. A peer can close an idle socket
without advertising `Connection: close`. A subsequent request on that socket may
fail and consumes one ordinary HTTP attempt, including its normal admission,
GET-write pacing, error metrics and retry backoff. With `--retries 1`, that page
fails; with remaining attempts, the ordinary retry obtains a new socket. The
transport does not increase the configured attempt budget to hide stale failures.
This is a compatibility trade-off compared with always opening a new connection.
Server-advertised close is honored immediately. The five-second idle cutoff limits
exposure, but cannot eliminate this race.

Retry-After, adaptive 429 cooldown, request counts, H/T/P caps, CLI output and
cancellation polling are otherwise unchanged. Non-200 bodies are never drained
for reuse. Calls without a command controller remain close-only.

## Validation and measurement

`src/pool_test.v` tests real socket reuse, lifecycle cleanup, idle capacity and
expiry, pool identity, and rejection of HTTP/1.0, close, unknown framing, unread
bytes, error statuses and truncated bodies. Integration tests count actual
accepted connections for plain/gzip/chunked HTTP, verified HTTPS and CONNECT,
and check stale HTTP/TLS attempt limits plus cancellation/deadline enforcement on
a reused TLS stream. The existing suite covers pacing, concurrency, 429/retries,
proxy routing, certificate validation and stalled-handshake cancellation.

Run `scripts/benchmark-connections.py --binary baseline=/path/to/baseline
--binary reuse=/path/to/reuse --reuse-binary reuse --output /tmp/connections.json` for alternating A/B
runs with an unrecorded warmup. It uses sequential loopback pages, creates an
ephemeral trusted test certificate, verifies all output bytes and request counts,
and records connections/TLS handshakes separately from wall time. It adds no
artificial RTT and is not a live-service or real-network latency claim.

The added reused-TLS deadline test exposed an existing OpenSSL timeout-boundary
race in the pre-pool baseline: a socket timeout could be reported just before the
wall-clock deadline, producing a retryable `net: op timed out` and partial output
instead of the established successful-empty deadline result. The baseline was
observed returning exit 1 with `sm1` after page-two timeout; the reuse build was
observed taking either path before the fix. The accompanying compatibility fix
maps the precise `net.err_timed_out` code to the existing request-deadline code,
and preserves that code through body reading instead of wrapping it as malformed
content. Other network errors and malformed-body errors keep their classifications.
Regression coverage checks both close-only and reused TLS, empty output, exit 0,
attempt/error counters, and refreshed per-attempt deadlines on both TLS backends.

## Recorded Linux results (2026-11-11)

Final opt-in implementation: format check and all five unit files passed with
both OpenSSL and Linux Mbed TLS. The full integration suite passed **63/63** with
OpenSSL (22.725 s) and **63/63** with Mbed TLS (21.690 s). Tests include default
close-only and opt-in paths, cross-worker TLS reuse, and deadlines both before
headers and during a delayed body. [Commands, binary hashes and platform](provenance/connection-reuse/validation.json),
[OpenSSL unit log](provenance/connection-reuse/unit-openssl.txt),
[Mbed TLS unit log](provenance/connection-reuse/unit-mbedtls.txt),
[OpenSSL integration log](provenance/connection-reuse/integration-openssl.txt) and
[Mbed TLS integration log](provenance/connection-reuse/integration-mbedtls.txt)
retain the evidence. **Native Windows validation of these changes is pending**;
the historical Windows CI results elsewhere do not validate this pool.

The final three-condition benchmark used 40 nonempty sequential pages and one
terminal empty page, seven recorded repetitions per condition after warmup,
alternating order, the pinned production compiler, and no concurrent compilation
or test workload. Both TLS variants used the same trusted ephemeral certificate.

| Transport | Old `b9e2117` | Final default | Final `--reuse-connections` |
| --- | ---: | ---: | ---: |
| HTTP median wall time | 29.067 ms | 26.933 ms | 19.016 ms |
| Verified HTTPS median wall time | 97.848 ms | 102.187 ms | 23.714 ms |
| Requests in every run | 41 | 41 | 41 |
| TCP connections in every run | 41 | 41 | 1 |
| TLS handshakes per HTTPS run | 41 | 41 | 1 |

Opt-in versus the same final binary's default reduced these synthetic medians by
29.4% (HTTP) and 76.8% (HTTPS). Default versus old varied by -7.3% (HTTP) and +4.4%
(HTTPS); this small, fast fixture does not establish a default performance win or
statistical equivalence. The stronger result is the repeatable reduction from
41 setups to 1 with unchanged requests and byte-identical output. These are
loopback setup/fixture costs, not real-world RTT savings, live-API measurements,
or a comparison with Go.

Raw evidence:
- [Final three-condition comparison](benchmarks/connection-reuse-optin-threeway-linux.json)
- [Independent same-final-binary default/opt-in comparison](benchmarks/connection-reuse-optin-linux.json)
- [Earlier baseline/default-on prototype comparison](benchmarks/connection-reuse-linux.json), before the feature was changed to opt-in; retained for chronology, not the final default behavior.

Reproduce the final comparison with:

```sh
python3 scripts/benchmark-connections.py \
  --binary old=/path/to/b9e2117-binary \
  --binary default=/path/to/final-binary \
  --binary reuse=/path/to/final-binary --reuse-binary reuse \
  --repetitions 7 --output /tmp/connections.json
```
