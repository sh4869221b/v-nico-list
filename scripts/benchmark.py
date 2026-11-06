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
args = parser.parse_args()
if args.repetitions < 1 or args.targets < 1 or args.pages < 1 or args.latency_ms < 0:
    parser.error("counts must be positive and latency nonnegative")

def respond(request):
    items = [video("sm" + str(int(request.identifier) * 100000 + request.page * 100 + i)) for i in range(100)] if request.page <= args.pages else []
    return Reply(payload(request.kind, items, args.pages * 100), delay=args.latency_ms / 1000)

report = {"scope": "Synthetic loopback CLI process wall time; includes startup, HTTP, JSON, sorting, output; no live API performance inference.",
          "platform": platform.platform(), "python": platform.python_version(),
          "parameters": {"targets": args.targets, "pages_per_target": args.pages, "items_per_page": 100,
                         "response_delay_ms": args.latency_ms, "warmups": 1, "repetitions": args.repetitions,
                         "output_format": args.format,
                         "flags": ["-T4", "-P4", "-H8", "--no-progress", "--retries=1"] + (["--json"] if args.format == "json" else [])}, "binaries": {}}
expected_items = ["sm" + str(target * 100000 + page * 100 + i)
                  for target in range(1, args.targets + 1)
                  for page in range(1, args.pages + 1) for i in range(100)]
expected_items.sort(key=lambda item: int(item[2:]))
result_digest = None
for specification in args.binary:
    name, separator, binary = specification.partition("=")
    if not separator or not name:
        parser.error("--binary must be NAME=PATH")
    binary = str(Path(binary).resolve())
    samples = []
    for iteration in range(args.repetitions + 1):
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
            if iteration:
                samples.append({"wall_seconds": elapsed, "requests": len(fixture.records), "http_peak": fixture.peak,
                                "stdout_bytes": len(result.stdout.encode()), "output_count": expected, "result_sha256": digest,
                                "items_sha256": hashlib.sha256(json.dumps(value["items"], separators=(",", ":")).encode()).hexdigest()})
    report["binaries"][name] = {"path": binary, "sha256": hashlib.sha256(Path(binary).read_bytes()).hexdigest(),
                                "samples": samples, "wall_median_seconds": statistics.median(s["wall_seconds"] for s in samples),
                                "wall_min_seconds": min(s["wall_seconds"] for s in samples),
                                "wall_max_seconds": max(s["wall_seconds"] for s in samples)}
Path(args.output).write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
print(json.dumps(report, indent=2))
