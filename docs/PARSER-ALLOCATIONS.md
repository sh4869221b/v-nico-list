# Parser allocation experiments

This follows the unchanged-parser baseline in [PARSER-BENCHMARK.md](PARSER-BENCHMARK.md).
The experiments are independent of the escaped-string decoder branch: `quoted()`
is unchanged throughout. All measurements are local Linux/GCC, pinned V
`67011350d000d86c3fc2a925b505c590dbfdea88`, `-prod -gc boehm`, normal GC enabled.
They measure synthetic `parse_page` workloads, **not live API or complete CLI
throughput**. There is no inference about Go performance, HTTP or worker scaling.

Raw results, full binary/source/compiler identities and test logs are in
[provenance/parser-allocations-20261111](provenance/parser-allocations-20261111).
The unchanged benchmark driver checks exact Page values and the full decoded
JSON tree before timing, and checks the final Page and checksum for every sample.
GC bytes are allocator-accounted cumulative bytes, not allocation counts, live
memory, RSS or peak memory. Timing ranges are sample ranges, not confidence intervals.

## A. Bounded literal comparison

Control: `5f375c1` (production files identical to main `1f518b8`). Candidate:
`1c6b644`, replacing only `p.s[p.i..].starts_with(literal)` with a bounds-checked
byte loop. The old code copies the entire unconsumed suffix for each attempted
literal. The replacement compares at most five bytes without constructing a
substring. It deliberately remains a *prefix* test; surrounding grammar retains
responsibility for rejecting `nullx`, `truefalse`, invalid delimiters and trailing
data. Numeric parsing and all string decoding remain unchanged.

Frozen original validator tests compare results and exact errors for truncated
literals, all offsets, malformed delimiters, unknown nested members, duplicates,
invalid UTF-8, numeric edge spellings, and nesting limits. Existing parser tests
remain in force.

`prefix-ab.json` is the first exploratory 12-case run (1 and 100 items, 20 timed
parses, 10 warmups, 7 samples). Its initial build/measurement activity overlapped
unit-test compilation, so retain it as **reference only**, not the primary timing
claim. `prefix-ab-repeat.json` repeats the six 100-item cases without concurrent
builds/tests, alternating both binaries, with 20 timed parses/10 warmups/7 samples.
`prefix-long.json` separately checks the same candidate binary with 500 timed
parses/30 warmups/9 samples for all 12 cases. The long candidate-only run is a
stability check, not a paired ratio against a differently batched control.

| 100-item full case | Paired control ms | Paired prefix ms | Paired ratio | GC bytes reduced | Long prefix ms (range) |
| --- | ---: | ---: | ---: | ---: | ---: |
| user ASCII | 35.108 | 1.626 | 21.60x | 99.146% | 1.692 (1.590–1.816) |
| user Unicode | 38.416 | 1.885 | 20.37x | 99.146% | 1.661 (1.602–1.737) |
| user escaped | 50.774 | 4.318 | 11.76x | 99.009% | 4.340 (4.100–4.589) |
| mylist ASCII | 36.178 | 1.611 | 22.45x | 99.176% | 1.591 (1.525–1.759) |
| mylist Unicode | 34.763 | 1.699 | 20.46x | 99.176% | 1.661 (1.598–1.798) |
| mylist escaped | 49.747 | 4.054 | 12.27x | 99.031% | 4.164 (3.906–4.315) |

The byte reduction agrees with the prior suffix-copy source analysis. It is not a
claim that 99% of CPU time was spent copying: the elapsed-time ratios above are
measured independently. Candidate GC totals are approximately 2.29–3.68 MB/page
instead of 277–371 MB/page for these 100-item fixtures.

## B. Independent array/date trials

The prefix binary above is fixed as control. No trial includes the other trial's
production changes. Both use 500 timed parses, 30 warmups, 9 alternating samples
per variant and all 12 full cases. Builds and unit tests finish before timing.

- Arrays: constant read-only field-name arrays plus exact output capacity from
  the already decoded items array. This changes neither AST parsing nor validation.
- Dates: factor the existing year/month/day validation and UTC conversion into
  `date_components`; call it directly from the already format-validated timestamp
  components instead of constructing YYYYMMDD and reparsing its substrings.
  `parse_date` retains the original eight-digit check. This is not a general date
  parser replacement and does not expand the accepted syntax.

Frozen original date/timestamp paths compare exact values and errors across
leap centuries, years 0000 and 9999, invalid month/day values, time bounds,
positive/negative offsets, fractions, truncations and malformed syntax. Page
tests cover zero/null arrays, 1/2/31/100/1000 items with preserved order and values,
null and empty timestamp handling, and every original validation field's types.

The first array trial (`f738071`, `arrays-ab.json`) reserved exactly the decoded
item count. Review identified a downside for huge malformed arrays that fail on
the first item: unnecessarily reserving the full output array before validating
its contents. The follow-up (`05dc4b9`, `bounded-arrays-ab.json`) caps **initial
capacity** at 100, preserving normal 100-item behavior while allowing larger valid
pages to grow normally. This is not a new input-size limit. A 1000-item minimal
fixture comparison (`bounded-arrays-large.json`) and 1000-item unit tests check
larger pages; the frozen contract suite also rejects an invalid first item in a
10000-item array. Full AST allocation remains, so this is not a claim of bounded
memory for arbitrary JSON input.

The independent original array trial saves about 97 KB per 100-item user page
and 7.4 KB per mylist page. The date trial (`fdd12fe`, `dates-ab.json`) saves about
6.4 KB per 100-item page. Their long-batch elapsed-time medians are mostly within
3% either way of prefix-only control, with overlapping sample ranges: **no clear
additional throughput gain** is established by either isolated trial. Retention
is based on small reproducible allocator-byte savings and modest, tested code
changes, not a promised CPU improvement.

The initial-cap-100 variant also exposed a real tradeoff: on the 1000-item minimal
mylist fixture it increased GC bytes by about 41 KB/page because the array growth
sequence changed. The final version therefore reserves exactly **only when the
decoded array has at most 100 items**, and starts from the original empty array
for larger input. This keeps the small-page allocation benefit without changing
large-page output growth. The bounded-cap trial is retained rather than silently
discarded; it is not the final implementation. `small-arrays-ab.json` (7 samples,
500 parses, 30 warmups) and `small-arrays-large.json` (7 samples, 50 parses,
10 warmups) evaluate the final array policy independently. The combined version
is measured separately against the same prefix control.

An initial combined validation run was intentionally interrupted to make this
large-page adjustment. Its logs are retained as `interrupted-capped-*`; they are
not final validation evidence. The final validation is rerun from the adjusted
source, with separate non-interrupted logs for each TLS backend.

The final policy eliminates the 1000-item mylist allocation regression: observed
GC-byte differences versus prefix are only 2–34 bytes/page (allocator noise),
while user pages save approximately 896 KB through constant validation arrays.
Large-case wall medians remain variable; these are allocation observations, not
universal speed claims. Small-case medians are especially noisy because even
500 one-item parses form only a short timing batch.

After those independent trials, the same reservation expression was extracted
into `page_initial_capacity` solely to make its policy directly testable. Tests
assert exact capacity at 0/1/2/31/99/100 and zero at 101/1000/10000/one billion.
An invalid-large-array rejection alone would also pass with unbounded reservation,
so it is not used as proof of the cap policy. The final combined source, including
this helper, is separately built, benchmarked and validated. A pre-helper test
run was interrupted for the extraction; its `interrupted-pre-helper-*` logs are
historical only. Production SHA-256 identities are in `combined-ab.json` and
`final-hashes.txt`.

## Final combined result and validation

Final production code is prefix + immutable validation fields + small-page-only
reservation + shared date components. `quoted()` is unchanged. `combined-ab.json`
uses the final source with the directly testable reservation helper, 500 timed
parses, 30 warmups and 9 alternating samples per variant.

| 100-item full case | Prefix ms | Combined ms (range) | Prefix/combined median | GC bytes saved/page |
| --- | ---: | ---: | ---: | ---: |
| user-ascii-full-100 | 1.706 | 1.736 (1.602–1.882) | 0.983x | 103440 |
| user-unicode-full-100 | 1.860 | 1.781 (1.635–2.068) | 1.045x | 103440 |
| user-escaped-full-100 | 4.384 | 4.434 (4.310–5.159) | 0.989x | 103444 |
| mylist-ascii-full-100 | 1.714 | 1.749 (1.579–2.000) | 0.980x | 13834 |
| mylist-unicode-full-100 | 1.625 | 1.620 (1.580–1.756) | 1.003x | 13835 |
| mylist-escaped-full-100 | 4.100 | 4.136 (3.967–4.247) | 0.991x | 13808 |

These small elapsed-time changes are mixed, not an established additional speedup.
The combined allocation reduction is about 103.4 KB/user page and 13.8 KB/mylist
page at 100 items (0.38–4.36% of prefix-only allocation depending on encoding and
kind). The much larger Phase A improvement must not be attributed to these changes.

Final validation from the same production source:
- V formatting and Python syntax checks passed.
- Python fixture/comparison tests: 2/2 passed.
- OpenSSL V unit test files: 7/7 passed.
- Default MbedTLS V unit test files: 7/7 passed.
- OpenSSL Linux loopback integration: 65/65 passed.
- MbedTLS Linux loopback integration: 65/65 passed.
- Final six-case parser binary smoke and loopback CLI benchmark smoke passed.
- All A/B runs verified complete Page and decoded-tree contracts before timing.
- `git diff --check` passed.

The complete reproducible commands are in `provenance/parser-allocations-20261111/commands.txt`.
[Generated-C excerpts](provenance/parser-allocations-20261111/generated-c-excerpts.txt)
show the bounded helper and unchanged stack-resident literal list. The normal
helper path has no substring construction. Retained binaries/manifests are in
the sibling `v-nico-prefix-binaries`, `v-nico-array-binaries`, `v-nico-date-binaries`,
`v-nico-bounded-array-binaries`, `v-nico-small-array-binaries`, and
`v-nico-allocations-combined-binaries` directories; raw JSON embeds their hashes.

No Windows execution, escaped-decoder combination, live API test, or full-CLI
performance comparison was performed. The loopback CLI run is a smoke test only.
All commits are local; no push, PR, merge or publication was performed.
