module main

import json2
import strconv
import encoding.utf8

// Frozen pre-optimization string path for differential acceptance/value tests.
fn (mut p JSONCheck) reference_quoted() !string {
	if p.i >= p.s.len || p.s[p.i] != `"` { return error('JSON: expected string') }
	start := p.i
	p.i++
	mut escaped := false
	for p.i < p.s.len {
		c := p.s[p.i]
		p.i++
		if c == `"` {
			// strict_json has already validated UTF-8; without escapes the
			// scanned bytes are the decoded value. Keep the strict decoder
			// for escape handling, including surrogate pairs.
			if !escaped { return p.s[start + 1..p.i - 1] }
			return json2.decode[string](p.s[start..p.i], strict: true)!
		}
		if c < 0x20 { return error('JSON: control character in string') }
		if c == `\\` {
			escaped = true
			if p.i >= p.s.len { return error('JSON: truncated escape') }
			e := p.s[p.i]
			p.i++
			if e == `u` {
				if p.i + 4 > p.s.len { return error('JSON: truncated unicode escape') }
				hex := p.s[p.i..p.i + 4]
				for h in hex {
					if !h.is_hex_digit() { return error('JSON: invalid unicode escape') }
				}
				code := strconv.parse_uint(hex, 16, 16)!
				p.i += 4
				if code >= 0xd800 && code <= 0xdbff {
					if p.i + 6 > p.s.len || p.s[p.i..p.i + 2] != '\\u' {
						return error('JSON: unpaired unicode surrogate')
					}
					lo := strconv.parse_uint(p.s[p.i + 2..p.i + 6], 16, 16)!
					if lo < 0xdc00 || lo > 0xdfff {
						return error('JSON: unpaired unicode surrogate')
					}
					p.i += 6
				} else if code >= 0xdc00 && code <= 0xdfff {
					return error('JSON: unpaired unicode surrogate')
				}
			} else if e !in [u8(`"`), `\\`, `/`, `b`, `f`, `n`, `r`, `t`] {
				return error('JSON: invalid escape')
			}
		}
	}
	return error('JSON: unterminated string')
}

fn check_escape_equivalence(s string) {
	mut old := JSONCheck{ s: s }
	mut next := JSONCheck{ s: s }
	mut old_ok := true
	mut next_ok := true
	a := old.reference_quoted() or {
		old_ok = false
		''
	}
	b := next.quoted() or {
		next_ok = false
		''
	}
	assert old_ok == next_ok, 'acceptance mismatch: ${s.bytes()}'
	if old_ok {
		assert a == b, 'value mismatch: ${s.bytes()}'
		assert old.i == next.i
	}
}

fn json_hex(code int) string {
	return '\\u' + '${code:04X}'
}

fn test_every_bmp_escape_and_surrogate_boundaries() {
	for code in 0 .. 65536 { check_escape_equivalence('"' + json_hex(code) + '"') }
	for hi in [0xd800, 0xd801, 0xdbfe, 0xdbff] {
		for lo in 0xdc00 .. 0xe000 {
			check_escape_equivalence('"a' + json_hex(hi) + json_hex(lo) + 'z"')
		}
	}
	for hi in 0xd800 .. 0xdc00 {
		for lo in [0xdbff, 0xdc00, 0xdc01, 0xdffe, 0xdfff, 0xe000] {
			check_escape_equivalence('"' + json_hex(hi) + json_hex(lo) + '"')
		}
	}
}

fn test_escape_spellings_mutations_and_truncation() {
	for text in ['"\\uD800\\uDC00"', '"\\u0041"', '"\\uDBFF\\uDFFF"'] {
		for pos in 0 .. text.len {
			for c in 0 .. 128 {
				mut bytes := text.bytes()
				bytes[pos] = u8(c)
				check_escape_equivalence(bytes.bytestr())
			}
			check_escape_equivalence(text[..pos])
		}
	}
	for c in 0 .. 128 {
		check_escape_equivalence('"a\\' + [u8(c)].bytestr() + 'z"')
		check_escape_equivalence('"\\n' + [u8(c)].bytestr() + 'z"')
	}
	for s in ['"\\"\\\\\\/\\b\\f\\n\\r\\t\\u0000"', '"日本語é😀\\n日本語é😀"',
		'"prefix\\u0000suffix"', '"\\ud800\\u+DC0"', '"\\ud800\\u-DC0"',
		'"' + '日本語'.repeat(10000) + '\\n' + 'abc'.repeat(10000) + '"',
		'"' + '\\u3042'.repeat(10000) + '"'] {
		check_escape_equivalence(s)
	}
}

fn test_generated_unicode_string_roundtrips() {
	mut seed := u32(123456789)
	for _ in 0 .. 500 {
		mut source := ''
		mut escaped := ''
		for _ in 0 .. 50 {
			seed = seed * 1664525 + 1013904223
			cp := seed % 0x110000
			if cp >= 0xd800 && cp <= 0xdfff { continue }
			source += rune(cp).str()
			if cp < 0x10000 {
				escaped += json_hex(int(cp))
			} else {
				escaped += json_hex(int(0xd800 + ((cp - 0x10000) >> 10)))
				escaped += json_hex(int(0xdc00 + ((cp - 0x10000) & 0x3ff)))
			}
		}
		encoded_escapes := '"' + escaped + '"'
		check_escape_equivalence(encoded_escapes)
		assert (strict_json(encoded_escapes) or { panic(err) }) == json2.Any(source)
		encoded := json2.encode(source)
		check_escape_equivalence(encoded)
		decoded := strict_json(encoded) or { panic(err) }
		assert decoded is string
		assert decoded == source
	}
}

fn test_escaped_names_unknown_fields_and_invalid_raw_utf8() {
	for s in ['{"x":0,"\\u0078":1}', '{"\\u0000":0,"\\u0000":1}', '{"😀":0,"\\ud83d\\ude00":1}',
		'{"unknown":[{"bad":"\\ud800\\u+DC0"}]}'] {
		if _ := strict_json(s) {
			assert false, s
		}
	}
	for bytes in [[u8(0xff)], [u8(0xc0), 0x80], [u8(0xed), 0xa0, 0x80], [u8(0xf4), 0x90, 0x80,
		0x80], [u8(0xe2), 0x82]] {
		for prefix in ['', '\\n'] {
			s := '"' + prefix + bytes.bytestr() + '"'
			assert !utf8.validate_str(s)
			if _ := strict_json(s) {
				assert false
			}
		}
	}
}

fn test_standard_escape_bytes_independently() {
	mut p := JSONCheck{ s: '"\\"\\\\\\/\\b\\f\\n\\r\\t\\u0000"' }
	actual := p.quoted() or { panic(err) }
	assert actual.bytes() == [u8(34), 92, 47, 8, 12, 10, 13, 9, 0]
}
