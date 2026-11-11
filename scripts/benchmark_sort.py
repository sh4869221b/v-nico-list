#!/usr/bin/env python3
"""Compile isolated production sort code from checkouts; report synthetic samples."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile

DRIVER = """module main
import os
import time
fn main() {
    n := os.args[1].int()
    mut input := []string{cap: n}
    for i in 0 .. n { input << 'sm${(i * i64(7919)) % n}' }
    for iteration in 0 .. 2 {
        mut ids := input.clone()
        started := time.sys_mono_now()
        SORT_CALL
        elapsed := time.sys_mono_now() - started
        for i, id in ids { assert id == 'sm${i}' }
        if iteration == 1 { println(elapsed) }
    }
}
"""

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--source", action="append", required=True, metavar="NAME=CHECKOUT")
parser.add_argument("--v", default=os.environ.get("V", "v"))
parser.add_argument("--cc", default="gcc")
parser.add_argument("--size", type=int, action="append")
parser.add_argument("--repetitions", type=int, default=9)
parser.add_argument("--output", default="sort-benchmark.json")
args = parser.parse_args()
sizes = args.size or [6000, 60000]
if len(set(sizes)) != len(sizes):
    parser.error("--size values must be unique")
if args.repetitions < 1 or any(n < 1 or n > 10000000 or math.gcd(n, 7919) != 1 for n in sizes):
    parser.error("sizes must be 1..10000000 and coprime to 7919; repetitions must be positive")
compiler = shutil.which(args.v)
if not compiler:
    parser.error("V compiler not found")
report = {"scope": "Isolated numeric ID sorting, not CLI or live API throughput. Timed region includes key generation, sorting and copy-back; excludes input cloning, startup and validation.",
          "platform": platform.platform(), "compiler": subprocess.check_output([compiler, "version"], text=True).strip(),
          "cc": args.cc, "flags": ["-prod"], "sizes": sizes, "repetitions": args.repetitions,
          "order": "alternating forward/reverse per repetition; one warmup per process", "sources": {}}
with tempfile.TemporaryDirectory(prefix="nico-sort-") as temporary:
    binaries = {}
    for index, specification in enumerate(args.source):
        name, separator, path = specification.partition("=")
        if not separator or not name or name in binaries:
            parser.error("--source must be UNIQUE_NAME=CHECKOUT")
        source = Path(path).resolve()
        destination = Path(temporary) / str(index)
        destination.mkdir()
        hashes = {}
        for filename in ("domain.v", "config.v"):
            data = (source / "src" / filename).read_bytes()
            (destination / filename).write_bytes(data)
            hashes[filename] = hashlib.sha256(data).hexdigest()
        domain = (destination / "domain.v").read_text()
        if "fn sort_ids(" in domain:
            call = "sort_ids(mut ids)"
        elif "fn compare_ids(" in domain:
            call = "ids.sort_with_compare(compare_ids)"
        else:
            parser.error("checkout has no supported sort entry point")
        driver = DRIVER.replace("SORT_CALL", call)
        (destination / "main.v").write_text(driver)
        binary = destination / ("sort.exe" if os.name == "nt" else "sort")
        command = [compiler, "-cc", args.cc, "-prod", "-o", str(binary), str(destination)]
        build = subprocess.run(command, capture_output=True, text=True, timeout=120)
        if build.returncode:
            raise RuntimeError(build.stdout + build.stderr)
        binaries[name] = str(binary)
        report["sources"][name] = {"path": str(source), "source_sha256": hashes, "entry_point": call,
                                   "driver_sha256": hashlib.sha256(driver.encode()).hexdigest(),
                                   "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "results": {}}
    for size in sizes:
        for iteration in range(args.repetitions):
            order = list(binaries) if iteration % 2 == 0 else list(reversed(binaries))
            for name in order:
                result = subprocess.run([binaries[name], str(size)], capture_output=True, text=True, timeout=120, check=True)
                samples = report["sources"][name]["results"].setdefault(str(size), {"nanoseconds": []})
                samples["nanoseconds"].append(int(result.stdout.strip()))
    for source in report["sources"].values():
        for result in source["results"].values():
            result["median_nanoseconds"] = statistics.median(result["nanoseconds"])
Path(args.output).write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
