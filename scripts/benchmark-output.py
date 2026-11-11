#!/usr/bin/env python3
"""Isolated line-output A/B. Builds a 1M-ID harness from two source revisions.

No API or HTTP calls. Includes process startup, constructing IDs and output;
this is deliberately not an end-to-end CLI benchmark. Uses the configured V
compiler/VMODULES, just like scripts/build.sh. Python standard library only.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, help='Git revision of baseline source')
parser.add_argument('--v', default=os.environ.get('V', 'v'))
parser.add_argument('--repetitions', type=int, default=7)
parser.add_argument('--output', default='output-benchmark.json')
args = parser.parse_args()
if args.repetitions < 1:
    parser.error('repetitions must be positive')
repo = Path(__file__).resolve().parents[1]
baseline = subprocess.check_output(['git', 'rev-parse', '--verify', args.baseline + '^{commit}'], cwd=repo, text=True, timeout=30).strip()
harness = '''module main
fn main() {
 C.nico_signals()
 mut c := new_control(Config{}) or { panic(err) }
 mut ids := []string{cap: 1000000}
 for i in 0 .. 1000000 { ids << 'sm${1000000 + i}' }
 c.emit_items(ids)
 if c.output_count != ids.len || c.output_error != '' { panic('output mismatch') }
}
'''
report = {'scope': 'Output-only harness, including startup and construction of 1M IDs; no HTTP or live API inference.',
          'platform': platform.platform(), 'baseline_commit': baseline,
          'compiler': subprocess.check_output([args.v, 'version'], text=True, timeout=30).strip(),
          'warmups': 1, 'repetitions': args.repetitions, 'items': 1000000,
          'execution_order': 'alternating forward/reverse', 'sinks': {}, 'source_sha256': {}, 'binary_sha256': {}}
with tempfile.TemporaryDirectory(prefix='nico-output-bench-') as temp:
    root = Path(temp)
    for name in ('old', 'new'):
        source = root / name
        source.mkdir()
        digest = hashlib.sha256()
        names = (subprocess.check_output(['git', 'ls-tree', '--name-only', baseline + ':src'], cwd=repo, text=True, timeout=30).splitlines()
                 if name == 'old' else [path.name for path in (repo / 'src').iterdir() if path.is_file()])
        for filename in sorted(names):
            path = repo / 'src' / filename
            if not filename.endswith(('.v', '.h')) or filename.endswith('_test.v'):
                continue
            data = (subprocess.check_output(['git', 'show', baseline + ':src/' + path.name], cwd=repo, timeout=30)
                    if name == 'old' else path.read_bytes())
            digest.update(path.name.encode() + b'\0' + data)
            text = data.decode().replace('@VMODROOT/src/', '@VMODROOT/')
            if path.name == 'main.v':
                if text.count('fn main() {') != 1:
                    raise RuntimeError('cannot locate main entry point')
                text = text.replace('fn main() {', 'fn cli_main() {')
            (source / path.name).write_text(text)
        report['source_sha256'][name] = digest.hexdigest()
        (source / 'v.mod').write_bytes(subprocess.check_output(['git', 'show', baseline + ':v.mod'], cwd=repo, timeout=30)
                                     if name == 'old' else (repo / 'v.mod').read_bytes())
        (source / 'bench.v').write_text(harness)
        binary = root / (name + '-bin')
        subprocess.run([args.v, '-cc', 'gcc', '-d', 'use_openssl', '-prod', '-o', str(binary), str(source)], check=True, timeout=120)
        report['binary_sha256'][name] = hashlib.sha256(binary.read_bytes()).hexdigest()
    for sink in ('null', 'pipe', 'file'):
        samples = {name: [] for name in ('old', 'new')}
        digests = {}
        for rep in range(args.repetitions + 1):
            for name in (('old', 'new') if rep % 2 else ('new', 'old')):
                with tempfile.TemporaryFile() as output:
                    destination = subprocess.DEVNULL if sink == 'null' else subprocess.PIPE if sink == 'pipe' else output
                    started = time.perf_counter()
                    result = subprocess.run([str(root / (name + '-bin'))], stdout=destination, stderr=subprocess.PIPE, check=True, timeout=120)
                    elapsed = time.perf_counter() - started
                    if sink == 'pipe':
                        data = result.stdout
                    elif sink == 'file':
                        output.seek(0)
                        data = output.read()
                    else:
                        data = None
                    if data is not None:
                        if len(data) != 10000000:
                            raise RuntimeError('incorrect byte count')
                        digests[name] = hashlib.sha256(data).hexdigest()
                        if digests[name] != 'd6781172358e9b6637cd8155894860a4677294db9198b0faf45d9e50e848301b':
                            raise RuntimeError('incorrect output bytes')
                    if rep:
                        samples[name].append(elapsed)
        report['sinks'][sink] = {'samples_seconds': samples,
                                 'median_seconds': {k: statistics.median(v) for k, v in samples.items()},
                                 'sha256': digests}
Path(args.output).write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
