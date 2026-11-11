# v-nico-list

A V command line tool that collects video IDs from niconico user pages and mylists. It ports [go-nico-list](https://github.com/sh4869221b/go-nico-list/tree/6638228b9acfa6256805f5e57bdd75f4ca80e084), preserving its command line options and result format.

The Linux build passes 55 loopback integration contracts. Native Windows CI passes 49, with 6 POSIX signal cases skipped. The published baseline was slower than Go. The latest [JSON/sort optimizations](docs/PERFORMANCE.md) reduce synthetic wall time versus that V baseline; they are not a new Go comparison. [Recorded results and platform limits](docs/VALIDATION.md) describe the evidence.

[日本語](docs/README.ja.md) · [Compatibility and transport boundaries](docs/COMPATIBILITY.md) · [Validation and benchmarks](docs/VALIDATION.md) · [Provenance](docs/provenance/README.md)

## Build

Use the official [V compiler](https://github.com/vlang/v), pinned by [scripts/v-revision](scripts/v-revision) and [scripts/vc-revision](scripts/vc-revision). Linux needs a C compiler, OpenSSL development headers/libraries, and Boehm GC development libraries. On Debian/Ubuntu, install `gcc make libssl-dev libgc-dev openssl`.

`scripts/setup-v.sh /path/to/new/v` bootstraps the pinned official V/VC/TCC sources into a new directory using your inherited network/proxy configuration. It refuses to replace an existing directory. The resulting Linux binary dynamically links OpenSSL and other system libraries; it is not a fully static executable.

```sh
V=/path/to/v/v scripts/build.sh
./bin/v-nico-list --help
```

The executable uses V's networking and TLS facilities, with a bounded HTTP/1.1 transport. It does not invoke curl or require libcurl. The Linux build selects OpenSSL. [Native Windows CI](https://github.com/sh4869221b/v-nico-list/actions/runs/42152349163) builds and runs the executable with MSVC and V's default Mbed TLS backend; both native CI jobs passed. No prebuilt releases are supplied yet.

## Usage

```sh
v-nico-list nicovideo.jp/user/12345
v-nico-list https://www.nicovideo.jp/user/12345/video --url
v-nico-list nicovideo.jp/user/1 nicovideo.jp/mylist/847130 -T 8 -P 4 -H 8
v-nico-list --input-file targets.txt --json --dedupe
cat targets.txt | v-nico-list --stdin
```

Inputs come from positional arguments, then `--input-file`, then `--stdin`. File/stdin inputs are trimmed, empty lines are skipped, and each line is limited to 1 MiB. The compatible input parser extracts partial URL matches: the first user URL wins even if a mylist URL appears earlier in the same input. User IDs match up to 9 digits and mylist IDs up to 12; longer numeric suffixes are truncated by the matching pattern.

Video IDs are printed one per line, numerically sorted. `--url` adds `https://www.nicovideo.jp/watch/`. `--dedupe` removes duplicates from the combined output. `--no-sort` streams completed targets without a stable cross-target order; with `--json`, it preserves input order in the combined `items` instead. Logs, progress and the final summary go to stderr. `--logfile` directs structured logs to that file; the summary stays on stderr.

`--comment N` includes only videos with **more than** N comments. Dates are inclusive UTC calendar bounds in `YYYYMMDD`, independent of the offset in each video's RFC 3339 timestamp.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `-c, --comment` | `0` | Exclusive lower comment count |
| `-a, --dateafter` | `10000101` | First included UTC date |
| `-b, --datebefore` | `99991231` | Last included UTC date |
| `-u, --url` | `false` | Emit watch URLs in line output |
| `-T, --concurrency-targets` | `3` | Concurrent input targets; at least 1 |
| `-P, --concurrency-pages` | `1` | Concurrent pages per target; at least 1 |
| `-H, --concurrency-http` | `0` | Global HTTP cap; 0 disables the additional cap |
| `-A, --concurrency-adaptive` | `false` | Adjust unspecified concurrency layers from HTTP feedback |
| `--http-metrics` | `false` | Emit a final aggregate HTTP metrics log event |
| `--rate-limit` | `0` | Global requests/second; 0 disables |
| `--min-interval` | `0s` | Minimum interval between requests |
| `--timeout` | `10s` | Timeout for each HTTP attempt |
| `--retries` | `10` | Maximum total attempts per request; at least 1 |
| `--input-file` | empty | Read newline-separated inputs from a file |
| `--stdin` | `false` | Also read newline-separated stdin |
| `--logfile` | empty | Append structured logs to a file |
| `--progress` | `false` | Force progress output |
| `--no-progress` | `false` | Disable progress, including when forced |
| `--strict` | `false` | Fail if any input is invalid |
| `--best-effort` | `false` | Suppress fetch failure exit status |
| `--dedupe` | `false` | Remove repeated combined-output IDs |
| `--no-sort` | `false` | Skip global sorting |
| `--json` | `false` | Emit one JSON object |
| `-h, --help` | | Display usage |
| `-v, --version` | | Display the port version |

Repeated options use the last value, including mixed short and long forms. Explicit concurrency options fix only their own layer in adaptive mode, regardless of position or whether they equal the default. `-A -T3` fixes target concurrency while page/HTTP concurrency remain automatic; `-A -H0` explicitly removes the HTTP cap. Short values may be attached (`-T3`) and boolean short options clustered (`-uA`). Boolean long options accept explicit values (`--strict=false`). Removed names `--concurrency`, `--page-concurrency`, `--http-concurrency`, `--adaptive-concurrency`, `--adaptive-http-concurrency`, `--tab`, `-t`, `--max-pages`, `--max-videos` and `-n` are rejected.

## JSON and failures

```json
{
  "inputs": {"total": 1, "valid": 1, "invalid": 0},
  "invalid": [],
  "targets": [{"type": "user", "id": "1", "items": ["sm123"], "error": ""}],
  "errors": [],
  "output_count": 1,
  "items": ["sm123"]
}
```

All arrays remain arrays when empty. Targets are sorted by type and numeric target ID. Per-target `items` preserve page order; sorting/deduplication affect the combined `items` only. `--url` does not change JSON IDs. Failed targets carry an `error`; successfully completed page prefixes and other targets still contribute results.

Exit status is 0 when there are no fetch errors; invalid inputs are skipped by default. `--strict` makes invalid inputs an error and takes precedence over `--best-effort`. Validation, input reading and output failures remain errors under `--best-effort`. Cancellation and request deadlines yield successful empty target results, matching the reference's behavior.

Page 1 is fetched first. Without a known total, subsequent pages are sequential until empty/404. Fixed `-P1` also runs sequentially to empty/404 even with a total. Larger page concurrency uses a known total to bound scheduling. Parallel results commit in page order and stop before the earliest terminating/failed page. Retries release HTTP admission while waiting, share global pacing, and use exponential backoff from 100 ms to 30 s. A 429 honors `Retry-After`; adaptive mode applies its cooldown command-wide.

## Development

```sh
/path/to/v/v -cc gcc -d use_openssl test src
python3 tests/integration.py --binary bin/v-nico-list
python3 scripts/benchmark.py --binary v=bin/v-nico-list --output /tmp/v-benchmark.json
```

The integration suite uses synthetic HTTP/HTTPS loopback servers only. It covers CLI contracts, filters, pagination, partial results, retry timing, concurrency/pacing, cancellation, TLS verification, gzip/chunking and the 8 MiB decoded response limit. TLS fixtures need the OpenSSL command line tool. See [validation instructions and recorded evidence](docs/VALIDATION.md) for the Go comparison and platform limits.

`NICO_BASE_URL` is a development override for the API base (default `https://nvapi.nicovideo.jp/v3`). Fixtures set it to a loopback server ending in `/v3`; endpoint paths are appended beneath that base. It does not disable TLS verification or proxy handling.
