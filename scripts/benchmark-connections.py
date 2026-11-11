#!/usr/bin/env python3
"""Synthetic HTTP/verified HTTPS connection reuse A/B. Never uses a live API."""
import argparse
import hashlib
import json
import os
import platform
from pathlib import Path
import ssl
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tests"))
from loopback import Fixture, Reply, payload, video

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--binary", action="append", required=True, metavar="NAME=PATH")
parser.add_argument("--reuse-binary", action="append", default=[], metavar="NAME", help="enable --reuse-connections for this binary label")
parser.add_argument("--pages", type=int, default=40)
parser.add_argument("--repetitions", type=int, default=5)
parser.add_argument("--output", required=True)
args = parser.parse_args()
if args.pages < 1 or args.repetitions < 1:
    parser.error("pages and repetitions must be positive")
binaries = []
for value in args.binary:
    if "=" not in value:
        parser.error("--binary must be NAME=PATH")
    name, path = value.split("=", 1)
    if not name or not path or any(existing == name for existing, _ in binaries):
        parser.error("binary names and paths must be nonempty; names must be unique")
    resolved = Path(path).resolve()
    if not resolved.is_file():
        parser.error("binary does not exist: " + str(resolved))
    binaries.append((name, str(resolved)))
if any(name not in {label for label, _ in binaries} for name in args.reuse_binary):
    parser.error("--reuse-binary must name a --binary label")
flags = ["nicovideo.jp/user/1", "-P", "1", "--retries", "1", "--no-progress"]
results = {"fixture": "loopback; no artificial RTT; sequential pages; verified HTTPS; one unrecorded warmup", "pages": args.pages, "repetitions": args.repetitions, "flags": {name: flags + (["--reuse-connections"] if name in args.reuse_binary else []) for name, _ in binaries},
           "platform": platform.platform(), "python": platform.python_version(),
           "binaries": [{"name": name, "path": path, "sha256": hashlib.sha256(Path(path).read_bytes()).hexdigest()} for name, path in binaries], "runs": []}
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    cert, key = root / "cert.pem", root / "key.pem"
    subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
                    "-subj", "/CN=localhost", "-addext", "subjectAltName=IP:127.0.0.1",
                    "-keyout", str(key), "-out", str(cert)], check=True, capture_output=True, timeout=30)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(cert, key)
    expected = "".join(f"sm{page}\n" for page in range(1, args.pages + 1)).encode()
    for secure in (False, True):
        protocol = "https" if secure else "http"
        for repetition in range(-1, args.repetitions):
            # Alternate order to reduce run-order bias.
            order = binaries if repetition % 2 else list(reversed(binaries))
            for name, binary in order:
                def respond(request):
                    return Reply(payload(request.kind, [video("sm" + str(request.page))] if request.page <= args.pages else []))
                with Fixture(respond, context if secure else None) as fixture:
                    env = os.environ.copy()
                    env.update(NICO_BASE_URL=fixture.url, NO_PROXY="127.0.0.1", no_proxy="127.0.0.1", SSL_CERT_FILE=str(cert))
                    start = time.perf_counter()
                    run = subprocess.run([binary, *results["flags"][name]], env=env, capture_output=True, timeout=30)
                    elapsed = time.perf_counter() - start
                    assert run.returncode == 0, run.stderr
                    assert run.stdout == expected
                    assert len(fixture.records) == args.pages + 1
                    assert not fixture.errors, fixture.errors
                    if repetition >= 0:
                        results["runs"].append(dict(protocol=protocol, binary=name, repetition=repetition, wall_seconds=elapsed,
                                                    connections=fixture.connections, tls_handshakes=fixture.connections if secure else 0,
                                                    requests=len(fixture.records), stdout_sha256=hashlib.sha256(run.stdout).hexdigest()))
results["summary"] = []
for protocol in ("http", "https"):
    for name, _ in binaries:
        runs = [row for row in results["runs"] if row["protocol"] == protocol and row["binary"] == name]
        results["summary"].append(dict(protocol=protocol, binary=name, median_wall_seconds=statistics.median(row["wall_seconds"] for row in runs),
                                      connections=[row["connections"] for row in runs], requests=[row["requests"] for row in runs]))
Path(args.output).write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results["summary"], indent=2))
