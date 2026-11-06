#!/usr/bin/env python3
"""Black-box CLI contracts against loopback fixtures. Python standard library only."""

from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import json
import os
from pathlib import Path
import queue
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest

from loopback import Fixture, Reply, TunnelProxy, payload, single_page, video

PARSER = argparse.ArgumentParser(description=__doc__)
PARSER.add_argument("--binary", default="bin/v-nico-list")
PARSER.add_argument("--only", help="Run test names containing this substring")
PARSER.add_argument("--profile", choices=("v", "go-reference"), default="v", help="Go excludes force-proxy loopback cases and V-specific extreme-duration overflow regressions")
OPTIONS = None


class CLIContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.binary = str(Path(OPTIONS.binary).resolve())
        if not Path(cls.binary).is_file():
            raise RuntimeError("build the CLI first: " + cls.binary)

    def run_cli(self, fixture, *args, stdin=None, env=None, timeout=15):
        environment = os.environ.copy()
        # Only this loopback destination bypasses proxies. Retain all inherited
        # proxy configuration and CA trust for non-loopback destinations.
        environment.update(NICO_BASE_URL=fixture.url, NO_PROXY="localhost,127.0.0.1,::1", no_proxy="localhost,127.0.0.1,::1")
        if env:
            environment.update(env)
        result = subprocess.run([self.binary, "--no-progress", "--retries", "1", *args],
                                input=stdin, capture_output=True, text=True, env=environment, timeout=timeout)
        self.assertFalse(fixture.errors, fixture.errors)
        return result

    def json_result(self, result, code=0):
        if code == 0:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stderr)
        value = json.loads(result.stdout)
        self.assertEqual(set(value), {"inputs", "invalid", "targets", "errors", "output_count", "items"})
        self.assertEqual(set(value["inputs"]), {"total", "valid", "invalid"})
        for key in ("invalid", "targets", "errors", "items"):
            self.assertIsInstance(value[key], list, key + " must be an array, including when empty")
        for target in value["targets"]:
            self.assertEqual(set(target), {"type", "id", "items", "error"})
            self.assertIsInstance(target["items"], list)
            self.assertIsInstance(target["error"], str)
        self.assertEqual(value["output_count"], len(value["items"]))
        return value

    def test_user_mylist_schema_sort_and_headers(self):
        with Fixture(single_page) as fixture:
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/10", "nicovideo.jp/mylist/9", "nicovideo.jp/user/2", "bad", "--json", "--url"))
            self.assertEqual(value["inputs"], {"total": 4, "valid": 3, "invalid": 1})
            self.assertEqual(value["invalid"], ["bad"])
            self.assertEqual(value["items"], ["sm2", "sm9", "sm10"])
            self.assertEqual([(t["type"], t["id"]) for t in value["targets"]], [("mylist", "9"), ("user", "2"), ("user", "10")])
            self.assertEqual(value["errors"], [])
            for request in fixture.records:
                headers = {k.lower(): v for k, v in request.headers.items()}
                self.assertEqual(headers.get("x-frontend-id"), "6")
                self.assertEqual(headers.get("accept"), "*/*")

    def test_empty_arrays_and_404(self):
        with Fixture(lambda r: Reply(status=404)) as fixture:
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json"))
            self.assertEqual(value["items"], [])
            self.assertEqual(value["targets"][0]["items"], [])
            self.assertEqual(value["errors"], [])
            self.assertEqual(len(fixture.records), 1)

    def test_http_redirects_follow_relative_locations(self):
        for status in (301, 302, 303, 307, 308):
            with self.subTest(status=status):
                def respond(r):
                    if r.page == 1:
                        return Reply(status=status, headers={"Location": "/v3/users/1/videos?pageSize=100&page=2"})
                    return Reply(payload(r.kind, [video("sm2")], 1))
                with Fixture(respond) as fixture:
                    value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json", "-P2"))
                    self.assertEqual(value["items"], ["sm2"])
                    self.assertEqual([r.page for r in fixture.records], [1, 2])

    def test_http_redirect_loop_is_bounded(self):
        with Fixture(lambda r: Reply(status=302, headers={"Location": r.path})) as fixture:
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json"), code=1)
            self.assertEqual(value["items"], [])
            self.assertEqual(len(fixture.records), 10)

    def test_input_precedence_partial_regex_and_lengths(self):
        inputs = ["prefix nicovideo.jp/mylist/77 nicovideo.jp/user/2 suffix",
                  "nicovideo.jp/user/12345678999", "nicovideo.jp/mylist/12345678901299"]
        with Fixture(single_page) as fixture:
            value = self.json_result(self.run_cli(fixture, *inputs, "--json"))
            self.assertEqual({(t["type"], t["id"]) for t in value["targets"]},
                             {("user", "2"), ("user", "123456789"), ("mylist", "123456789012")})

    def test_args_file_stdin_and_no_sort_input_order(self):
        with tempfile.TemporaryDirectory() as directory, Fixture(single_page) as fixture:
            source = Path(directory) / "inputs.txt"
            source.write_text("\u3000nicovideo.jp/user/2\u00a0\n\n\u00a0\u3000\ninvalid\n", encoding="utf-8")
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/3", "--input-file", str(source), "--stdin", "--no-sort", "--json", stdin="\nnicovideo.jp/mylist/1\n"))
            self.assertEqual(value["items"], ["sm3", "sm2", "sm1"])
            self.assertEqual(value["inputs"], {"total": 4, "valid": 3, "invalid": 1})

    def test_strict_overrides_best_effort(self):
        with Fixture(single_page) as fixture:
            result = self.run_cli(fixture, "bad", "nicovideo.jp/user/1", "--json", "--strict", "--best-effort")
            value = self.json_result(result, code=1)
            self.assertEqual(value["items"], ["sm1"])
            self.assertIn("invalid input", result.stderr.lower())

    def test_invalid_default_skips_and_bool_last_value_wins(self):
        with Fixture(single_page) as fixture:
            value = self.json_result(self.run_cli(fixture, "bad", "--strict", "--strict=false", "--json"))
            self.assertEqual(value["inputs"]["invalid"], 1)
            self.assertEqual(value["targets"], [])

    def test_empty_positional_argument_counts_as_invalid(self):
        with Fixture(single_page) as fixture:
            value = self.json_result(self.run_cli(fixture, "", "nicovideo.jp/user/1", "--json"))
            self.assertEqual(value["inputs"], {"total": 2, "valid": 1, "invalid": 1})
            self.assertEqual(value["invalid"], [""])
            self.assertEqual(value["items"], ["sm1"])

    def test_json_invalid_utf8_input_fails_without_partial_json(self):
        with tempfile.TemporaryDirectory() as directory, Fixture(single_page) as fixture:
            source = Path(directory) / "invalid-utf8.txt"
            source.write_bytes(b"\xff\n")
            result = self.run_cli(fixture, "--input-file", str(source), "--json")
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "", "invalid UTF-8 must not produce a partial JSON object")

    def test_validation_and_removed_flags(self):
        invalid = [["--concurrency-targets", "0"], ["--concurrency-pages", "0"], ["--concurrency-http", "-1"],
                   ["--retries", "0"], ["--timeout", "0s"], ["--rate-limit", "-1"], ["--min-interval", "-1ms"],
                   ["--dateafter", "20260230"], ["--dateafter", "20260102", "--datebefore", "20260101"],
                   ["--concurrency", "2"], ["--page-concurrency", "2"], ["--http-concurrency", "2"],
                   ["--adaptive-http"], ["--adaptive-concurrency"], ["--adaptive-http-concurrency"],
                   ["--tab"], ["-t"], ["--max-pages=1"], ["--max-videos=1"], ["-n", "2"], ["--not-an-option"]]
        with Fixture(single_page) as fixture:
            for flags in invalid:
                with self.subTest(flags=flags):
                    result = self.run_cli(fixture, "nicovideo.jp/user/1", *flags)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertEqual(result.stdout, "")
            self.assertEqual(fixture.records, [])

    def test_no_inputs_and_missing_input_file_are_errors(self):
        with Fixture(single_page) as fixture:
            self.assertNotEqual(self.run_cli(fixture).returncode, 0)
            self.assertNotEqual(self.run_cli(fixture, "--input-file", "/no/such/nico-input-file").returncode, 0)

    def test_help_and_version_without_inputs(self):
        with Fixture(single_page) as fixture:
            for option in ("--help", "-h", "--version", "-v"):
                with self.subTest(option=option):
                    result = self.run_cli(fixture, option)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(result.stdout)
            self.assertEqual(fixture.records, [])

    def test_input_line_limit_preserves_preceding_results(self):
        with tempfile.TemporaryDirectory() as directory, Fixture(single_page) as fixture:
            source = Path(directory) / "inputs.txt"
            source.write_text("nicovideo.jp/user/1\n" + "x" * (1024 * 1024 + 1) + "\n", encoding="utf-8")
            result = self.run_cli(fixture, "--input-file", str(source), "--best-effort")
            self.assertNotEqual(result.returncode, 0, result.stderr)

    def test_input_error_cancels_inflight_fetch_promptly(self):
        with Fixture(lambda r: Reply(payload(r.kind), delay=3)) as fixture:
            self.assert_input_error_cancels_fetch(fixture.url, lambda: fixture.records)

    def assert_input_error_cancels_fetch(self, url, request_started, env=None):
        environment = os.environ.copy()
        environment.update(NICO_BASE_URL=url, NO_PROXY="localhost,127.0.0.1", no_proxy="localhost,127.0.0.1")
        if env:
            environment.update(env)
        process = subprocess.Popen([self.binary, "--stdin", "--json", "--no-progress", "--best-effort", "--retries=1", "nicovideo.jp/user/1"],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        try:
            deadline = time.monotonic() + 3
            while not request_started() and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(request_started(), "valid target must start before the input error is introduced")
            writer = process.stdin
            process.stdin = None  # The writer thread owns the input pipe.
            def send_bad_line():
                try:
                    writer.write("x" * (1024 * 1024 + 1) + "\n")
                    writer.close()
                except (BrokenPipeError, OSError):
                    pass
            thread = threading.Thread(target=send_bad_line, daemon=True)
            started = time.monotonic()
            thread.start()
            stdout, stderr = process.communicate(timeout=1.5)
            self.assertLess(time.monotonic() - started, 1.5)
            self.assertNotEqual(process.returncode, 0, stderr)
            self.assertIn("input", stderr.lower())
            thread.join(timeout=1)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_broken_stdout_cancels_other_targets_promptly(self):
        def respond(r):
            reply = single_page(r)
            reply.delay = 0.05 if r.identifier == "1" else 3
            return reply
        with Fixture(respond) as fixture:
            environment = os.environ.copy()
            environment.update(NICO_BASE_URL=fixture.url, NO_PROXY="localhost,127.0.0.1", no_proxy="localhost,127.0.0.1")
            read_fd, write_fd = os.pipe()
            os.close(read_fd)
            try:
                started = time.monotonic()
                process = subprocess.Popen([self.binary, "--no-sort", "--no-progress", "--retries=1", "-T2", "nicovideo.jp/user/1", "nicovideo.jp/user/2"],
                                           stdout=write_fd, stderr=subprocess.PIPE, text=True, env=environment)
            finally:
                os.close(write_fd)
            try:
                _, stderr = process.communicate(timeout=1.5)
                self.assertLess(time.monotonic() - started, 1.5)
                self.assertNotEqual(process.returncode, 0, stderr)
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_comment_is_exclusive_and_dates_are_utc_inclusive(self):
        videos = [video("sm1", 5), video("sm2", 6, "2025-12-31T23:59:59Z"),
                  video("sm3", 6, "2026-01-01T09:00:00+09:00"),
                  video("sm4", 6, "2026-01-02T08:59:59+09:00"),
                  video("sm5", 6, "2026-01-02T09:00:00+09:00")]
        with Fixture(lambda r: Reply(payload(r.kind, videos if r.page == 1 else []))) as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "-c5", "-a20260101", "-b20260101")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "sm3\nsm4\n")

    def test_integer_prefixes_and_native_width(self):
        def respond(r):
            return Reply(payload(r.kind, [video("sm1", comments=2)] if r.page == 1 else [], 1))
        with Fixture(respond) as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "-c0x1", "-T0x1", "-P02")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "sm1\n")
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "--comment=2147483648", "-P2")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_numeric_sort_dedupe_urls_and_short_option_cluster(self):
        with Fixture(lambda r: Reply(payload(r.kind, [video("sm10"), video("sm2"), video("sm2")] if r.page == 1 else []))) as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "--dedupe", "-uA", "-T1", "-P1", "-H1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "https://www.nicovideo.jp/watch/sm2\nhttps://www.nicovideo.jp/watch/sm10\n")
            self.assertIn("output_count=2", result.stderr)

    def test_json_target_items_remain_unsorted_and_undeduped(self):
        def respond(r):
            return Reply(payload(r.kind, [video("sm10"), video("sm2"), video("sm2")] if r.page == 1 else []))
        with Fixture(respond) as fixture:
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "nicovideo.jp/mylist/1", "--json", "--dedupe"))
            self.assertEqual(value["items"], ["sm2", "sm10"])
            for target in value["targets"]:
                self.assertEqual(target["items"], ["sm10", "sm2", "sm2"])

    def test_no_sort_streams_before_all_targets_finish(self):
        def respond(r):
            reply = single_page(r)
            if r.identifier == "2":
                reply.delay = 0.5
            return reply
        with Fixture(respond) as fixture:
            environment = os.environ.copy()
            environment.update(NICO_BASE_URL=fixture.url, NO_PROXY="localhost,127.0.0.1", no_proxy="localhost,127.0.0.1")
            process = subprocess.Popen([self.binary, "--no-progress", "--retries", "1", "--no-sort", "nicovideo.jp/user/1", "nicovideo.jp/user/2"],
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
            try:
                first_line = queue.Queue()
                reader = threading.Thread(target=lambda: first_line.put(process.stdout.readline()), daemon=True)
                reader.start()
                self.assertEqual(first_line.get(timeout=3), "sm1\n")
                reader.join(timeout=1)
                self.assertIsNone(process.poll(), "unordered output should arrive while another target is running")
                stdout, stderr = process.communicate(timeout=5)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(stdout, "sm2\n")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_mylist_total_count_fallbacks(self):
        for total_key in ("totalCount", "totalItemCount", "data.totalCount"):
            with self.subTest(total_key=total_key):
                def respond(r):
                    return Reply(payload(r.kind, [video("sm" + str(r.page))] if r.page <= 3 else [], 300, total_key), delay=0.03)
                with Fixture(respond) as fixture:
                    value = self.json_result(self.run_cli(fixture, "nicovideo.jp/mylist/1", "--json", "-P3"))
                    self.assertEqual(value["items"], ["sm1", "sm2", "sm3"])
                    self.assertEqual([r.page for r in fixture.records].count(1), 1)
                    self.assertLessEqual(max(r.page for r in fixture.records), 3)

    def test_present_zero_negative_totals_do_not_become_unknown(self):
        for kind in ("user", "mylist"):
            for total in (0, -1):
                with self.subTest(kind=kind, total=total):
                    def respond(r):
                        return Reply(payload(r.kind, [video("sm1")], total)) if r.page == 1 else Reply(status=500)
                    with Fixture(respond) as fixture:
                        value = self.json_result(self.run_cli(fixture, "nicovideo.jp/" + kind + "/1", "--json", "-P2"))
                        self.assertEqual(value["items"], ["sm1"])
                        self.assertEqual(len(fixture.records), 1)

    def test_unknown_total_stays_sequential_until_empty(self):
        with Fixture(lambda r: Reply(payload(r.kind, [video("sm" + str(r.page))] if r.page <= 4 else []), delay=0.02)) as fixture:
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json", "-P8", "-A"))
            self.assertEqual(value["items"], ["sm1", "sm2", "sm3", "sm4"])
            self.assertEqual([r.page for r in fixture.records], [1, 2, 3, 4, 5])
            self.assertEqual(fixture.peak, 1)

    def test_parallel_failure_keeps_only_ordered_prefix(self):
        def respond(r):
            if r.page == 3:
                return Reply(status=500, delay=0.12)
            return Reply(payload(r.kind, [video("sm" + str(r.page))], 500), delay=0.08 if r.page == 2 else 0.01)
        with Fixture(respond) as fixture:
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json", "-P4"), code=1)
            self.assertEqual(value["items"], ["sm1", "sm2"])
            self.assertTrue(value["targets"][0]["error"])
            self.assertEqual(len(value["errors"]), 1)
            self.assertTrue(any(r.page == 4 for r in fixture.records), "fixture must exercise completed higher page")

    def test_earlier_empty_page_supersedes_later_error(self):
        def respond(r):
            if r.page == 2:
                return Reply(payload(r.kind), delay=0.10)
            if r.page == 3:
                return Reply(status=500)
            return Reply(payload(r.kind, [video("sm" + str(r.page))], 400))
        with Fixture(respond) as fixture:
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json", "-P3"))
            self.assertEqual(value["items"], ["sm1"])
            self.assertEqual(value["errors"], [])

    def test_partial_other_targets_and_best_effort(self):
        def respond(r):
            return Reply(status=403) if r.identifier == "2" else single_page(r)
        with Fixture(respond) as fixture:
            value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "nicovideo.jp/user/2", "--json", "--best-effort"))
            self.assertEqual(value["items"], ["sm1"])
            self.assertEqual(len(value["errors"]), 1)
            failed = next(t for t in value["targets"] if t["id"] == "2")
            self.assertEqual(failed["items"], [])
            self.assertTrue(failed["error"])

    def test_retries_are_attempt_count_with_exponential_backoff(self):
        with Fixture(lambda r: Reply(status=503) if r.attempt < 3 else Reply(payload(r.kind))) as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "--retries=3")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(fixture.records), 3)
            times = [r.started for r in fixture.records]
            self.assertGreaterEqual(times[1] - times[0], 0.075)
            self.assertGreaterEqual(times[2] - times[1], 0.16)

    def test_retry_after_seconds_and_http_date(self):
        for mode in ("seconds", "date"):
            with self.subTest(mode=mode):
                def respond(r):
                    if r.attempt == 1:
                        value = "1" if mode == "seconds" else email.utils.format_datetime(dt.datetime.now(dt.timezone.utc) + dt.timedelta(seconds=2), usegmt=True)
                        return Reply(status=429, headers={"Retry-After": value})
                    return Reply(payload(r.kind))
                with Fixture(respond) as fixture:
                    result = self.run_cli(fixture, "nicovideo.jp/user/1", "--retries=2")
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(len(fixture.records), 2)
                    self.assertGreaterEqual(fixture.records[1].started - fixture.records[0].started, 0.85)

    def test_retry_wait_releases_http_slot(self):
        def respond(r):
            if r.identifier == "1" and r.attempt == 1:
                return Reply(status=429, headers={"Retry-After": "1"})
            return Reply(payload(r.kind))
        with Fixture(respond) as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "nicovideo.jp/user/2", "--retries=2", "-H1", "-T2")
            self.assertEqual(result.returncode, 0, result.stderr)
            one = [r for r in fixture.records if r.identifier == "1"]
            two = next(r for r in fixture.records if r.identifier == "2")
            self.assertLess(two.started, one[1].started - 0.5)
            self.assertEqual(fixture.peak, 1)

    def test_global_pacing_includes_targets_pages_and_retries(self):
        def respond(r):
            if r.identifier == "1" and r.page == 1 and r.attempt == 1:
                return Reply(status=500)
            return Reply(payload(r.kind, [video("sm1")] if r.page == 1 else []))
        for flags in (("--min-interval", "60ms"), ("--rate-limit", "16.6666666667"), ("--rate-limit", "100", "--min-interval", "60ms")):
            with self.subTest(flags=flags), Fixture(respond) as fixture:
                result = self.run_cli(fixture, "nicovideo.jp/user/1", "nicovideo.jp/user/2", "--retries=2", "-T2", "-P3", *flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                times = sorted(r.started for r in fixture.records)
                self.assertEqual(len(times), 5)
                for left, right in zip(times, times[1:]):
                    self.assertGreaterEqual(right - left, 0.045, "command-wide dispatch pacing")

    def assert_pending_request_is_cancellable(self, fixture, *flags, env=None):
        environment = os.environ.copy()
        environment.update(NICO_BASE_URL=fixture.url, NO_PROXY="localhost,127.0.0.1", no_proxy="localhost,127.0.0.1")
        if env:
            environment.update(env)
        process = subprocess.Popen([self.binary, "--no-progress", "--retries=2", "nicovideo.jp/user/1", *flags],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
        try:
            deadline = time.monotonic() + 3
            while not fixture.records and process.poll() is None and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(fixture.records, "first request must dispatch before the extreme delay is tested")
            time.sleep(0.35)
            self.assertEqual(len(fixture.records), 1, "an overflowing delay must not admit an immediate second request")
            self.assertIsNone(process.poll(), "the process must remain waiting, rather than silently disable the delay")
            started = time.monotonic()
            process.send_signal(signal.SIGINT)
            stdout, stderr = process.communicate(timeout=1)
            self.assertLess(time.monotonic() - started, 1)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertEqual(stdout, "", "cancellation preserves the successful-empty target convention")
            self.assertFalse(fixture.errors, fixture.errors)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    @unittest.skipIf(os.name == "nt", "POSIX SIGINT edge-duration cancellation contract")
    def test_extreme_tiny_positive_rate_waits_and_is_cancellable(self):
        if OPTIONS.profile == "go-reference":
            self.skipTest("V-specific overflow regression; current Go baseline can disable an overflowing rate interval")
        for rate in ("1e-300", "1e-10"):
            with self.subTest(rate=rate), Fixture(single_page) as fixture:
                self.assert_pending_request_is_cancellable(fixture, "--rate-limit", rate)

    @unittest.skipIf(os.name == "nt", "POSIX SIGINT edge-duration cancellation contract")
    def test_extreme_representable_interval_waits_and_is_cancellable(self):
        if OPTIONS.profile == "go-reference":
            self.skipTest("V-specific saturating monotonic-deadline regression; outside Go parity profile")
        for adaptive in (False, True):
            with self.subTest(adaptive=adaptive), Fixture(single_page) as fixture:
                self.assert_pending_request_is_cancellable(fixture, "--min-interval", "9223372036854000000ns", *(["-A"] if adaptive else []))

    @unittest.skipIf(os.name == "nt", "POSIX SIGINT edge-duration cancellation contract")
    def test_extreme_retry_after_waits_and_is_cancellable(self):
        if OPTIONS.profile == "go-reference":
            self.skipTest("V-specific Retry-After overflow regression; current Go baseline can overflow or discard these delays")
        values = ("9223372035", "9223372036854775807", "+9223372036854775807", "9999999999999999999999999999999999999", "Fri, 31 Dec 9999 23:59:59 GMT")
        for value in values:
            for adaptive in (False, True):
                with self.subTest(value=value, adaptive=adaptive), Fixture(lambda r: Reply(status=429, headers={"Retry-After": value})) as fixture:
                    self.assert_pending_request_is_cancellable(fixture, *(["-A"] if adaptive else []))

    @unittest.skipIf(os.name == "nt", "POSIX SIGINT edge-duration cancellation contract")
    def test_extreme_timeout_serves_normally_and_is_cancellable(self):
        if OPTIONS.profile == "go-reference":
            self.skipTest("V-specific near-maximum wall-deadline arithmetic regression")
        maximum = "9223372036854000000ns"
        with Fixture(single_page) as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "--timeout", maximum)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "sm1\n", "a near-maximum positive timeout must not wrap into an immediate deadline")
            self.assertEqual(len(fixture.records), 2)
        with Fixture(lambda r: Reply(payload(r.kind), delay=3)) as fixture:
            self.assert_pending_request_is_cancellable(fixture, "--timeout", maximum)

    def test_target_page_http_caps_and_mixed_last_override(self):
        def respond(r):
            return Reply(payload(r.kind, [video("sm" + str(int(r.identifier) * 100 + r.page))] if r.page <= 5 else [], 500), delay=0.04)
        targets = ["nicovideo.jp/user/" + str(i) for i in range(1, 6)]
        for flags, expected_peak, expected_per_target in ((["-T1", "-P1"], 1, 1),
                (["-T3", "-P4", "-H2"], 2, 2),
                (["-A", "--concurrency-targets=4", "-T1", "--concurrency-pages=4", "-P1", "--concurrency-http=8", "-H1"], 1, 1),
                (["-T1", "-A", "-P2", "-H0"], 2, 2)):
            with self.subTest(flags=flags), Fixture(respond) as fixture:
                result = self.run_cli(fixture, *targets, *flags)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLessEqual(fixture.peak, expected_peak)
                self.assertGreaterEqual(fixture.peak, expected_peak, "fixture must supply enough work to use the cap")
                self.assertLessEqual(max(fixture.target_peaks.values()), expected_per_target)

    def test_adaptive_429_pauses_new_requests_globally(self):
        def respond(r):
            if r.identifier == "1" and r.page == 1 and r.attempt == 1:
                return Reply(status=429, headers={"Retry-After": "1"}, delay=0.02)
            return Reply(payload(r.kind, [video("sm1")] if r.page == 1 else []), delay=0.12)
        with Fixture(respond) as fixture:
            result = self.run_cli(fixture, *["nicovideo.jp/user/" + str(i) for i in range(1, 5)], "-A", "--retries=2")
            self.assertEqual(result.returncode, 0, result.stderr)
            throttled = next(r for r in fixture.records if r.identifier == "1" and r.attempt == 1)
            during_pause = [r for r in fixture.records if 0.10 < r.started - throttled.started < 0.90]
            self.assertEqual(during_pause, [], "new work dispatched during adaptive command-wide cooldown")

    def test_adaptive_grows_with_sustained_known_total_supply(self):
        pages = 225
        def respond(r):
            return Reply(payload(r.kind, [video("sm" + str(r.page))], pages * 100), delay=0.04)
        with Fixture(respond) as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "-A", "-T1", "--json", "--http-metrics", timeout=20)
            value = self.json_result(result)
            self.assertEqual(value["items"], ["sm" + str(page) for page in range(1, pages + 1)])
            self.assertEqual(len(fixture.records), pages)
            metrics = [json.loads(line) for line in result.stderr.splitlines() if line.startswith("{") and json.loads(line).get("msg") == "http_metrics"]
            self.assertEqual(len(metrics), 1)
            adaptive = metrics[0]["http"]["adaptive"]
            self.assertTrue(any(d["to"] > adaptive["initial"] for d in adaptive["decisions"]),
                            "adaptive budget must grow under sustained healthy supply: " + json.dumps(adaptive))

    def test_invalid_json_utf8_duplicate_names_and_timestamps(self):
        bad = [b"{", b'{"meta":{"status":200},"data":{"items":[],"items":[]}}',
               b'{"meta":{"status":200},"data":{"items":[]},"bad":"\xff"}',
               payload("user", [video("sm1", date="not-a-timestamp")]),
               payload("user", [video("sm1", date="2026-01-01T25:00:00Z")]),
               payload("user", [video("sm1", date="2026-02-30T00:00:00Z")])]
        for body in bad:
            with self.subTest(body=body[:100]), Fixture(lambda r: Reply(body)) as fixture:
                value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json"), code=1)
                self.assertEqual(value["items"], [])
                self.assertTrue(value["targets"][0]["error"])

    def test_gzip_decoding(self):
        with Fixture(lambda r: Reply(payload(r.kind, [video("sm1")] if r.page == 1 else []), compressed=True)) as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "sm1\n")

    def test_success_body_limit_after_gzip_and_chunking(self):
        prefix = b'{"meta":{"status":200},"data":{"items":[]},"padding":"'
        suffix = b'"}'
        for compressed, chunked in ((False, False), (False, True), (True, False), (True, True)):
            with self.subTest(compressed=compressed, chunked=chunked):
                body = prefix + b"x" * (8 * 1024 * 1024 + 1 - len(prefix) - len(suffix)) + suffix
                with Fixture(lambda r: Reply(body, compressed=compressed, chunked=chunked)) as fixture:
                    value = self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json", timeout=25), code=1)
                    self.assertEqual(value["items"], [])
                    self.assertTrue(value["targets"][0]["error"])

    def test_exact_body_limit_is_accepted(self):
        prefix = b'{"meta":{"status":200},"data":{"items":[]},"padding":"'
        suffix = b'"}'
        body = prefix + b"x" * (8 * 1024 * 1024 - len(prefix) - len(suffix)) + suffix
        with Fixture(lambda r: Reply(body, chunked=True, compressed=True)) as fixture:
            self.json_result(self.run_cli(fixture, "nicovideo.jp/user/1", "--json", timeout=25))

    def test_timeout_is_prompt_successful_empty(self):
        with Fixture(lambda r: Reply(payload(r.kind, [video("sm1")]), delay=0.8)) as fixture:
            started = time.monotonic()
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "--timeout", "80ms", timeout=3)
            self.assertLess(time.monotonic() - started, 0.6)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    @unittest.skipIf(os.name == "nt", "POSIX SIGINT test; Windows exercised by remaining CLI contracts")
    def test_sigint_cancels_promptly(self):
        with Fixture(lambda r: Reply(payload(r.kind), delay=2)) as fixture:
            environment = os.environ.copy()
            environment.update(NICO_BASE_URL=fixture.url, NO_PROXY="localhost,127.0.0.1", no_proxy="localhost,127.0.0.1")
            process = subprocess.Popen([self.binary, "--no-progress", "nicovideo.jp/user/1"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=environment)
            try:
                deadline = time.monotonic() + 3
                while not fixture.records and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(fixture.records)
                process.send_signal(signal.SIGINT)
                stdout, stderr = process.communicate(timeout=1)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(stdout, "")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate()

    def test_metrics_logfile_and_stdout_separation(self):
        with tempfile.TemporaryDirectory() as directory, Fixture(single_page) as fixture:
            logfile = Path(directory) / "events.jsonl"
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "--json", "--http-metrics", "--logfile", str(logfile))
            self.json_result(result)
            events = [json.loads(line) for line in logfile.read_text(encoding="utf-8").splitlines() if line]
            metrics = [event for event in events if event.get("msg") == "http_metrics"]
            self.assertEqual(len(metrics), 1)
            self.assertNotIn("nicovideo.jp", json.dumps(metrics))
            self.assertIn("summary inputs=1 valid=1 invalid=0 fetch_ok=1 fetch_err=0 output_count=1", result.stderr)

    def test_http_proxy_absolute_form_and_basic_auth(self):
        if OPTIONS.profile == "go-reference":
            self.skipTest("Go ProxyFromEnvironment always bypasses loopback, independent of NO_PROXY")
        with Fixture(single_page) as origin, Fixture(single_page) as proxy:
            address = proxy.url.removesuffix("/v3").replace("http://", "http://fixture:secret@")
            result = self.run_cli(origin, "nicovideo.jp/user/1", env={"HTTP_PROXY": address, "http_proxy": address, "NO_PROXY": "", "no_proxy": ""})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "sm1\n")
            self.assertEqual(origin.records, [], "requests must reach the explicitly configured local proxy")
            self.assertEqual(len(proxy.records), 2)
            for request in proxy.records:
                self.assertTrue(request.path.startswith(origin.url + "/"))
                headers = {k.lower(): v for k, v in request.headers.items()}
                self.assertEqual(headers.get("proxy-authorization"), "Basic Zml4dHVyZTpzZWNyZXQ=")

    def test_no_proxy_cidr_and_host_port(self):
        with Fixture(single_page) as origin, Fixture(single_page) as proxy:
            for exclusion in ("127.0.0.0/8", "127.0.0.1:" + str(origin.server.server_port)):
                with self.subTest(exclusion=exclusion):
                    result = self.run_cli(origin, "nicovideo.jp/user/1", env={"HTTP_PROXY": proxy.url.removesuffix("/v3"), "NO_PROXY": exclusion, "no_proxy": exclusion})
                    self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(origin.records), 4)
            self.assertEqual(proxy.records, [])


class TLSContracts(CLIContracts):
    # Inherit helpers only; avoid running the CLI suite twice.
    def runTest(self):
        pass

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        if not shutil.which("openssl"):
            raise unittest.SkipTest("OpenSSL CLI is required to generate ephemeral local TLS certificates")
        cls.temp = tempfile.TemporaryDirectory()
        root = Path(cls.temp.name)
        cls.ca = root / "ca.pem"
        def openssl(*args):
            subprocess.run(["openssl", *map(str, args)], cwd=root, capture_output=True, check=True)
        openssl("req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=loopback-test-root", "-keyout", "ca.key", "-out", cls.ca)
        for name, san in (("valid", "DNS:localhost,IP:127.0.0.1"), ("wrong-host", "DNS:wrong-host.invalid")):
            extension = root / (name + ".ext")
            extension.write_text("subjectAltName=" + san + "\nextendedKeyUsage=serverAuth\n", encoding="ascii")
            openssl("req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=" + name, "-keyout", name + ".key", "-out", name + ".csr")
            openssl("x509", "-req", "-in", name + ".csr", "-CA", cls.ca, "-CAkey", "ca.key", "-CAcreateserial", "-days", "1", "-extfile", extension, "-out", name + ".pem")
        cls.root = root

    @classmethod
    def tearDownClass(cls):
        if hasattr(cls, "temp"):
            cls.temp.cleanup()

    def tls_fixture(self, name="valid", respond=single_page):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(self.root / (name + ".pem"), self.root / (name + ".key"))
        return Fixture(respond, context)

    def test_tls_trusted_ca_success(self):
        for hostname in ("127.0.0.1", "localhost"):
            with self.subTest(hostname=hostname), self.tls_fixture() as fixture:
                fixture.url = fixture.url.replace("127.0.0.1", hostname)
                result = self.run_cli(fixture, "nicovideo.jp/user/1", env={"SSL_CERT_FILE": str(self.ca)})
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "sm1\n")

    def test_tls_input_error_cancels_delayed_response_promptly(self):
        with self.tls_fixture(respond=lambda r: Reply(payload(r.kind), delay=3)) as fixture:
            self.assert_input_error_cancels_fetch(fixture.url, lambda: fixture.records,
                                                  env={"SSL_CERT_FILE": str(self.ca)})

    def test_tls_input_error_cancels_stalled_handshake_promptly(self):
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            listener.settimeout(3)
            started = threading.Event()
            release = threading.Event()
            def stall_handshake():
                try:
                    with listener.accept()[0] as connection:
                        connection.settimeout(3)
                        if connection.recv(4096):
                            started.set()  # Observe ClientHello before introducing input failure.
                            release.wait(timeout=3)
                except OSError:
                    pass
            server = threading.Thread(target=stall_handshake, daemon=True)
            server.start()
            try:
                self.assert_input_error_cancels_fetch(f"https://127.0.0.1:{listener.getsockname()[1]}/v3",
                                                      started.is_set, env={"SSL_CERT_FILE": str(self.ca)})
            finally:
                release.set()
                server.join(timeout=4)

    @unittest.skipIf(os.name == "nt", "POSIX SIGINT edge-duration cancellation contract")
    def test_tls_extreme_timeout_serves_normally_and_is_cancellable(self):
        if OPTIONS.profile == "go-reference":
            self.skipTest("V-specific near-maximum TLS-backend deadline arithmetic regression")
        maximum = "9223372036854000000ns"
        trust = {"SSL_CERT_FILE": str(self.ca)}
        with self.tls_fixture() as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", "--timeout", maximum, env=trust)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "sm1\n")
            self.assertEqual(len(fixture.records), 2)
        with self.tls_fixture(respond=lambda r: Reply(payload(r.kind), delay=3)) as fixture:
            self.assert_pending_request_is_cancellable(fixture, "--timeout", maximum, env=trust)

    def test_tls_untrusted_ca_rejected(self):
        with self.tls_fixture() as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1")
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(fixture.records, [])

    def test_tls_hostname_mismatch_rejected(self):
        with self.tls_fixture("wrong-host") as fixture:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", env={"SSL_CERT_FILE": str(self.ca)})
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertEqual(fixture.records, [])

    def test_tls_http_connect_proxy_preserves_verification(self):
        if OPTIONS.profile == "go-reference":
            self.skipTest("Go ProxyFromEnvironment always bypasses loopback, independent of NO_PROXY")
        with self.tls_fixture() as fixture, TunnelProxy(fixture.server.server_port) as proxy:
            address = proxy.url.replace("http://", "http://fixture:secret@")
            result = self.run_cli(fixture, "nicovideo.jp/user/1", env={"SSL_CERT_FILE": str(self.ca), "HTTPS_PROXY": address, "https_proxy": address, "NO_PROXY": "", "no_proxy": ""})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "sm1\n")
            self.assertTrue(proxy.records)
            for _, headers in proxy.records:
                self.assertEqual(headers.get("proxy-authorization"), "Basic Zml4dHVyZTpzZWNyZXQ=")
            for request in fixture.records:
                self.assertNotIn("proxy-authorization", {key.lower() for key in request.headers})

    def test_tls_untrusted_ca_still_rejected_through_connect(self):
        if OPTIONS.profile == "go-reference":
            self.skipTest("Go ProxyFromEnvironment always bypasses loopback, independent of NO_PROXY")
        with self.tls_fixture() as fixture, TunnelProxy(fixture.server.server_port) as proxy:
            result = self.run_cli(fixture, "nicovideo.jp/user/1", env={"HTTPS_PROXY": proxy.url, "https_proxy": proxy.url, "NO_PROXY": "", "no_proxy": ""})
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")
            self.assertTrue(proxy.records)
            self.assertEqual(fixture.records, [])


if __name__ == "__main__":
    OPTIONS = PARSER.parse_args()
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()
    suite.addTests(loader.loadTestsFromTestCase(CLIContracts))
    for name in loader.getTestCaseNames(TLSContracts):
        if name.startswith("test_tls_"):
            suite.addTest(TLSContracts(name))
    if OPTIONS.only:
        suite = unittest.TestSuite(test for group in suite for test in (group if isinstance(group, unittest.TestSuite) else [group]) if OPTIONS.only in test.id())
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    sys.exit(not result.wasSuccessful())
