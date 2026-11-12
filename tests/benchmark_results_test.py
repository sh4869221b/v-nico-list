"""Fixture and exact-output contracts for benchmark_results.py."""
import importlib.util
import argparse
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from unittest import mock
import json
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('benchmark_results', Path(__file__).resolve().parents[1] / 'scripts/benchmark_results.py')
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class ResultFixtureTests(unittest.TestCase):
    def test_unique_large_ids(self):
        ids = bench.expected_items(3, 1000)
        self.assertEqual(len(ids), 300000)
        self.assertEqual(len(set(ids)), len(ids))
        self.assertTrue(all(item[2:].isdigit() for item in ids))

    def test_sequential_pagination_has_one_terminal_request(self):
        args = argparse.Namespace(targets=2, pages=3, page_workers=1, latency_ms=0)
        request = argparse.Namespace(identifier='2', page=4, kind='user')
        value = json.loads(bench.fixture_reply(request, args).body)
        self.assertEqual(value['data']['items'], [])
        self.assertEqual(value['data']['totalCount'], 300)
        self.assertEqual(sum(bench.expected_requests(2, 3, 1).values()), 8)
        self.assertIn(('user', '2', 4, 1), bench.expected_requests(2, 3, 1))
        args.page_workers = 4
        self.assertEqual(sum(bench.expected_requests(2, 3, 4).values()), 6)
        with self.assertRaises(ValueError):
            bench.fixture_reply(request, args)

    def test_sorted_exact_bytes(self):
        items = sorted(bench.expected_items(2, 2), key=lambda item: int(item[2:]))
        data = ('\n'.join(items) + '\n').encode()
        bench.validate_output(data, 'sorted-lines', 2, 2)
        with self.assertRaises(RuntimeError):
            bench.validate_output(data[:-1], 'sorted-lines', 2, 2)

    def test_streaming_target_order_is_concurrent_page_order_is_exact(self):
        items = bench.expected_items(2, 2)
        data = ('\n'.join(items[200:] + items[:200]) + '\n').encode()
        bench.validate_output(data, 'no-sort-slow', 2, 2)
        items[0], items[100] = items[100], items[0]
        with self.assertRaises(RuntimeError):
            bench.validate_output(('\n'.join(items) + '\n').encode(), 'no-sort-slow', 2, 2)

    def test_json_all_fields(self):
        items = bench.expected_items(1, 2)
        value = {'inputs': {'total': 1, 'valid': 1, 'invalid': 0}, 'invalid': [],
                 'errors': [], 'output_count': 200, 'items': sorted(items, key=lambda item: int(item[2:])),
                 'targets': [{'type': 'user', 'id': '1', 'error': '', 'items': items}]}
        bench.validate_output(json.dumps(value).encode(), 'json', 1, 2)
        value['targets'][0]['items'] = list(reversed(items))
        with self.assertRaises(RuntimeError):
            bench.validate_output(json.dumps(value).encode(), 'json', 1, 2)


@unittest.skipUnless(sys.platform == 'linux' and shutil.which('gcc'), 'Linux and GCC required')
class SupervisorCleanupTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        source = self.root / 'supervisor.c'
        source.write_text(bench.SUPERVISOR)
        self.supervisor = self.root / 'supervisor'
        subprocess.run(['gcc', '-O2', '-o', str(self.supervisor), str(source)], check=True)
        self.pidfile = self.root / 'pid'
        self.child = self.root / 'child'
        self.child.write_text('#!' + sys.executable + '\nimport os, time\n'
                              + 'open(' + repr(str(self.pidfile)) + ', "w").write(str(os.getpid()))\n'
                              + 'time.sleep(20)\n')
        self.child.chmod(0o755)
        self.args = argparse.Namespace(supervisor=str(self.supervisor), targets=1, pages=1,
            target_workers=4, page_workers=4, http_workers=8, latency_ms=0,
            slow_start_ms=0, slow_chunk_bytes=4096, slow_bytes_per_second=262144, timeout=.3)

    def assert_child_reaped(self):
        self.assertTrue(self.pidfile.exists())
        pid = int(self.pidfile.read_text())
        self.assertFalse(Path('/proc', str(pid)).exists(), 'CLI child was not reaped')

    def test_timeout_kills_and_reaps_child(self):
        with self.assertRaisesRegex(RuntimeError, 'timeout=True'):
            bench.run_sample(str(self.child), 'no-sort-slow', self.args)
        self.assert_child_reaped()

    def test_signal_before_child_pid_assignment_is_not_lost(self):
        source = self.root / 'supervisor.c'
        # Widen precisely the fork-to-pid-publication window. The child writes
        # its PID while the parent is paused before child_pid assignment.
        source.write_text(bench.SUPERVISOR.replace(
            '    child_pid = pid;', '    usleep(500000);\n    child_pid = pid;'))
        subprocess.run(['gcc', '-O2', '-o', str(self.supervisor), str(source)], check=True)
        process = subprocess.Popen([str(self.supervisor), str(self.root / 'usage'), str(self.child)],
                                   start_new_session=True)
        try:
            deadline = time.monotonic() + 1
            while not self.pidfile.exists() and time.monotonic() < deadline:
                time.sleep(.001)
            self.assertTrue(self.pidfile.exists())
            os.kill(process.pid, signal.SIGTERM)
            self.assertEqual(process.wait(timeout=2), 128 + signal.SIGKILL)
            self.assert_child_reaped()
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
                process.wait()

    def test_interrupted_wait_kills_and_reaps_child(self):
        original = subprocess.Popen.wait
        interrupted = False

        def interrupt_once(process, *args, **kwargs):
            nonlocal interrupted
            if not interrupted:
                interrupted = True
                deadline = time.monotonic() + 1
                while not self.pidfile.exists() and time.monotonic() < deadline:
                    time.sleep(.001)
                raise KeyboardInterrupt()
            return original(process, *args, **kwargs)

        with mock.patch.object(subprocess.Popen, 'wait', interrupt_once):
            with self.assertRaises(KeyboardInterrupt):
                bench.run_sample(str(self.child), 'no-sort-slow', self.args)
        self.assert_child_reaped()


if __name__ == '__main__':
    unittest.main()
