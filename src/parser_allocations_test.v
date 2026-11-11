module main

import time

// Frozen date paths from 5f375c1, including error messages and UTC conversion.
fn original_timestamp(s string) !i64 {
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
	base := original_date(date)!
	h := s[11..13].int()
	m := s[14..16].int()
	sec := s[17..19].int()
	if h > 23 || m > 59 || sec > 59 { return error('invalid timestamp time') }
	return base + h * 3600 + m * 60 + sec - offset
}

fn original_date(s string) !i64 {
	if s.len != 8 || !all_digits(s) { return error('invalid date') }
	y := s[..4].int()
	m := s[4..6].int()
	d := s[6..].int()
	if y < 0 || m < 1 || m > 12 || d < 1 || d > time.days_in_month(m, y)! {
		return error('invalid date')
	}
	return time.new(time.Time{ year: y, month: m, day: d }).unix()
}

fn check_date_contract(s string) {
	mut old_error := ''
	old := original_date(s) or {
		old_error = err.msg()
		i64(0)
	}
	mut new_error := ''
	new := parse_date(s) or {
		new_error = err.msg()
		i64(0)
	}
	assert old_error == new_error, s
	assert old == new, s
}

fn check_timestamp_contract(s string) {
	mut old_error := ''
	old := original_timestamp(s) or {
		old_error = err.msg()
		i64(0)
	}
	mut new_error := ''
	new := timestamp(s) or {
		new_error = err.msg()
		i64(0)
	}
	assert old_error == new_error, s
	assert old == new, s
}

fn test_date_components_against_frozen_paths() {
	for year in [0, 1, 4, 100, 400, 1000, 1600, 1900, 2000, 2023, 2024, 2100, 2400, 9999] {
		for month in 0 .. 14 {
			for day in [0, 1, 28, 29, 30, 31, 32] {
				check_date_contract('${year:04}${month:02}${day:02}')
				for tail in ['T00:00:00Z', 'T23:59:59.123456789Z', 'T12:34:56+23:59', 'T12:34:56-23:59',
					'T24:00:00Z', 'T00:60:00Z', 'T00:00:60Z', 'T00:00:00+24:00', 'T00:00:00+00:60',
					'T00:00:00.Z'] {
					check_timestamp_contract('${year:04}-${month:02}-${day:02}' + tail)
				}
			}
		}
	}
	for s in ['', '2024010', '202401011', '2024x101', '00000000', 'abcdefgh'] {
		check_date_contract(s)
	}
	for s in ['', '2024-01-01', '2024-01-01T00:00:00', '2024-01-01T00:00:00z', '2024-01-01t00:00:00Z',
		'2024-01-01T00:00:00.1+00:00', '2024-01-01T00:00:00-00:00', '2024-01-01T00:00:00+0x:00',
		'2024-01-01T00:00:00+00:0x', '2024-01-01T00:00:00Zx'] {
		check_timestamp_contract(s)
	}
	valid := '2024-02-29T12:34:56Z'
	for i in 0 .. valid.len {
		check_timestamp_contract(valid[..i])
		check_timestamp_contract(valid[..i] + 'x' + valid[i + 1..])
	}
}

fn test_preallocated_page_sizes_and_nulls() {
	for kind in ['user', 'mylist'] {
		key := if kind == 'user' { 'essential' } else { 'video' }
		for size in [0, 1, 2, 31, 100, 1000] {
			mut raw := []string{}
			for i in 0 .. size {
				raw << '{"' + key + '":{"id":"sm${i}","registeredAt":null,"count":{"comment":${i}}}}'
			}
			items := '{"items":[' + raw.join(',') + ']}'
			data := if kind == 'user' { items } else { '{"mylist":' + items + '}' }
			page := parse_page('{"data":' + data + '}', kind) or { panic(err) }
			assert page.items.len == size
			for i, v in page.items {
				assert v.id == 'sm${i}' && v.comment == i && v.registered == -62135596800
			}
		}
		for body in ['null', '{}', '{"data":null}', '{"data":{"items":null,"mylist":{"items":null}}}'] {
			page := parse_page(body, kind) or { panic(err) }
			assert page.items.len == 0
		}
		bad := '{"data":' + if kind == 'user' {
			'{"items":[{"essential":{"registeredAt":""}}]}}'
		} else {
			'{"mylist":{"items":[{"video":{"registeredAt":""}}]}}}'
		}
		if _ := parse_page(bad, kind) {
			assert false
		}
	}
}

fn validation_fixture(scope string, key string, value string) string {
	member := '"${key}":${value}'
	item := if scope == 'series' {
		'{"series":{' + member + '}}'
	} else if scope == 'video' {
		'{"essential":{' + member + '}}'
	} else {
		'{"essential":{"' + scope + '":{' + member + '}}}'
	}
	return '{"data":{"items":[' + item + ']}}'
}

fn test_constant_validation_fields_preserve_null_and_types() {
	// Deliberately independent lists: every old validation field must still be checked.
	for group in [
		['video', 'string', 'type', 'title', 'shortDescription', 'latestCommentSummary'],
		['video', 'integer', 'duration'],
		['video', 'bool', 'isChannelVideo', 'isPaymentRequired', 'requireSensitiveMasking', '9d091f87',
			'acf68865'],
		['count', 'integer', 'view', 'mylist', 'like'],
		['thumbnail', 'string', 'url', 'middleUrl', 'largeUrl', 'listingUrl', 'nHdUrl'],
		['owner', 'string', 'ownerType', 'id', 'name', 'iconUrl'],
		['series', 'string', 'title'],
		['series', 'integer', 'id', 'order'],
	] {
		for key in group[2..] {
			for value in ['null', '""', '"text"', '0', '-1', '1.0', '1e0', 'true', 'false', '{}',
				'[]'] {
				want := value == 'null' || (group[1] == 'string' && value.starts_with('"')) || (group[1] == 'integer' && value in [
					'0',
					'-1',
				]) || (group[1] == 'bool' && value in ['true', 'false'])
				mut accepted := true
				parse_page(validation_fixture(group[0], key, value), 'user') or {
					accepted = false
					Page{}
				}
				assert accepted == want, '${group[0]}.${key}=${value}'
			}
		}
	}
}

fn test_large_invalid_array_still_rejected_without_an_item_limit() {
	// The AST must still validate the complete input. Large inputs use the
	// original empty Video array, so this error does not reserve 10000 Videos.
	body := '{"data":{"items":[false,' + 'null,'.repeat(9998) + 'null]}}'
	if _ := parse_page(body, 'user') {
		assert false
	}
}

fn test_page_initial_capacity_policy() {
	for size in [0, 1, 2, 31, 99, 100] {
		assert page_initial_capacity(size) == size
	}
	for size in [101, 1000, 10000, 1000000000] {
		assert page_initial_capacity(size) == 0
	}
}
