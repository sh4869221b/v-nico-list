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
	date := s[..4] + s[5..7] + s[8..10]
	base := parse_date(date)!
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
	mut items := []Video{}
	for raw in array_value(field(items_obj, 'items'))! {
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
			validate_fields(v, ['type', 'title', 'shortDescription', 'latestCommentSummary'], ['duration'], [
				'isChannelVideo',
				'isPaymentRequired',
				'requireSensitiveMasking',
				'9d091f87',
				'acf68865',
			])!
			validate_fields(count, [], ['view', 'mylist', 'like'], [])!
			validate_fields(object(field(v, 'thumbnail'))!, ['url', 'middleUrl', 'largeUrl',
				'listingUrl', 'nHdUrl'], [], [])!
			validate_fields(object(field(v, 'owner'))!, ['ownerType', 'id', 'name', 'iconUrl'], [], [])!
			validate_fields(object(field(item, 'series'))!, ['title'], ['id', 'order'], [])!
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
