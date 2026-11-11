#!/usr/bin/env python3
"""Isolated production parse_page benchmark. Never contacts the live API."""

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import tempfile

HERE = Path(__file__).resolve().parent
DRIVER = HERE / "parse_benchmark" / "main.v"
FLAGS = ["-prod", "-gc", "boehm"]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def command(argv, cwd=None):
    return subprocess.check_output(argv, cwd=cwd, text=True, stderr=subprocess.STDOUT,
                                   timeout=180).strip()


def git_identity(path):
    return {"head": command(["git", "rev-parse", "HEAD"], path),
            "tree": command(["git", "rev-parse", "HEAD^{tree}"], path),
            "status": command(["git", "status", "--porcelain"], path)}


def fixture(kind, style, size, profile="full"):
    """Synthetic schema-shaped data, not a capture or traffic distribution model."""
    text = {"ascii": "ordinary ASCII title and description",
            "unicode": "動画と説明 投稿者 😀 café",
            "escaped": "動画と説明 投稿者 😀 café"}[style]
    dates = ["2024-01-10T00:00:00Z", "2024-02-29T23:00:00-01:00",
             "2024-03-01T09:00:00.123456789+09:00", "2000-02-29T12:34:56Z"]
    items, expected = [], []
    for i in range(size):
        date = dates[i % len(dates)]
        v = {"id": f"sm{i + 1}", "count": {"comment": i * 17 - 1}, "registeredAt": date}
        item = {"essential" if kind == "user" else "video": v}
        if profile == "full":
            v.update(type="video", title=text, shortDescription=text * 4,
                     latestCommentSummary=text, duration=123 + i, isChannelVideo=False,
                     isPaymentRequired=False, requireSensitiveMasking=True,
                     **{"9d091f87": False, "acf68865": True})
            v["count"].update(view=10000 + i, mylist=i, like=i * 2)
            v["thumbnail"] = {key: f"https://example.invalid/{key}/{i}.jpg" for key in
                              ("url", "middleUrl", "largeUrl", "listingUrl", "nHdUrl")}
            v["owner"] = dict(ownerType="user", id=str(i), name=text,
                              iconUrl="https://example.invalid/icon.jpg")
            # Unknown members must still be decoded and validated by production.
            v["unknown"] = {"tags": [text, "tag", None], "nested": [[1, -2, 0.5, True],
                              {"text": text, "empty": [], "object": {}}]}
            item["series"] = dict(id=i, order=i + 1, title=text)
        items.append(item)
        expected.append(dict(id=v["id"], comment=v["count"]["comment"],
                             registered=int(datetime.fromisoformat(date.replace("Z", "+00:00")).timestamp())))
    data = {"items": items, "totalCount": size}
    if kind == "mylist":
        data = {"totalCount": size + 99, "mylist": dict(data, totalItemCount=size + 1)}
    obj = {"meta": {"status": 200}, "data": data}
    body = json.dumps(obj, ensure_ascii=style == "escaped", separators=(",", ":"))
    if style == "escaped":
        # Exercise escaped names, numeric IDs, slash and surrogate-pair decoding.
        body = body.replace('"title":', '"\\u0074itle":').replace('"sm', '"\\u0073m').replace("/", "\\/")
    page = dict(items=expected, status=200, total=size, has_total=True, not_found=False)
    return body.encode(), obj, page



def exact_json(actual, expected):
    """JSON structural equality including scalar types (Python True == 1 is unsafe)."""
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(
            exact_json(actual[key], value) for key, value in expected.items())
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(
            exact_json(a, b) for a, b in zip(actual, expected))
    return actual == expected


def specifications(values, parser):
    result = {}
    for value in values:
        name, sep, path = value.partition("=")
        if not sep or not name or name in result or not all(c.isalnum() or c in "_-" for c in name):
            parser.error("specifications must be UNIQUE_NAME=PATH (alphanumeric, _ or - names)")
        result[name] = Path(path).resolve()
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", action="append", default=[], metavar="NAME=CHECKOUT")
    parser.add_argument("--binary", action="append", default=[], metavar="NAME=PATH",
                        help="reuse a harness binary with its adjacent .json build manifest")
    parser.add_argument("--build-dir", type=Path, help="new directory to retain compiled binaries and manifests")
    parser.add_argument("--v", default=os.environ.get("V", "v"))
    parser.add_argument("--cc", default="gcc")
    parser.add_argument("--size", action="append", type=int)
    parser.add_argument("--profile", choices=("full", "minimal"), default="full")
    parser.add_argument("--iterations", type=int, default=20)
    parser.add_argument("--warmups", type=int, default=10)
    parser.add_argument("--repetitions", type=int, default=7)
    parser.add_argument("--output", type=Path, default=Path("parse-benchmark.json"))
    args = parser.parse_args()
    sources, binaries = specifications(args.source, parser), specifications(args.binary, parser)
    if not (sources or binaries) or sources.keys() & binaries.keys():
        parser.error("provide at least one source or binary, with unique names")
    sizes = args.size or [100]
    if len(set(sizes)) != len(sizes) or any(n < 1 or n > 1000 for n in sizes):
        parser.error("unique sizes must be in 1..1000")
    if not (1 <= args.iterations <= 10000 and 1 <= args.warmups <= 1000 and 1 <= args.repetitions <= 100):
        parser.error("iterations 1..10000, warmups 1..1000, repetitions 1..100 required")
    report = {"scope": "Isolated parse_page wall time plus loop/assignment/scalar checksum; includes normal GC. Excludes file IO, startup, validation, output, HTTP, workers and sorting. No CLI/live API speed claim.",
              "started_at_utc": datetime.now(timezone.utc).isoformat(),
              "harness_sha256": sha(Path(__file__).read_bytes()),
              "platform": platform.platform(), "machine": platform.machine(), "python": platform.python_version(),
              "cpu": platform.processor(), "parameters": vars(args).copy(),
              "order": "fresh process per sample, warmups inside each process; alternating forward/reverse variants per repetition",
              "memory": "Boehm gc_heap_usage total_bytes delta across timed batch (allocator-accounted bytes, not allocation count, RSS or peak/live memory). Heap snapshots are before/after only; GC remains enabled.",
              "variants": {}, "fixtures": {}}
    report["parameters"] = {k: str(v) if isinstance(v, Path) else v for k, v in report["parameters"].items()}
    driver_hash = sha(DRIVER.read_bytes())
    with tempfile.TemporaryDirectory(prefix="nico-parse-") as tmp:
        root = Path(tmp)
        build_root = args.build_dir.resolve() if args.build_dir else root / "build"
        if sources:
            build_root.mkdir()  # Refuse overwrite; TemporaryDirectory bounds default outputs.
            compiler = shutil.which(args.v)
            if not compiler:
                parser.error("V compiler not found")
            compiler = str(Path(compiler).resolve())
            compiler_git = git_identity(Path(compiler).parent)
            pinned = (HERE / "v-revision").read_text().strip()
            if compiler_git["head"] != pinned:
                parser.error("V compiler checkout must match scripts/v-revision")
            compiler_info = {"path": compiler, "sha256": sha(Path(compiler).read_bytes()),
                             "version": command([compiler, "version"]), "git": compiler_git,
                             "cc": args.cc, "cc_version": command([args.cc, "--version"]),
                             "flags": FLAGS, "vmodules": os.environ.get("VMODULES")}
            for name, source in sources.items():
                dest = root / ("source-" + name)
                dest.mkdir()
                hashes = {}
                for filename in ("domain.v", "config.v"):
                    content = (source / "src" / filename).read_bytes()
                    (dest / filename).write_bytes(content)
                    hashes[filename] = sha(content)
                shutil.copyfile(DRIVER, dest / "main.v")
                binary = build_root / (name + (".exe" if os.name == "nt" else ""))
                build = [compiler, "-cc", args.cc, *FLAGS, "-o", str(binary), str(dest)]
                command(build)
                metadata = {"source": str(source), "git": git_identity(source), "source_sha256": hashes,
                            "driver_sha256": driver_hash, "compiler": compiler_info, "build_command": build,
                            "binary_sha256": sha(binary.read_bytes())}
                Path(str(binary) + ".json").write_text(json.dumps(metadata, indent=2) + "\n")
                binaries[name] = binary
        for name, binary in binaries.items():
            metadata = json.loads(Path(str(binary) + ".json").read_text())
            if metadata["driver_sha256"] != driver_hash or metadata["binary_sha256"] != sha(binary.read_bytes()):
                raise ValueError(f"{name}: driver or binary differs from build manifest")
            report["variants"][name] = dict(metadata, path=str(binary), results={})
        for size in sizes:
            for kind in ("user", "mylist"):
                for style in ("ascii", "unicode", "escaped"):
                    key = f"{kind}-{style}-{args.profile}-{size}"
                    body, tree, page = fixture(kind, style, size, args.profile)
                    path = root / (key + ".json")
                    path.write_bytes(body)
                    report["fixtures"][key] = {"sha256": sha(body), "bytes": len(body), "items": size,
                                                "expected_page_sha256": sha(json.dumps(page, sort_keys=True).encode())}
                    for name, binary in binaries.items():
                        lines = command([str(binary), str(path), kind, "verify"]).splitlines()
                        if len(lines) != 2 or not exact_json(json.loads(lines[0]), page) or not exact_json(json.loads(lines[1]), tree):
                            raise ValueError(f"{name}/{key}: exact Page or full decoded JSON mismatch")
                        report["variants"][name]["results"][key] = {"samples": []}
                    for repetition in range(args.repetitions):
                        order = list(binaries) if repetition % 2 == 0 else list(reversed(binaries))
                        for name in order:
                            lines = command([str(binaries[name]), str(path), kind, str(args.iterations), str(args.warmups)]).splitlines()
                            if len(lines) != 2 or not exact_json(json.loads(lines[1]), page):
                                raise ValueError(f"{name}/{key}: timed run Page mismatch")
                            sample = json.loads(lines[0])
                            expected_sum = args.warmups * size + args.iterations * (size + 200 + size)
                            if sample["iterations"] != args.iterations or sample["checksum"] != expected_sum or sample["nanoseconds"] <= 0 or sample["allocated_bytes"] <= 0:
                                raise ValueError(f"{name}/{key}: invalid timing/checksum/GC counters")
                            report["variants"][name]["results"][key]["samples"].append(sample)
        for variant in report["variants"].values():
            for result in variant["results"].values():
                values = [s["nanoseconds"] / args.iterations for s in result["samples"]]
                result.update(ns_per_page_median=statistics.median(values), ns_per_page_min=min(values),
                              ns_per_page_max=max(values), allocated_bytes_per_page_median=statistics.median(
                                  s["allocated_bytes"] / args.iterations for s in result["samples"]))
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Verified exact Page and full decoded JSON for {len(report['fixtures'])} fixtures; saved {args.output}")
    for name, variant in report["variants"].items():
        for key, result in variant["results"].items():
            print(f"{name} {key}: {result['ns_per_page_median'] / 1e6:.3f} ms/page, "
                  f"{result['allocated_bytes_per_page_median']:.0f} GC bytes/page")


if __name__ == "__main__":
    main()
