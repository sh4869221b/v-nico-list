#!/usr/bin/env python3
"""Deterministic stdout/control concurrency contracts using loopback only."""

from __future__ import annotations

import argparse
import array
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest

from loopback import Fixture, Reply, payload, video

OPTIONS = None


class OutputConcurrency(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = str(Path(OPTIONS.binary).resolve())
        if not Path(cls.binary).is_file():
            raise RuntimeError("build the CLI first: " + cls.binary)

    def start(self, fixture, targets, stdout=subprocess.PIPE, *flags):
        environment = os.environ.copy()
        environment.update(NICO_BASE_URL=fixture.url, NO_PROXY="localhost,127.0.0.1,::1",
                           no_proxy="localhost,127.0.0.1,::1")
        return subprocess.Popen(
            [self.binary, "--no-sort", "--no-progress", "--retries=1", "-P1",
             f"-T{targets}", f"-H{targets}", *flags,
             *[f"nicovideo.jp/user/{i}" for i in range(1, targets + 1)]],
            stdout=stdout, stderr=subprocess.PIPE, env=environment)

    @staticmethod
    def reap(process):
        if process.poll() is None:
            process.kill()
        process.communicate(timeout=5)

    def wait_full(self, process, fd, capacity):
        import fcntl
        import termios
        until = time.monotonic() + 5
        while time.monotonic() < until:
            available = array.array("i", [0])
            fcntl.ioctl(fd, termios.FIONREAD, available, True)
            if available[0] == capacity:
                return
            if process.poll() is not None:
                self.fail("CLI exited before filling its stdout pipe")
            time.sleep(0.005)
        self.fail("stdout pipe never filled")

    def blocked_output(self, break_pipe=False):
        import fcntl
        release = threading.Event()
        second_terminal = threading.Event()
        ids = [f"sm{i:08d}" for i in range(9000)]

        def respond(request):
            if request.identifier == "2":
                if request.page == 1:
                    if not release.wait(10):
                        raise RuntimeError("test did not release second response")
                    return Reply(payload(request.kind, [video("smsecond")]))
                second_terminal.set()
                return Reply(payload(request.kind, []))
            return Reply(payload(request.kind, [video(i) for i in ids] if request.page == 1 else []))

        read_fd, write_fd = os.pipe()
        process = None
        try:
            capacity = fcntl.fcntl(write_fd, fcntl.F_SETPIPE_SZ, 4096)
            with Fixture(respond) as fixture:
                try:
                    process = self.start(fixture, 2, write_fd)
                    os.close(write_fd)
                    write_fd = -1
                    self.wait_full(process, read_fd, capacity)
                    # No stdout byte has been consumed. Target 1 cannot finish
                    # emission; target 2 must nevertheless finish HTTP/page work.
                    release.set()
                    self.assertTrue(second_terminal.wait(3),
                                    "HTTP page completion/admission stalled behind full stdout")
                    if break_pipe:
                        # Target 2 is completing collection while target 1 owns
                        # output. Closing the reader must release both emitters.
                        os.close(read_fd)
                        read_fd = -1
                        _, stderr = process.communicate(timeout=3)
                        self.assertNotEqual(process.returncode, 0, stderr)
                        self.assertIn(b"failed to write stdout", stderr)
                    else:
                        # Let communicate drain both pipes with its timeout;
                        # cleanup kills/reaps even when the process stalls.
                        process.stdout = os.fdopen(read_fd, "rb")
                        read_fd = -1
                        stdout, stderr = process.communicate(timeout=5)
                        self.assertEqual(process.returncode, 0, stderr)
                        self.assertEqual(stdout, ("\n".join(ids + ["smsecond"]) + "\n").encode())
                        self.assertIn(b"output_count=9001", stderr)
                    self.assertFalse(fixture.errors, fixture.errors)
                finally:
                    release.set()
                    if process is not None:
                        self.reap(process)
        finally:
            if read_fd >= 0:
                os.close(read_fd)
            if write_fd >= 0:
                os.close(write_fd)

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux pipe sizing and FIONREAD")
    def test_full_stdout_does_not_block_http_completion(self):
        self.blocked_output()

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux pipe sizing and FIONREAD")
    def test_broken_stdout_releases_waiting_emitters(self):
        self.blocked_output(break_pipe=True)

    def test_concurrent_targets_remain_contiguous_and_deduplicated(self):
        ready = threading.Barrier(3)
        by_target = {str(t): [f"sm{t}{i:015d}" for i in range(3000)] for t in range(1, 4)}

        def respond(request):
            if request.page != 1:
                return Reply(payload(request.kind, []))
            ready.wait(timeout=5)
            ids = by_target[request.identifier]
            return Reply(payload(request.kind, [video(i) for i in ["smshared", *ids, "smshared"]]))

        with Fixture(respond) as fixture:
            process = self.start(fixture, 3, subprocess.PIPE, "--dedupe")
            try:
                stdout, stderr = process.communicate(timeout=10)
                self.assertEqual(process.returncode, 0, stderr)
                lines = stdout.decode().splitlines()
                self.assertEqual(lines.count("smshared"), 1)
                self.assertEqual(lines[0], "smshared")
                unique = [line for line in lines if line != "smshared"]
                self.assertEqual(len(unique), 9000)
                blocks = [unique[i:i + 3000] for i in range(0, len(unique), 3000)]
                self.assertEqual(sorted(blocks), sorted(by_target.values()))
                self.assertIn(b"output_count=9001", stderr)
                self.assertFalse(fixture.errors, fixture.errors)
            finally:
                self.reap(process)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", default="bin/v-nico-list")
    parser.add_argument("--only", help="Run test names containing this substring")
    OPTIONS = parser.parse_args()
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(OutputConcurrency)
    if OPTIONS.only:
        suite = unittest.TestSuite(test for test in suite if OPTIONS.only in test.id())
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
