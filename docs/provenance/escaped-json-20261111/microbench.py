#!/usr/bin/env python3
"""Local isolated quoted() experiment; no network, and not a CLI benchmark."""
import hashlib
import json
import pathlib
import statistics
import subprocess
import sys
import tempfile

v, baseline, candidate, output = map(pathlib.Path, sys.argv[1:5])
hashfile = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
main = r'''module main
import os
import time
fn main() {
    input := os.read_file(os.args[1])!
    expected := os.read_file(os.args[2])!
    mut p := JSONCheck{s: input}
    assert p.quoted()! == expected
    for _ in 0..10000 { p.i = 0; assert p.quoted()! == expected }
    before := gc_heap_usage()
    start := time.sys_mono_now()
    mut checksum := 0
    for _ in 0..100000 { p.i = 0; checksum += p.quoted()!.len }
    elapsed := time.sys_mono_now() - start
    after := gc_heap_usage()
    assert checksum == expected.len * 100000
    println('${elapsed} ${after.total_bytes - before.total_bytes}')
}
'''
cases = {
    'ascii': ('abc xyz/123' * 16, False),
    'unicode': ('日本語é😀/123' * 16, False),
    'escaped_unicode': ('日本語é😀/123' * 16, True),
    'standard_escapes': ('\"\\/\b\f\n\r\t\0abc' * 16, False),
}
if len(sys.argv) > 5 and sys.argv[5] == 'sparse':
    cases = {
        'late_escape': ('abc xyz/123' * 256 + '\n', False),
        'early_escape': ('\n' + 'abc xyz/123' * 256, False),
    }
result = {'compiler_sha256': hashfile(v), 'iterations': 100000, 'warmups': 10000,
          'repetitions': 9, 'flags': ['-cc', 'gcc', '-prod', '-gc', 'boehm'],
          'sources': {}, 'cases': {}}
with tempfile.TemporaryDirectory(prefix='quoted-bench-') as tmp:
    root = pathlib.Path(tmp)
    bins = {}
    for name, source in [('baseline', baseline), ('candidate', candidate)]:
        dest = root / name
        dest.mkdir()
        for filename in ['domain.v', 'config.v']:
            (dest / filename).write_bytes((source / 'src' / filename).read_bytes())
        (dest / 'main.v').write_text(main)
        binary = root / (name + '.bin')
        subprocess.run([str(v), *result['flags'], '-o', str(binary), str(dest)], check=True)
        bins[name] = binary
        result['sources'][name] = {'domain_sha256': hashfile(dest / 'domain.v'),
                                   'binary_sha256': hashfile(binary)}
    for case, (expected, ascii_only) in cases.items():
        body = json.dumps(expected, ensure_ascii=ascii_only)
        inp, exp = root / 'input', root / 'expected'
        inp.write_text(body)
        exp.write_text(expected)
        samples = {'baseline': [], 'candidate': []}
        for rep in range(9):
            for name in (list(bins) if rep % 2 == 0 else list(bins)[::-1]):
                run = subprocess.run([str(bins[name]), str(inp), str(exp)], check=True,
                                     text=True, capture_output=True, timeout=180)
                elapsed, allocated = map(int, run.stdout.split())
                samples[name].append({'ns_per_string': elapsed / 100000,
                                      'gc_bytes_per_string': allocated / 100000})
        result['cases'][case] = {'input': body, 'expected': expected, 'samples': samples,
            'median_ns': {n: statistics.median(s['ns_per_string'] for s in ss)
                          for n, ss in samples.items()}}
output.write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps({c: r['median_ns'] for c, r in result['cases'].items()}, indent=2))
