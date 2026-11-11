module main

import json2
import encoding.utf8
import strconv

// Frozen validator from 5f375c1 for differential prefix/grammar tests.
struct OriginalJSONCheck {
	s string
mut:
	i int
}

fn (mut p OriginalJSONCheck) ws() {
	for p.i < p.s.len && p.s[p.i] in [u8(` `), `\n`, `\r`, `\t`] { p.i++ }
}

fn (mut p OriginalJSONCheck) quoted() !string {
	if p.i >= p.s.len || p.s[p.i] != `"` { return error('JSON: expected string') }
	start := p.i
	p.i++
	mut escaped := false
	for p.i < p.s.len {
		c := p.s[p.i]
		p.i++
		if c == `"` {
			// original_strict_json has already validated UTF-8; without escapes the
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

fn (mut p OriginalJSONCheck) value(depth int) !json2.Any {
	if depth > 512 { return error('JSON: nesting limit exceeded') }
	p.ws()
	if p.i >= p.s.len { return error('JSON: unexpected end') }
	c := p.s[p.i]
	if c == `"` { return json2.Any(p.quoted()!) }
	if c == `{` || c == `[` {
		is_object := c == `{`
		end := if is_object { u8(`}`) } else { u8(`]`) }
		p.i++
		p.ws()
		if p.i < p.s.len && p.s[p.i] == end {
			p.i++
			return if is_object {
				json2.Any(map[string]json2.Any{})
			} else {
				json2.Any([]json2.Any{})
			}
		}
		mut obj := map[string]json2.Any{}
		mut arr := []json2.Any{}
		mut key := ''
		for {
			p.ws()
			if is_object {
				key = p.quoted()!
				if key in obj { return error('JSON: duplicate object name ${key}') }
				p.ws()
				if p.i >= p.s.len || p.s[p.i] != `:` { return error('JSON: expected colon') }
				p.i++
			}
			v := p.value(depth + 1)!
			if is_object { obj[key] = v } else { arr << v }
			p.ws()
			if p.i >= p.s.len { return error('JSON: unexpected end') }
			if p.s[p.i] == end {
				p.i++
				return if is_object { json2.Any(obj) } else { json2.Any(arr) }
			}
			if p.s[p.i] != `,` { return error('JSON: expected comma') }
			p.i++
		}
	}
	for literal in ['null', 'true', 'false'] {
		if p.s[p.i..].starts_with(literal) {
			p.i += literal.len
			return match literal {
				'null' { json2.Any(json2.Null{}) }
				'true' { json2.Any(true) }
				else { json2.Any(false) }
			}
		}
	}
	start := p.i
	if p.s[p.i] == `-` { p.i++ }
	if p.i >= p.s.len { return error('JSON: invalid number') }
	if p.s[p.i] == `0` {
		p.i++
	} else {
		if p.s[p.i] < `1` || p.s[p.i] > `9` { return error('JSON: invalid value') }
		for p.i < p.s.len && p.s[p.i].is_digit() { p.i++ }
	}
	if p.i < p.s.len && p.s[p.i] == `.` {
		p.i++
		digits := p.i
		for p.i < p.s.len && p.s[p.i].is_digit() { p.i++ }
		if p.i == digits { return error('JSON: invalid fraction') }
	}
	if p.i < p.s.len && p.s[p.i] in [u8(`e`), `E`] {
		p.i++
		if p.i < p.s.len && p.s[p.i] in [u8(`+`), `-`] { p.i++ }
		digits := p.i
		for p.i < p.s.len && p.s[p.i].is_digit() { p.i++ }
		if p.i == digits { return error('JSON: invalid exponent') }
	}
	if p.i == start { return error('JSON: invalid value') }
	text := p.s[start..p.i]
	if !text.contains('.') && !text.contains('e') && !text.contains('E') {
		if n := strconv.parse_int(text, 10, 64) { return json2.Any(n) }
		if n := strconv.parse_uint(text, 10, 64) { return json2.Any(n) }
	}
	return json2.Any(strconv.atof64(text) or { f64(0) })
}

fn original_strict_json(s string) !json2.Any {
	if !utf8.validate_str(s) { return error('JSON: invalid UTF-8') }
	mut p := OriginalJSONCheck{ s: s }
	result := p.value(0)!
	p.ws()
	if p.i != s.len { return error('JSON: trailing data') }
	return result
}

fn test_prefix_matches_original_suffix_at_every_offset() {
	for text in ['', 'null', 'true', 'false', 'nullx', 'nulltrue', 'n', 'tru', 'fals', '0',
		'日本語null', ' null false ', '\u0000null'] {
		for i in 0 .. text.len + 1 {
			p := JSONCheck{ s: text, i: i }
			for literal in ['null', 'true', 'false'] {
				assert p.has_literal(literal) == text[i..].starts_with(literal)
			}
		}
	}
}

fn test_prefix_strict_json_differential() {
	mut cases := ['', 'null', 'true', 'false', '0', '-0', '1.0', '1e0', '01', '1e+', '-1',
		'18446744073709551616', '{}', '[]', '[null,true,false,0,-12,1.2e-3]',
		'{"unknown":[true,{"x":null}],"日本語":false}', '{"a":1,"a":2}', '{"a":1,"\\u0061":2}',
		'{"x":"\\ud800"}', '[true,]', '{"x":false} trailing', '{"x":"' + [u8(0xff)].bytestr() + '"}']
	for literal in ['null', 'true', 'false'] {
		for n in 0 .. literal.len + 1 {
			for suffix in ['', ' ', 'x', '0', 'true', ',', ']', '}'] {
				word := literal[..n] + suffix
				cases << word
				cases << '[' + word + ']'
				cases << '{"unknown":' + word + '}'
			}
		}
	}
	for depth in [511, 512, 513] { cases << '['.repeat(depth) + 'null' + ']'.repeat(depth) }
	for body in cases {
		mut old_error := ''
		old := original_strict_json(body) or {
			old_error = err.msg()
			json2.Any(json2.Null{})
		}
		mut new_error := ''
		new := strict_json(body) or {
			new_error = err.msg()
			json2.Any(json2.Null{})
		}
		assert new_error == old_error, body
		assert new == old, body
	}
}
