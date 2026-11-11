# Isolated parser baseline

`scripts/benchmark_parse.py` measures the **unchanged production `parse_page`** from
one or more checkouts. It copies `src/domain.v` and `src/config.v` without editing
them into a temporary harness and builds with the pinned V revision, GCC, `-prod`
and explicit `-gc boehm` (the production GC). No network or CLI process workload
is involved. This commit adds measurement infrastructure, not an optimization.

## Reproduce and compare

From this checkout, with the pinned compiler prepared by `scripts/setup-v.sh`:

```sh
export VMODULES=/path/to/writable/vmodules
python3 scripts/benchmark_parse.py --source main=. --v /path/to/v/v \
  --size 1 --size 100 --iterations 20 --warmups 10 --repetitions 7 \
  --build-dir /tmp/parser-main-binaries --output /tmp/parser-main.json

# Independent optimization checkouts: builds happen before any measurements.
python3 scripts/benchmark_parse.py \
  --source baseline=/path/to/main --source candidate=/path/to/candidate \
  --v /path/to/v/v --size 100 --iterations 20 --repetitions 9 \
  --build-dir /tmp/parser-ab-binaries --output /tmp/parser-ab.json

# Reuse those exact binaries with this same driver, without recompilation:
python3 scripts/benchmark_parse.py \
  --binary baseline=/tmp/parser-ab-binaries/baseline \
  --binary candidate=/tmp/parser-ab-binaries/candidate \
  --size 100 --iterations 20 --repetitions 9 --output /tmp/parser-ab-repeat.json

python3 tests/benchmark_parse_test.py
```

Retained build directories must not already exist. Each binary has an adjacent
`.json` build manifest; reuse rejects a changed binary or driver. Default builds,
fixtures and copies are automatically removed with their temporary directory.
Only explicit `--build-dir` artifacts and the result JSON persist. Every child
process has a 180-second timeout; sizes and loop counts have explicit bounds.
The harness is currently validated on Linux/GCC, not Windows. `--cc` requires a
compiler supporting `--version`. The V checkout HEAD must match `scripts/v-revision`.

## Cases and correctness

The default six cases are user and mylist pages with 100 items, each encoded as
ASCII, literal Unicode, or escape-heavy Unicode. `--size` can be repeated for
1..1000 items; `--profile minimal` omits extra metadata but keeps IDs, comments
and timestamps. These are deterministic synthetic schema-shaped fixtures, not
captured responses or a claim about users' actual payload frequencies.

Full fixtures exercise every currently validated user metadata field, counts,
thumbnail URLs, owner/series objects, nested unknown objects/arrays, null, bool,
integer and fractional values. Timestamps cycle through UTC, negative offsets,
positive offsets with fractional seconds, and leap days. Mylist fixtures include
all three totals with deliberately different fallback values. Both protocols
preserve every item's ID, comment and timestamp in order.

Literal-Unicode and escaped cases have **identical decoded JSON values**.
Escaped cases encode non-ASCII characters and surrogate pairs, selected object
names, ID prefixes and URL slashes. ASCII strings have different content/length;
ASCII vs Unicode is not a controlled single-variable comparison. General escape
controls, malformed JSON, duplicate names, invalid UTF-8 and invalid dates remain
covered by production `domain_test.v`; this is not a replacement for those tests.

Before timing each fixture/variant, the harness emits the full `Page` and full
`strict_json` tree. Python independently checks the expected Page, with expected
UTC seconds calculated by `datetime`, and the full tree used to generate the
fixture. Recursive comparison preserves scalar types, rejecting `true` vs `1`
and `1.0` vs `1`. Every timed process also emits its final complete Page for the
same exact check. Generated-fixture and comparison tests test this machinery.

## Measured region and limitations

Each sample is a fresh process which reads its fixture, warms up by parsing it
10 times, and measures 20 more calls with `time.sys_mono_now()`. The measured
region includes parse allocations, normal GC, assignment to the last Page, and
a small scalar checksum/loop. It excludes file reads, startup, validation,
printing/encoding, HTTP, workers, filtering, sorting and output locking.
Alternating forward/reverse variant order reduces order bias for two-way A/B.
Use two variants for a decision; forward/reverse does not balance the middle of
three variants. Samples, min/median/max, fixture hashes, production file hashes,
Git HEAD/tree/status, driver/compiler/binary hashes and build flags are retained.
Working-tree hashes, rather than only HEAD, identify the compiled production code.

`gc_heap_usage().total_bytes` before/after the batch measures **Boehm cumulative
allocator-accounted bytes**, including transient allocation/reallocation and
allocator rounding. It is not allocation count, retained data, RSS, or peak
memory. Heap-size snapshots before/after are neither peak nor live memory.
Counters are outside the clock interval, and GC remains enabled with no forced
collection. Wall samples can still vary with GC/OS scheduling and heap history.
No source-level allocation attribution is established by these counters alone.

Do not extrapolate these numbers to live Niconico throughput or full CLI speed.
Do not subtract independently measured stages as a CPU profile. This harness
contains no worker scheduling, output-lock or network-wait experiment. Those
questions require separate evidence after isolated parser experiments.

## Recorded baseline

See [raw samples and build identity](provenance/parser-baseline-20261111/full.json)
and [unit-test log](provenance/parser-baseline-20261111/unit-tests.txt). The compiled
production files are from main `1f518b8385cbba51f1b57d6048de17b77d57fdbe`, tree
`c0e13139ed4556fcfa2e7e674eae574d06edf132`, unchanged in this branch. The harness
uses V `0.5.2 6701135` and GCC 14.2.0. Results below are local Linux measurements,
not confidence intervals or performance gates.

| Case (100 items) | Median ms/page | Range ms/page | GC MB/page |
| --- | ---: | ---: | ---: |
| user-ascii-full-100 | 36.963 | 36.352–41.315 | 278.04 |
| user-unicode-full-100 | 36.814 | 32.864–38.806 | 278.04 |
| user-escaped-full-100 | 51.257 | 47.135–54.681 | 370.93 |
| mylist-ascii-full-100 | 36.462 | 34.931–39.212 | 277.49 |
| mylist-unicode-full-100 | 35.847 | 33.556–39.167 | 277.50 |
| mylist-escaped-full-100 | 47.790 | 45.357–50.527 | 370.51 |

Seven samples per case, each with 10 warmups and 20 timed parses. The identical
Unicode/escaped trees expose about 33–39% more elapsed parsing time and about
33% more allocator-accounted bytes for escaped representation in these cases.
This is a representation-cost difference, not an isolated escape-decoder cost.
The suffix-copy finding below explains most of the extra allocation. One-item full pages use approximately 79–101 KB of GC
allocation versus 277–371 MB for 100 items: allocation grows far faster than item
count here. Runtime counters alone do not attribute that growth to array growth, date-string
allocation or any individual function. The following source inspection narrows
the cause without changing production code.

Production V unit tests passed 5/5 files. Fixture/type-equality tests, V format,
Python syntax and diff checks passed. A two-name reuse smoke loaded the same
retained binary twice, alternated order across two repetitions, and verified all
six four-item cases. It validates binary reuse, not a performance difference.
[Reuse smoke evidence](provenance/parser-baseline-20261111/reuse-smoke.json).
Linux CI now runs fixture tests and a tiny source-build smoke with no speed gate.
No new full CLI integration or Windows benchmark was run for these harness-only
changes; unchanged main's full CI is separate evidence.

## Suffix-copy finding (no optimization applied)

In the pinned compiler, `string.substr` allocates `len + 1` bytes and copies the
substring. Generated C confirms `JSONCheck.value`'s literal loop calls
`string__starts_with(string__substr(p->s, p->i, p->s.len), literal)`, not a borrowed
slice. Every number tries three literals, null tries one, true two, false three.
Each attempt therefore copies the entire remaining input even though only a
four/five-byte prefix is inspected. This produces quadratic total copied bytes
as the number of scalar fields and payload length grow together.

[Generated-C/source excerpt](provenance/parser-baseline-20261111/suffix-copy-source.txt),
[reproducible static estimator](provenance/parser-baseline-20261111/estimate_suffix.py),
and [estimated requested bytes](provenance/parser-baseline-20261111/suffix-copy-estimate.json).
The estimator only scans the known valid fixture outside strings; it is not an
alternative JSON parser or production code.

For the 100-item user Unicode fixture (119,543 bytes), 4,606 suffix copies request
275,593,653 bytes before allocator rounding, versus 278,038,027 median GC bytes
per parse. For the semantically identical escaped fixture (159,343 bytes), they
request 367,201,453 bytes versus 370,930,250 measured. The same pattern holds for
mylist. This accounts for roughly 99% of allocation bytes arithmetically, strongly
supporting suffix copying as the dominant **allocation** cause. It does not prove
99% of CPU time, nor establish a speedup for removing it. In particular the larger
escaped representation inflates these copies; attributing its entire timing gap
to escaped-string decoding would be misleading. Escape decoding, array/date
allocation and any literal-prefix change still require independent experiments
and semantic contract tests, in the agreed order.

## Follow-on experiments

The independent stages and final combined results are documented in
[PARSER-ALLOCATIONS.md](PARSER-ALLOCATIONS.md),
[ESCAPED-JSON.md](ESCAPED-JSON.md), and
[PARSER-COMBINED.md](PARSER-COMBINED.md). The last includes the first whole-CLI
A/B for these parser changes against exact main, plus final dual-backend checks.
