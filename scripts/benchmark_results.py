#!/usr/bin/env python3
"""Linux process-level large-result benchmark (Python stdlib + GCC; no live API).

Example, after building both revisions with scripts/build.sh:
  python3 scripts/benchmark_results.py --binary before=/tmp/before \
    --binary after=/tmp/after --targets 3 --pages 200 --repetitions 5
Repeat with --targets 30 --pages 20 (60k IDs), or 3/1000 and 30/100
(300k IDs). Each case uses fresh processes; measured repetitions alternate
binary order. RSS is the kernel's per-child high-water mark from wait4, not
sampled RSS or cumulative allocation. Parent/server/sink memory is excluded.
"""

import argparse
from collections import Counter
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import shutil
import statistics
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tests'))
from loopback import Fixture, Reply, payload, video


# A fresh native supervisor avoids inheriting Python's large pre-exec RSS floor.
# Its own usage is NOT included in the reported wait4 child metrics.
SUPERVISOR = r"""
#define _GNU_SOURCE
#include <sys/resource.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
static volatile sig_atomic_t child_pid = -1;
static volatile sig_atomic_t stop_requested = 0;
static void stop_child(int sig) {
    (void)sig;
    stop_requested = 1;
    if (child_pid > 0) kill((pid_t)child_pid, SIGKILL);
}
int main(int argc, char **argv) {
    if (argc < 3) return 125;
    struct sigaction action = {0};
    action.sa_handler = stop_child;
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    struct timespec begin, end;
    clock_gettime(CLOCK_MONOTONIC, &begin);
    pid_t pid = fork();
    if (pid < 0) return 125;
    if (!pid) { execv(argv[2], argv + 2); _exit(127); }
    child_pid = pid;
    if (stop_requested) kill(pid, SIGKILL);
    int status; struct rusage usage;
    while (wait4(pid, &status, 0, &usage) < 0) {
        if (errno != EINTR) return 125;
    }
    clock_gettime(CLOCK_MONOTONIC, &end);
    FILE *f = fopen(argv[1], "w");
    if (!f) return 125;
    fprintf(f, "%.9f %.9f %.9f %ld\n",
        end.tv_sec - begin.tv_sec + (end.tv_nsec - begin.tv_nsec) / 1e9,
        usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6,
        usage.ru_stime.tv_sec + usage.ru_stime.tv_usec / 1e6, usage.ru_maxrss);
    if (fclose(f)) return 125;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 128 + WTERMSIG(status);
}
"""


def page_ids(target, page, pages):
    # Disjoint target ranges even above 1000 pages; descending within a page
    # makes exact fixture order distinguishable from global numeric sorting.
    start = 10000000 + (target - 1) * pages * 100 + (page - 1) * 100
    return ['sm' + str(start + i) for i in reversed(range(100))]


def expected_items(targets, pages):
    return [item for target in range(1, targets + 1)
            for page in range(1, pages + 1) for item in page_ids(target, page, pages)]


class TimedFixture(Fixture):
    """Timestamp handler completion, after response body flush, not creation."""
    def __init__(self, respond):
        super().__init__(respond)
        self.completions = []
        owner = self
        base = self.server.RequestHandlerClass

        class Handler(base):
            def do_GET(self):
                super().do_GET()
                with owner.lock:
                    owner.completions.append((self.path, time.monotonic()))

        self.server.RequestHandlerClass = Handler


def validate_output(data, mode, targets, pages):
    expected = expected_items(targets, pages)
    sorted_ids = sorted(expected, key=lambda item: int(item[2:]))
    if mode == 'json':
        value = json.loads(data)
        wanted = {'inputs': {'total': targets, 'valid': targets, 'invalid': 0},
                  'invalid': [], 'errors': [], 'output_count': len(expected),
                  'items': sorted_ids,
                  'targets': [{'type': 'user', 'id': str(target), 'error': '',
                               'items': [item for page in range(1, pages + 1)
                                         for item in page_ids(target, page, pages)]}
                              for target in range(1, targets + 1)]}
        if value != wanted:
            raise RuntimeError('JSON differs from complete expected payload')
        canonical = json.dumps(value, sort_keys=True, separators=(',', ':')).encode()
    elif mode == 'sorted-lines':
        if data != ('\n'.join(sorted_ids) + '\n').encode():
            raise RuntimeError('sorted line bytes differ from fixture')
        canonical = data
    else:
        # Target completion order is intentionally concurrent, but each target
        # must remain one contiguous, page-ordered block with exact line bytes.
        lines = data.decode('ascii').splitlines(keepends=True)
        width = pages * 100
        blocks = Counter(''.join(lines[i:i + width]) for i in range(0, len(lines), width))
        wanted = Counter('\n'.join(expected[i:i + width]) + '\n'
                         for i in range(0, len(expected), width))
        if blocks != wanted:
            raise RuntimeError('streaming target blocks differ from fixture order')
        canonical = ('\n'.join(expected) + '\n').encode()
    return hashlib.sha256(canonical).hexdigest()


def expected_requests(targets, pages, page_workers):
    # Fixed -P1 follows sequential pagination until a terminal empty page.
    terminal = 1 if page_workers == 1 else 0
    return Counter(('user', str(target), page, 1)
                   for target in range(1, targets + 1)
                   for page in range(1, pages + terminal + 1))


def fixture_reply(request, args):
    last_page = args.pages + (1 if args.page_workers == 1 else 0)
    if not 1 <= int(request.identifier) <= args.targets or not 1 <= request.page <= last_page:
        raise ValueError('unexpected target/page')
    ids = page_ids(int(request.identifier), request.page, args.pages) if request.page <= args.pages else []
    return Reply(payload(request.kind, [video(item) for item in ids], args.pages * 100),
                 delay=args.latency_ms / 1000)


def run_sample(binary, mode, args):
    def respond(request):
        return fixture_reply(request, args)

    flags = [f'-T{args.target_workers}', f'-P{args.page_workers}', f'-H{args.http_workers}',
             '--no-progress', '--retries=1']
    flags += ['--json'] if mode == 'json' else ['--no-sort'] if mode.startswith('no-sort-') else []
    command = [binary, *flags, *['nicovideo.jp/user/' + str(i) for i in range(1, args.targets + 1)]]
    with TimedFixture(respond) as fixture, tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as stderr:
        environment = os.environ.copy()
        environment.update(NICO_BASE_URL=fixture.url, NO_PROXY='localhost,127.0.0.1,::1', no_proxy='localhost,127.0.0.1,::1')
        slow = mode == 'no-sort-slow'
        started = time.monotonic()
        usage_path = Path(args.supervisor).with_name('usage.txt')
        usage_path.unlink(missing_ok=True)
        process = subprocess.Popen([args.supervisor, str(usage_path), *command], stdout=subprocess.PIPE if slow else output,
                                   stderr=stderr, env=environment, start_new_session=True)
        expired = threading.Event()
        reader_errors = []
        sink = {'first_read_seconds': None, 'finished_seconds': None, 'bytes': 0}

        def expire():
            expired.set()
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass

        def drain():
            try:
                expired.wait(args.slow_start_ms / 1000)
                while not expired.is_set():
                    chunk = os.read(process.stdout.fileno(), args.slow_chunk_bytes)
                    if not chunk:
                        break
                    if sink['first_read_seconds'] is None:
                        sink['first_read_seconds'] = time.monotonic() - started
                    output.write(chunk)
                    sink['bytes'] += len(chunk)
                    expired.wait(len(chunk) / args.slow_bytes_per_second)
                sink['finished_seconds'] = time.monotonic() - started
            except Exception as exc:
                reader_errors.append(repr(exc))

        timer = threading.Timer(args.timeout, expire)
        reader = threading.Thread(target=drain) if slow else None
        reader_started = False
        try:
            timer.start()
            if reader:
                reader.start()
                reader_started = True
            process.wait()
            wall = time.monotonic() - started
            if reader:
                reader.join(timeout=args.timeout)
                if reader.is_alive():
                    raise TimeoutError('stdout reader did not finish')
        finally:
            # Covers KeyboardInterrupt and wait/reader failures as well as the
            # normal path. Kill the entire private group before reaping so a
            # failed supervisor cannot leave its CLI behind holding the pipe.
            timer.cancel()
            if timer.ident is not None:
                timer.join()
            if process.returncode is None or (reader_started and reader.is_alive()):
                expire()
            process.wait()
            if reader_started:
                reader.join(timeout=2)
            if process.stdout:
                process.stdout.close()
        stderr.seek(0)
        diagnostics = stderr.read().decode(errors='replace')
        if expired.is_set() or process.returncode or reader_errors:
            raise RuntimeError(f'child failed: timeout={expired.is_set()}, code={process.returncode}, reader={reader_errors}: {diagnostics}')
        child_wall, user_cpu, system_cpu, peak_rss = usage_path.read_text().split()
        output.seek(0)
        data = output.read()
        digest = validate_output(data, mode, args.targets, args.pages)
        wanted_requests = expected_requests(args.targets, args.pages, args.page_workers)
        completion_deadline = time.monotonic() + 1
        while len(fixture.completions) < sum(wanted_requests.values()) and time.monotonic() < completion_deadline:
            time.sleep(0.001)
        actual = Counter((r.kind, r.identifier, r.page, r.attempt) for r in fixture.records)
        if fixture.errors or actual != wanted_requests or len(fixture.completions) != sum(wanted_requests.values()):
            raise RuntimeError(f'fixture/request mismatch: {fixture.errors}')
        last_response = max(t for _, t in fixture.completions) - started
        completion_times = dict(fixture.completions)
        target_timing = {}
        for target in range(1, args.targets + 1):
            requests = [r for r in fixture.records if r.identifier == str(target)]
            target_timing[str(target)] = {
                'first_request_seconds': min(r.started for r in requests) - started,
                'last_response_complete_seconds': max(completion_times[r.path] for r in requests) - started}
        return {'command': command, 'wall_seconds': wall, 'child_wall_seconds': float(child_wall), 'user_cpu_seconds': float(user_cpu),
                'system_cpu_seconds': float(system_cpu), 'peak_rss_kib': int(peak_rss),
                'last_response_complete_seconds': last_response,
                'child_exit_after_last_response_seconds': wall - last_response,
                'requests': len(fixture.records), 'http_peak': fixture.peak, 'target_timing': target_timing,
                'stdout_bytes': len(data), 'stdout_sha256': hashlib.sha256(data).hexdigest(),
                'canonical_result_sha256': digest, 'output_count': args.targets * args.pages * 100,
                'sink': sink if slow else 'temporary file'}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--binary', action='append', required=True, metavar='NAME=PATH')
    parser.add_argument('--binary-manifest', action='append', default=[], metavar='NAME=PATH',
                        help='reported source/build manifest; binary_sha256 must match supplied binary')
    parser.add_argument('--targets', type=int, default=3)
    parser.add_argument('--pages', type=int, default=200)
    parser.add_argument('--repetitions', type=int, default=5)
    parser.add_argument('--warmups', type=int, default=1)
    parser.add_argument('--mode', action='append', choices=['sorted-lines', 'json', 'no-sort-fast', 'no-sort-slow'])
    parser.add_argument('--target-workers', type=int, default=4)
    parser.add_argument('--page-workers', type=int, default=4)
    parser.add_argument('--http-workers', type=int, default=8)
    parser.add_argument('--latency-ms', type=float, default=0)
    parser.add_argument('--slow-bytes-per-second', type=int, default=262144)
    parser.add_argument('--slow-chunk-bytes', type=int, default=4096)
    parser.add_argument('--slow-start-ms', type=float, default=250)
    parser.add_argument('--timeout', type=float, default=180)
    parser.add_argument('--source-revision', default='unspecified', help='source revision of binaries, or describe each binary separately')
    parser.add_argument('--v', default=os.environ.get('V', 'v'), help='compiler used to build benchmarked binaries (metadata only)')
    parser.add_argument('--output', default='large-results-benchmark.json')
    args = parser.parse_args()
    if sys.platform != 'linux' or not hasattr(os, 'wait4'):
        parser.error('Linux wait4 is required for per-child peak RSS in KiB')
    if any(getattr(args, k) <= 0 for k in ('targets', 'pages', 'repetitions', 'target_workers', 'page_workers', 'http_workers', 'slow_bytes_per_second', 'slow_chunk_bytes', 'timeout')) or min(args.warmups, args.latency_ms, args.slow_start_ms) < 0:
        parser.error('counts/rates/timeout must be positive; delays/warmups nonnegative')
    binaries = {}
    for spec in args.binary:
        name, sep, path = spec.partition('=')
        if not sep or not name or name in binaries:
            parser.error('--binary requires UNIQUE_NAME=PATH')
        path = str(Path(path).resolve())
        binaries[name] = {'path': path, 'sha256': hashlib.sha256(Path(path).read_bytes()).hexdigest()}
    for spec in args.binary_manifest:
        name, sep, path = spec.partition('=')
        if not sep or name not in binaries or 'reported_build_manifest' in binaries[name]:
            parser.error('--binary-manifest requires a unique existing binary NAME=PATH')
        data = Path(path).read_bytes()
        manifest = json.loads(data)
        if manifest.get('binary_sha256') != binaries[name]['sha256']:
            parser.error(f'{name}: manifest binary_sha256 does not match actual binary')
        binaries[name]['reported_build_manifest'] = manifest
        binaries[name]['manifest_sha256'] = hashlib.sha256(data).hexdigest()
    report = {'scope': 'Synthetic loopback end-to-end child process; no live API inference.',
              'measurement': 'Fresh C supervisor forks and wait4-reaps CLI (excludes Python pre-exec RSS floor). Linux wait4 per-child ru_maxrss (KiB), ru_utime, ru_stime; wall excludes sink tail drain and validation. No parent/server memory. Response completion means server handler finished after body flush, not client consumption.',
              'platform': platform.platform(), 'python': platform.python_version(),
              'parameters': dict(vars(args)), 'binaries': binaries, 'cases': {},
              'reported_toolchain': {'source_revision_label': args.source_revision,
                                 'note': 'Toolchain metadata supplied by caller; not inferred from binary. Per-binary reported manifests, when supplied, are hash-checked against binaries.',
                                 'v_version': subprocess.check_output([args.v, 'version'], text=True).strip(),
                                 'v_sha256': hashlib.sha256(Path(shutil.which(args.v)).read_bytes()).hexdigest(),
                                 'gcc_version': subprocess.check_output(['gcc', '--version'], text=True).splitlines()[0]},
              'execution_order': 'warmups then repetitions; forward/reverse binary order alternates per case, measured first repetition forward'}
    with tempfile.TemporaryDirectory(prefix='nico-results-supervisor-') as temp:
        source = Path(temp) / 'supervisor.c'
        source.write_text(SUPERVISOR)
        args.supervisor = str(Path(temp) / 'supervisor')
        subprocess.run(['gcc', '-O2', '-o', args.supervisor, str(source)], check=True)
        report['harness_sha256'] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        report['supervisor_source_sha256'] = hashlib.sha256(SUPERVISOR.encode()).hexdigest()
        for mode in args.mode or ['sorted-lines', 'json', 'no-sort-slow']:
            samples = {name: [] for name in binaries}
            for iteration in range(-args.warmups, args.repetitions):
                names = list(binaries)
                if iteration % 2:
                    names.reverse()
                for name in names:
                    sample = run_sample(binaries[name]['path'], mode, args)
                    if iteration >= 0:
                        samples[name].append(sample)
                    print(f'{mode} {name} iteration={iteration} wall={sample["wall_seconds"]:.3f}s rss={sample["peak_rss_kib"]}KiB', file=sys.stderr)
            report['cases'][mode] = {'samples': samples, 'medians': {
                name: {key: statistics.median(sample[key] for sample in values)
                       for key in ('wall_seconds', 'user_cpu_seconds', 'system_cpu_seconds', 'peak_rss_kib', 'last_response_complete_seconds')}
                for name, values in samples.items()}}
            Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
    print(str(Path(args.output).resolve()))


if __name__ == '__main__':
    main()
