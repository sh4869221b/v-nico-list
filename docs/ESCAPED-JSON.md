# Escaped JSON strings: isolated optimization

The candidate replaces only `JSONCheck.quoted`'s escaped-string path. Previously
that path scanned/validated the token, copied it, then called the strict generic
JSON decoder to parse it again. It now decodes while scanning into a safe byte
array, instantiated only after the first backslash. Ordinary strings retain the
same scanning and substring return, without constructing a decoder buffer.

`hex4` checks every digit in both surrogate halves. Surrogate pairs are combined
into a scalar before UTF-8 encoding; lone halves and malformed escapes fail.
The existing whole-input UTF-8 check, full unknown-value validation, decoded
object-name uniqueness and depth/response limits are unchanged. Decoded NUL is
preserved as a byte, not interpreted as a terminator. Error wording/cursor position
on invalid input is not an API contract; acceptance and successful values are.
No unsafe conversion is used. The output array grows with the consumed string,
not the entire remaining JSON; `bytestr()` makes the final owned string copy.

No changes were made to literal suffix checks, array handling, dates, transport,
workers or output. In particular the quadratic suffix copying documented in
[PARSER-BENCHMARK.md](PARSER-BENCHMARK.md) remains in both comparison variants.

## Compatibility evidence

`src/escaped_json_test.v` retains the exact previous quoted-string function as a
reference oracle. Tests compare successful bytes, consumed input and acceptance:

- All 65,536 BMP escape values, including rejection of lone surrogates.
- Four high-surrogate boundaries against every low surrogate, and every high
  surrogate against six low-side boundary values (valid and invalid).
- Every ASCII byte substituted at every position in representative BMP and
  surrogate escapes, including signs, invalid hex, control bytes and truncation.
- All standard escapes, embedded NUL, mixed raw Unicode, long prefix/suffix and
  escape-heavy strings. An independent expected-byte assertion covers all
  standard escapes and NUL, rather than trusting the old decoder alone.
- 500 deterministic random Unicode strings, each tested in raw/encoder form and
  independently constructed escaped form, with decoded equality to the original
  rune string.
- Escaped duplicate names (including NUL and supplementary characters), unknown
  nested fields and raw invalid UTF-8 before/after escapes.

The parser benchmark independently checks exact typed whole JSON trees and every
Page field for both variants before timing. It is not only a checksum test.

## Measurements

Linux, pinned V `67011350d000d86c3fc2a925b505c590dbfdea88`, GCC 14.2.0,
`-prod -gc boehm`. No concurrent builds were run during timed experiments.
All fixtures are synthetic, with no live API requests. Source/binary hashes and
raw samples are in [full.json](provenance/escaped-json-20261111/full.json),
[repeat.json](provenance/escaped-json-20261111/repeat.json) and
[quoted.json](provenance/escaped-json-20261111/quoted.json).

### Whole-page parse

First alternating A/B: nine samples per variant/case, 10 warmups and 20 timed
parses per sample. Times are median milliseconds/page for 100-item full fixtures.

| Case | Baseline | Candidate | Baseline range | Candidate range |
| --- | ---: | ---: | ---: | ---: |
| user ASCII | 37.986 | 37.736 | 35.811–41.031 | 32.418–39.597 |
| user raw Unicode | 38.563 | 38.797 | 35.707–39.983 | 36.914–40.162 |
| user escaped | 53.214 | 52.090 | 49.047–56.754 | 48.501–57.128 |
| mylist ASCII | 37.071 | 36.507 | 34.888–39.678 | 32.704–39.080 |
| mylist raw Unicode | 36.644 | 36.555 | 34.202–40.075 | 34.208–39.559 |
| mylist escaped | 51.835 | 49.016 | 46.537–55.447 | 45.829–55.904 |

The first escaped medians decrease 2.1% and 5.4%, but ranges overlap substantially.
This is not a reliable claim of a particular whole-page speedup. Unescaped
negative controls are essentially unchanged. Escaped allocator-accounted bytes
fall from 370.930 to 370.101 MB/user page and 370.508 to 369.679 MB/mylist page,
about 0.22%; ordinary cases are unchanged. The much larger representation-cost
gap remains dominated by unchanged suffix copying.

A second alternating run reused the exact binaries (seven samples). Escaped
100-item medians were 53.391→50.410 ms/user (5.6% lower) and
51.098→46.559 ms/mylist (8.9% lower). Negative controls varied from 3.7% lower
to 3.3% higher, reinforcing that small whole-page changes are noisy. One-item
escaped medians were 58.3→46.1 µs/user and 57.5→48.1 µs/mylist, but the
unescaped one-item controls also varied -12% to +5%; these short batch timings
are context, not a precise effect estimate. Both full runs preserve every typed
JSON value and Page field. The isolated experiment below is the strongest
attribution evidence for the escaped path.

### Isolated quoted-string path

[Reproducible microbenchmark](provenance/escaped-json-20261111/microbench.py)
copies each variant's unchanged production files into its temporary harness.
It validates the complete decoded value against an independently generated
expected file, warms 10,000 iterations and times 100,000 calls in each of nine
fresh processes, alternating variant order. It excludes UTF-8 validation (done by
`strict_json` before `quoted` in production), objects, numbers and Page handling.
Each timed call contributes its full decoded length to a checked checksum.

| Repeated 16-times string pattern | Baseline ns | Candidate ns | Baseline GC bytes | Candidate GC bytes |
| --- | ---: | ---: | ---: | ---: |
| ASCII | 378.7 | 374.0 | 192 | 192 |
| raw Unicode | 648.8 | 651.2 | 320 | 320 |
| escaped Unicode | 15,722.0 | 2,460.7 | 9,520 | 1,792 |
| standard escapes and NUL | 5,313.3 | 1,368.7 | 2,592 | 1,008 |

A second isolated experiment uses 2,816 ASCII bytes and just one newline escape,
with otherwise identical harness settings. The optional `sparse` argument to the
microbenchmark reproduces [these samples](provenance/escaped-json-20261111/quoted-sparse.json).

| Sparse case | Baseline ns | Candidate ns | Baseline GC bytes | Candidate GC bytes |
| --- | ---: | ---: | ---: | ---: |
| one escape at end | 24,274.4 | 12,194.5 | 8,608 | 5,696 |
| one escape at start | 23,740.0 | 9,833.5 | 8,608 | 11,856 |

Both sparse cases improve time (1.99× and 2.41×). **Allocation does not improve
universally:** the early escape followed by a long raw tail allocates 38% more
cumulative bytes because the lazy array grows geometrically. The late escape
can size its initial buffer from the already-scanned prefix and allocates 34%
less. This is a bounded, linear-size growth tradeoff, not a claim of universally
lower memory use; the extra allocation could matter for workloads unlike these
page fixtures.

The two escape-heavy cases above are 6.39× and 3.88× faster, with 81% and 61% less
allocator-accounted bytes. This supports keeping the bounded direct decoder,
without extrapolating those ratios to whole-page parsing or real CLI throughput.
GC bytes are cumulative allocator-accounted bytes, not live/peak memory or an
allocation count. No Go comparison, network speed or user payload distribution is
established. Windows execution has not been tested locally in this phase.

## Reproduction

See [commands](provenance/escaped-json-20261111/commands.txt). The baseline source
is `5f375c1` (production files identical to merged main `1f518b8`), and retained
baseline/candidate harness binaries have adjacent hash-checked manifests. The
measurement source was dirty before the local commit; `source_sha256`, not a
later commit identifier alone, identifies the exact compiled production code.

## Final verification

Production change and differential tests are committed locally as
`6f4fe88daacb68326825e26d7687dcdb66a8014a`. Both compiler input hashes match the
measured candidate (domain SHA-256
`82a74a6e80dcdf756e2a4df46dd072a0860896e2781b5d69b3b21cde424e2950`).
The complete non-quoted production code is byte-for-byte identical to baseline.

- V formatting and diff checks passed.
- OpenSSL and MbedTLS V units: 6/6 files passed on each, including new differential/property coverage.
- OpenSSL full loopback CLI/TLS integration: 65/65 passed.
- MbedTLS full loopback CLI/TLS integration: 65/65 passed.
- Parser fixture/type-equality tests: 2/2 passed.
- Source-built four-item parser smoke and full CLI benchmark smoke passed.
- Python syntax check passed.

Logs, CLI binary hashes and smoke outputs are retained alongside the measurements.
No GitHub publication, push, pull request or merge was performed.
