module main

import json2
import encoding.utf8
import strconv

struct Target {
	kind  string
	id    string
	order int
}

fn parse_target(text string) ?Target {
	// Go's user regexp is always tried first, even if a mylist occurs earlier.
	for kind in ['user', 'mylist'] {
		needle := 'nicovideo.jp/${kind}/'
		mut offset := 0
		for offset < text.len {
			idx := text[offset..].index(needle) or { break }
			start := offset + idx + needle.len
			mut end := start
			limit := if kind == 'user' { 9 } else { 12 }
			for end < text.len && end - start < limit && text[end].is_digit() { end++ }
			if end > start { return Target{ kind: kind, id: text[start..end] } }
			offset = start
		}
	}
	return none
}

fn sort_text(id string) string {
	text := if id.len >= 2 { id[2..] } else { id }
	if !all_digits(text) { return text }
	mut norm := text.trim_left('0')
	if norm == '' { norm = '0' }
	if norm.len > 20 || (norm.len == 20 && norm > '18446744073709551615') { return text }
	return norm
}

struct IDSortKey {
	id  string
	key string
}

fn compare_id_keys(a &IDSortKey, b &IDSortKey) int {
	if a.key.len != b.key.len { return if a.key.len < b.key.len { -1 } else { 1 } }
	if a.key != b.key { return if a.key < b.key { -1 } else { 1 } }
	return if a.id < b.id {
		-1
	} else if a.id > b.id {
		1
	} else {
		0
	}
}

fn sort_ids(mut ids []string) {
	if ids.len < 2 { return }
	// Normalize once per ID, rather than twice per comparison. Preserve the
	// length/key/full-ID ordering, including nonnumeric and overflow fallback.
	mut keyed := []IDSortKey{cap: ids.len}
	for id in ids { keyed << IDSortKey{ id: id, key: sort_text(id) } }
	keyed.sort_with_compare(compare_id_keys)
	for i, item in keyed { ids[i] = item.id }
}

struct Video {
	id         string
	comment    i64
	registered i64
}

struct Page {
	items     []Video
	status    int
	total     i64 = -1
	has_total bool
	not_found bool
}

// Validate the complete JSON grammar and object-name uniqueness before decoding.
// This also validates unknown members, matching encoding/json/v2's default.
struct JSONCheck {
	s string
mut:
	i int
}

fn (mut p JSONCheck) ws() {
	for p.i < p.s.len && p.s[p.i] in [u8(` `), `\n`, `\r`, `\t`] { p.i++ }
}

fn (mut p JSONCheck) quoted() !string {
	if p.i >= p.s.len || p.s[p.i] != `"` { return error('JSON: expected string') }
	start := p.i
	p.i++
	for p.i < p.s.len {
		c := p.s[p.i]
		p.i++
		if c == `"` { return p.s[start + 1..p.i - 1] }
		if c < 0x20 { return error('JSON: control character in string') }
		if c == `\\` { return p.quoted_escaped(start)! }
	}
	return error('JSON: unterminated string')
}

// Called only after the first backslash. strict_json validates raw UTF-8 before
// parsing; this path validates and decodes escapes once, including both halves
// of a surrogate pair. Buffer growth is bounded by the consumed input size.
fn (mut p JSONCheck) quoted_escaped(start int) !string {
	mut out := []u8{cap: p.i - start}
	for j in start + 1 .. p.i - 1 { out << p.s[j] }
	mut escape := true
	for p.i < p.s.len {
		c := p.s[p.i]
		p.i++
		if escape {
			escape = false
			match c {
				`"`, `\\`, `/` { out << c }
				`b` { out << u8(8) }
				`f` { out << u8(12) }
				`n` { out << u8(10) }
				`r` { out << u8(13) }
				`t` { out << u8(9) }
				`u` {
					mut code := p.hex4()!
					if code >= 0xd800 && code <= 0xdbff {
						if p.i + 6 > p.s.len || p.s[p.i] != `\\` || p.s[p.i + 1] != `u` {
							return error('JSON: unpaired unicode surrogate')
						}
						p.i += 2
						lo := p.hex4()!
						if lo < 0xdc00 || lo > 0xdfff {
							return error('JSON: unpaired unicode surrogate')
						}
						code = 0x10000 + ((code - 0xd800) << 10) + lo - 0xdc00
					} else if code >= 0xdc00 && code <= 0xdfff {
						return error('JSON: unpaired unicode surrogate')
					}
					// code is a Unicode scalar, with surrogates excluded above.
					if code < 0x80 {
						out << u8(code)
					} else if code < 0x800 {
						out << u8(0xc0 | (code >> 6))
						out << u8(0x80 | (code & 0x3f))
					} else if code < 0x10000 {
						out << u8(0xe0 | (code >> 12))
						out << u8(0x80 | ((code >> 6) & 0x3f))
						out << u8(0x80 | (code & 0x3f))
					} else {
						out << u8(0xf0 | (code >> 18))
						out << u8(0x80 | ((code >> 12) & 0x3f))
						out << u8(0x80 | ((code >> 6) & 0x3f))
						out << u8(0x80 | (code & 0x3f))
					}
				}
				else { return error('JSON: invalid escape') }
			}
		} else if c == `"` {
			return out.bytestr()
		} else if c < 0x20 {
			return error('JSON: control character in string')
		} else if c == `\\` {
			escape = true
		} else {
			out << c
		}
	}
	return error('JSON: unterminated string')
}

// Compare only the literal bytes; slicing the remaining input copies it in V.
// Keep prefix semantics: value()/strict_json() validate the following delimiter.
fn (p &JSONCheck) has_literal(literal string) bool {
	if literal.len > p.s.len - p.i { return false }
	for j, c in literal {
		if p.s[p.i + j] != c { return false }
	}
	return true
}

fn (mut p JSONCheck) hex4() !u32 {
	if p.s.len - p.i < 4 { return error('JSON: truncated unicode escape') }
	mut code := u32(0)
	for _ in 0 .. 4 {
		c := p.s[p.i]
		p.i++
		n := if c >= `0` && c <= `9` {
			c - `0`
		} else if c >= `a` && c <= `f` {
			c - `a` + 10
		} else if c >= `A` && c <= `F` {
			c - `A` + 10
		} else {
			return error('JSON: invalid unicode escape')
		}
		code = (code << 4) | u32(n)
	}
	return code
}

fn (mut p JSONCheck) value(depth int) !json2.Any {
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
		if p.has_literal(literal) {
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

fn strict_json(s string) !json2.Any {
	if !utf8.validate_str(s) { return error('JSON: invalid UTF-8') }
	mut p := JSONCheck{ s: s }
	result := p.value(0)!
	p.ws()
	if p.i != s.len { return error('JSON: trailing data') }
	return result
}

fn object(v json2.Any) !map[string]json2.Any {
	if v is json2.Null { return map[string]json2.Any{} }
	if v is map[string]json2.Any { return v }
	return error('JSON: expected object')
}

fn field(o map[string]json2.Any, key string) json2.Any {
	return o[key] or { json2.Any(json2.Null{}) }
}

fn string_value(v json2.Any) !string {
	if v is json2.Null { return '' }
	if v is string { return v }
	return error('JSON: expected string')
}

fn integer_value(v json2.Any) !i64 {
	if v is json2.Null { return 0 }
	if v is i64 { return v }
	if v is int { return i64(v) }
	if v is u64 {
		if v > u64(9223372036854775807) { return error('JSON: integer overflow') }
		return i64(v)
	}
	// JSON floating spellings such as 1.0 and 1e0 are rejected for Go int fields.
	return error('JSON: expected integer')
}

fn array_value(v json2.Any) ![]json2.Any {
	if v is json2.Null { return []json2.Any{} }
	if v is []json2.Any { return v }
	return error('JSON: expected array')
}

fn timestamp(s string) !i64 {
	if s.len < 20 || s[4] != `-` || s[7] != `-` || s[10] != `T` || s[13] != `:` || s[16] != `:` {
		return error('invalid RFC3339 timestamp')
	}
	for a in [0, 5, 8, 11, 14, 17] {
		n := if a == 0 { 4 } else { 2 }
		if !all_digits(s[a..a + n]) { return error('invalid RFC3339 timestamp') }
	}
	mut pos := 19
	if pos < s.len && s[pos] == `.` {
		pos++
		start := pos
		for pos < s.len && s[pos].is_digit() { pos++ }
		if pos == start { return error('invalid timestamp fraction') }
	}
	mut offset := 0
	if pos < s.len && s[pos] == `Z` && pos + 1 == s.len {
	} else if pos + 6 == s.len && s[pos] in [u8(`+`), `-`] && s[pos + 3] == `:` && all_digits(s[pos + 1..pos + 3]) && all_digits(s[pos + 4..]) {
		h := s[pos + 1..pos + 3].int()
		m := s[pos + 4..].int()
		if h > 23 || m > 59 { return error('invalid timestamp timezone') }
		offset = (h * 60 + m) * 60
		if s[pos] == `-` { offset = -offset }
	} else {
		return error('invalid timestamp timezone')
	}
	base := date_components(s[..4].int(), s[5..7].int(), s[8..10].int())!
	h := s[11..13].int()
	m := s[14..16].int()
	sec := s[17..19].int()
	if h > 23 || m > 59 || sec > 59 { return error('invalid timestamp time') }
	return base + h * 3600 + m * 60 + sec - offset
}

fn validate_fields(o map[string]json2.Any, strings []string, integers []string, bools []string) ! {
	for key in strings { string_value(field(o, key))! }
	for key in integers { integer_value(field(o, key))! }
	for key in bools {
		v := field(o, key)
		if v !is json2.Null && v !is bool { return error('JSON: expected boolean at ${key}') }
	}
}

const video_string_fields = ['type', 'title', 'shortDescription', 'latestCommentSummary']
const video_integer_fields = ['duration']
const video_bool_fields = [
	'isChannelVideo',
	'isPaymentRequired',
	'requireSensitiveMasking',
	'9d091f87',
	'acf68865',
]
const count_integer_fields = ['view', 'mylist', 'like']
const thumbnail_string_fields = ['url', 'middleUrl', 'largeUrl', 'listingUrl', 'nHdUrl']
const owner_string_fields = ['ownerType', 'id', 'name', 'iconUrl']
const series_string_fields = ['title']
const series_integer_fields = ['id', 'order']

// item_count comes from an array length. Reserve only small pages; large
// inputs retain the original growth strategy rather than reserving up front.
fn page_initial_capacity(item_count int) int {
	return if item_count <= 100 { item_count } else { 0 }
}

fn parse_page(body string, kind string) !Page {
	root := object(strict_json(body)!)!
	meta := object(field(root, 'meta'))!
	status := integer_value(field(meta, 'status'))!
	data := object(field(root, 'data'))!
	items_obj := object(if kind == 'mylist' { field(data, 'mylist') } else { field(root, 'data') })!
	mut total_value := field(data, 'totalCount')
	if kind == 'mylist' {
		x := field(items_obj, 'totalCount')
		y := field(items_obj, 'totalItemCount')
		if x !is json2.Null {
			total_value = x
		} else if y !is json2.Null {
			total_value = y
		}
		integer_value(x)!
		integer_value(y)!
	}
	integer_value(field(data, 'totalCount'))!
	total := if total_value is json2.Null { i64(-1) } else { integer_value(total_value)! }
	raw_items := array_value(field(items_obj, 'items'))!
	mut items := []Video{cap: page_initial_capacity(raw_items.len)}
	for raw in raw_items {
		item := object(raw)!
		key := if kind == 'user' { 'essential' } else { 'video' }
		v := object(field(item, key))!
		id := string_value(field(v, 'id'))!
		count := object(field(v, 'count'))!
		comment := integer_value(field(count, 'comment'))!
		mut registered := i64(-62135596800)
		rv := field(v, 'registeredAt')
		if rv !is json2.Null { registered = timestamp(string_value(rv)!)! }
		if kind == 'user' {
			validate_fields(v, video_string_fields, video_integer_fields, video_bool_fields)!
			validate_fields(count, [], count_integer_fields, [])!
			validate_fields(object(field(v, 'thumbnail'))!, thumbnail_string_fields, [], [])!
			validate_fields(object(field(v, 'owner'))!, owner_string_fields, [], [])!
			validate_fields(object(field(item, 'series'))!, series_string_fields, series_integer_fields, [])!
		}
		items << Video{ id: id, comment: comment, registered: registered }
	}
	return Page{ items: items, status: int(status), total: total, has_total: total_value !is json2.Null }
}

fn filter_page(page Page, cfg Config) []string {
	mut ids := []string{}
	for v in page.items {
		if v.comment > cfg.comment && v.registered >= cfg.after_unix && v.registered < cfg.before_unix {
			ids << v.id
		}
	}
	return ids
}
