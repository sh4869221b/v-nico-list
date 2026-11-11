#!/usr/bin/env python3
"""Static requested-byte estimate, not a runtime allocation/CPU profiler.

Run from any directory. Uses the exact benchmark fixtures. Each non-string scalar
reaches the production ['null', 'true', 'false'] loop: null tries once, true twice,
false and numbers three times. Each current suffix allocation requests len+1.
"""
import json
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "scripts"))
from benchmark_parse import fixture

rows = []
for kind in ("user", "mylist"):
    for style in ("unicode", "escaped"):
        data = fixture(kind, style, 100)[0]
        i = total = copies = 0
        while i < len(data):
            if data[i] == 34:
                i += 1
                while data[i] != 34:
                    i += 2 if data[i] == 92 else 1
                i += 1
            elif data[i] in b"-0123456789ntf":
                match = re.match(rb"(?:null|true|false|-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)", data[i:])
                assert match
                token = match[0]
                n = 1 if token == b"null" else 2 if token == b"true" else 3
                copies += n
                total += n * (len(data) - i + 1)
                i += len(token)
            else:
                i += 1
        rows.append(dict(kind=kind, style=style, payload_bytes=len(data), suffix_copies=copies,
                         requested_suffix_bytes=total))
print(json.dumps(rows, indent=2))
