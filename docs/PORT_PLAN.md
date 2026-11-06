# V port plan

## Baseline and ownership

Port `sh4869221b/go-nico-list` commit `6638228b9acfa6256805f5e57bdd75f4ca80e084` (master inspected 2026-11-06), retaining its MIT copyright notice. The existing Go checkout is read-only for this task. New repository: `sh4869221b/v-nico-list`, public, default branch `main`, consistent with the sibling Zig port. Astra owns planning and review; GPT-6.1 Sol owns implementation.

## Required behavior

- Preserve current flag names, defaults, short options, repeated-option/explicit override semantics, and rejection of removed names.
- Read arguments, input file and stdin; retain partial URL matching, user-pattern precedence, per-line limit, strict/best-effort precedence, partial results, stdout/stderr separation and summary counts.
- Preserve comment/date filtering, numeric ID sorting, deduplication, unordered streaming, URL lines and complete JSON schema (including empty arrays and per-target errors).
- Request both API endpoint shapes with the required headers. Fetch page 1 first; use bounded page concurrency only with known totals, otherwise fetch sequentially to empty/404. Commit ordered page prefixes when a page fails or terminates.
- Share HTTP admission and rate pacing across targets, pages and retries. Honor Retry-After and bounded exponential backoff; release admission during retry waits. Keep independent explicit target/page/HTTP settings in adaptive mode.
- Verify HTTPS certificates and hostnames. Prefer V's HTTP/TLS facilities and avoid libcurl where practical. Never weaken verification or bypass the environment proxy/network policy. Document any proxy or transport boundary precisely.
- Limit successful decoded response bodies to 8 MiB before JSON decoding, including gzip expansion. Validate API JSON and timestamps; malformed input must produce a fetch error.
- Support cancellation, timeout, structured logs and HTTP metrics with documented implementation-specific diagnostic differences.

## Work and verification

1. Pin an official V compiler revision; split CLI, domain and transport/control code. Add focused unit tests.
2. Add a loopback fixture integration harness covering user/mylist, output, filters, errors/retries, rate pacing, concurrency bounds, gzip/body limit, HTTP/verified HTTPS and invalid certificates. No live-service load tests.
3. Add reproducible build/test commands, Linux and Windows CI, English/Japanese usage, design/provenance/compatibility notes and a local performance harness.
4. Astra reviews code and test evidence, sends defects to Sol, reruns affected tests and records unresolved differences honestly.
5. Inspect staged files for unintended artifacts, commit the new repository, create the public remote and push only this project if authorized credentials permit. If publication is blocked, retain a reviewable local repository and report the exact blocker rather than bypassing access controls.

## Acceptance and reporting

Report actual compiler/platform versions, executed checks and benchmark scope. Windows C generation alone is not Windows build/execution verification. Local synthetic results do not establish live niconico performance. No feature may silently accept an option without implementing it; any remaining incompatibility must be explicit in the README and verification report.
