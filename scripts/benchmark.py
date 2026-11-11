#!/usr/bin/env python3
"""Reproducible process-level loopback benchmark; output JSON evidence."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from loopback import Fixture, Reply, payload, video

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", action="append", required=True, metavar="NAME=PATH")
parser.add_argument("--repetitions", type=int, default=5)
parser.add_argument("--targets", type=int, default=12)
parser.add_argument("--pages", type=int, default=5)
parser.add_argument("--latency-ms", type=float, default=10)
parser.add_argument("--format", choices=("json", "lines"), default="json")
parser.add_argument("--output", default="benchmark-results.json")
parser.add_argument("--http-metrics", action="store_true", help="record V aggregate timing counters (not comparable to wall-time slices)")
parser.add_argument("--payload", choices=("minimal", "extended"), default="minimal")
args = parser.parse_args()
if args.repetitions < 1 or args.targets < 1 or args.pages < 1 or args.latency_ms < 0:
    parser.error("counts must be positive and latency nonnegative")

def respond(request):
    items = [video("sm" + str(int(request.identifier) * 100000 + request.page * 100 + i)) for i in range(100)] if request.page <= args.pages else []
    if args.payload == "extended":
        for item in items:
            item.update(title="動画 title 😀", shortDescription="Unicode and \"quoted\" text\n" * 8,
                        duration=123, isChannelVideo=False, isPaymentRequired=False,
                        thumbnail={"url": "https://example.invalid/thumbnail.jpg"},
                        owner={"ownerType": "user", "id": "1", "name": "投稿者"},
                        unknown={"nested": [None, True, {"text": "x" * 64}]})
    return Reply(payload(request.kind, items, args.pages * 100), delay=args.latency_ms / 1000)

report = {"scope": "Synthetic loopback CLI process wall time; includes startup, HTTP, JSON, sorting, output; no live API performance inference.",
          "platform": platform.platform(), "python": platform.python_version(),
          "parameters": {"targets": args.targets, "pages_per_target": args.pages, "items_per_page": 100,
                         "response_delay_ms": args.latency_ms, "warmups": 1, "repetitions": args.repetitions,
                         "output_format": args.format, "payload": args.payload,
                         "execution_order": "one warmup per binary, then alternating forward/reverse per repetition",
                         "flags": ["-T4", "-P4", "-H8", "--no-progress", "--retries=1"] + (["--json"] if args.format == "json" else []) + (["--http-metrics"] if args.http_metrics else [])}, "binaries": {}}
expected_items = ["sm" + str(target * 100000 + page * 100 + i)
                  for target in range(1, args.targets + 1)
                  for page in range(1, args.pages + 1) for i in range(100)]
expected_items.sort(key=lambda item: int(item[2:]))
result_digest = None
binaries = []
for specification in args.binary:
    name, separator, binary = specification.partition("=")
    if not separator or not name or name in report["binaries"]:
        parser.error("--binary must be UNIQUE_NAME=PATH")
    binary = str(Path(binary).resolve())
    binaries.append((name, binary))
    report["binaries"][name] = {"path": binary, "sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(), "samples": []}
for iteration in range(args.repetitions + 1):
    for name, binary in (binaries if iteration % 2 else list(reversed(binaries))):
        with Fixture(respond) as fixture:
            environment = os.environ.copy()
            environment.update(NICO_BASE_URL=fixture.url, NO_PROXY="localhost,127.0.0.1,::1", no_proxy="localhost,127.0.0.1,::1")
            command = [binary, *report["parameters"]["flags"]] + ["nicovideo.jp/user/" + str(i) for i in range(1, args.targets + 1)]
            started = time.perf_counter()
            result = subprocess.run(command, capture_output=True, text=True, env=environment, timeout=120)
            elapsed = time.perf_counter() - started
            if result.returncode:
                raise RuntimeError(name + " failed: " + result.stderr)
            expected = args.targets * args.pages * 100
            value = json.loads(result.stdout) if args.format == "json" else {"items": result.stdout.splitlines(), "output_count": len(result.stdout.splitlines()), "errors": []}
            if value["output_count"] != expected or value["items"] != expected_items or value["errors"]:
                raise RuntimeError(name + " returned incorrect output")
            digest = hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            if result_digest is not None and digest != result_digest:
                raise RuntimeError(name + " produced a different complete JSON result")
            result_digest = digest
            if fixture.errors:
                raise RuntimeError(str(fixture.errors))
            if len(fixture.records) != args.targets * args.pages:
                raise RuntimeError(name + " returned an unexpected request count")
            metrics = {}
            if args.http_metrics:
                events = [json.loads(line) for line in result.stderr.splitlines() if line.startswith("{")]
                metrics = next(event["http"] for event in events if event.get("msg") == "http_metrics")
            if iteration:
                sample = {"wall_seconds": elapsed, "requests": len(fixture.records), "http_peak": fixture.peak,
                          "stdout_bytes": len(result.stdout.encode()), "output_count": expected, "result_sha256": digest,
                          "items_sha256": hashlib.sha256(json.dumps(value["items"], separators=(",", ":")).encode()).hexdigest()}
                if args.http_metrics:
                    sample["http_metrics"] = metrics
                report["binaries"][name]["samples"].append(sample)
for result in report["binaries"].values():
    elapsed = [sample["wall_seconds"] for sample in result["samples"]]
    result.update(wall_median_seconds=statistics.median(elapsed), wall_min_seconds=min(elapsed), wall_max_seconds=max(elapsed))
Path(args.output).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, indent=2))
