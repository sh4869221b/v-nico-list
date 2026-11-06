# Source and dependency provenance

The behavioral baseline is [sh4869221b/go-nico-list at 6638228b9acfa6256805f5e57bdd75f4ca80e084](https://github.com/sh4869221b/go-nico-list/tree/6638228b9acfa6256805f5e57bdd75f4ca80e084), inspected on 2026-11-06. The V port was written in a separate repository; the reference checkout is read-only. The original MIT copyright notice is retained in [LICENSE](../../LICENSE).

The port follows the baseline CLI/input/filter/output/pagination/retry/control behavior. It does not bundle or invoke the Go executable. Runtime code is V with a small C signal/output bridge. The loopback tests and benchmarks use Python's standard library; synthetic fixtures contain no copied user content and make no requests to niconico.

Compiler sources come from [vlang/v](https://github.com/vlang/v) revision `67011350d000d86c3fc2a925b505c590dbfdea88`. Bootstrap C comes from [vlang/vc](https://github.com/vlang/vc) revision `63a7de2aaa48271b71ca8b306fe06d7cc6c3a372`. Their own upstream licenses apply to their compiler/runtime components and bundled third-party code. The revision files under `scripts/` are the CI source of truth; updates should change those files and this provenance record together.

The Linux bootstrap uses [vlang/tccbin](https://github.com/vlang/tccbin) at `60d606e37e6afe1ac5801fd88c55036a56b7caae`, pinned in `scripts/tcc-revision`. Native Windows bootstrap uses MSVC with the pinned V/VC sources and `makev.bat -msvc --local`; it does not fetch a mutable TCC snapshot.

Linux links the system OpenSSL and Boehm GC libraries; Windows uses the TLS backend selected by its V build and the corresponding V-distributed dependencies. Packaging must include the applicable V/runtime and third-party license notices. No release package or complete binary notice bundle has been produced yet.

The optional Go comparison launcher is generated in a temporary directory by [build_reference.py](../../scripts/build_reference.py). It imports the unchanged baseline's exported command constructor and injects `NICO_BASE_URL` through `RootConfig.BaseURL`. It disables VCS stamping only for the temporary launcher. This injection allows both executables to use identical synthetic loopback fixtures; it does not change baseline fetching or output code.

Executed Linux integration logs, toolchain/binary/harness hashes and four benchmark reports are retained in this directory. [VALIDATION.md](../VALIDATION.md) explains their scope and the measured slowdown; [linux-validation.json](linux-validation.json) associates the runs with the final executable hashes. Native Windows execution and live API performance are unverified.
