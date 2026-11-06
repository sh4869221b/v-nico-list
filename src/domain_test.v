module main

import json2
import time

fn test_input_precedence_partial_and_limits() {
	t := parse_target('nicovideo.jp/mylist/5 then fake://nicovideo.jp/user/12345678901') or { panic('target') }
	assert t.kind == 'user'
	assert t.id == '123456789'
	assert (parse_target('nicovideo.jp/mylist/00000123456789') or { panic('target') }).id == '000001234567'
	assert parse_target('nothing') == none
}

fn test_unicode_input_trimming_preserves_invalid_bytes_for_json_validation() {
	assert trim_input_line('\u3000\u00a0hello\u2003') == 'hello'
	assert trim_input_line('\u3000\u2003') == ''
	invalid := [u8(0xff)].bytestr()
	assert trim_input_line(' ' + invalid + ' ') == invalid
}

fn test_numeric_sort_and_overflow_fallback() {
	mut ids := ['sm10', 'so2', 'sm0002', 'sm1', 'sm18446744073709551616']
	ids.sort_with_compare(compare_ids)
	assert ids == ['sm1', 'sm0002', 'so2', 'sm10', 'sm18446744073709551616']
}

fn test_json_contract_null_case_types_duplicates_utf8() {
	for body in ['null', '{"data":null}', '{"data":{"items":null}}', '{}'] {
		p := parse_page(body, 'user') or { panic(err) }
		assert p.items.len == 0
		assert p.total == -1
	}
	good := '{"meta":{"status":200},"data":{"totalCount":1,"items":[{"essential":{"id":"sm9","registeredAt":"2024-01-10T00:00:00Z","count":{"comment":12}}}]}}'
	p := parse_page(good, 'user') or { panic(err) }
	assert p.items[0].id == 'sm9'
	assert p.items[0].comment == 12
	assert p.total == 1
	negative := parse_page('{"data":{"totalCount":-1}}', 'user') or { panic(err) }
	assert negative.has_total && negative.total == -1
	case_page := parse_page('{"data":{"items":[{"essential":{"ID":"sm9","COUNT":{"COMMENT":12}}}]}}', 'user') or { panic(err) }
	assert case_page.items[0].id == ''
	for bad in ['{"x":1,"x":2}', '{"x":1,"\\u0078":2}', '{"x":"\\ud800"}', '{"meta":{"status":"200"}}',
		'{"data":{"totalCount":1.0}}', '{} {}', '[1,]', '{"data":{"items":[{"essential":{"id":9}}]}}',
		'{"data":{"items":[{"essential":{"registeredAt":"2024-01-10T0:00:00Z"}}]}}'] {
		if _ := parse_page(bad, 'user') {
			assert false, 'accepted ${bad}'
		}
	}
	invalid := '{"x":"' + [u8(0xff)].bytestr() + '"}'
	if _ := strict_json(invalid) {
		assert false
	}
}

fn test_filters_exclusive_comment_and_utc_dates() {
	cfg := parse_config(['--comment', '3', '--dateafter', '20240101', '--datebefore', '20240101']) or { panic(err) }
	p := Page{
		items: [
			Video{ id: 'sm1', comment: 3, registered: timestamp('2024-01-01T12:00:00Z') or { panic(err) } },
			Video{ id: 'sm2', comment: 4, registered: timestamp('2024-01-02T00:59:59+01:00') or { panic(err) } },
			Video{ id: 'sm3', comment: 5, registered: timestamp('2024-01-02T00:00:00Z') or { panic(err) } },
		]
	}
	assert filter_page(p, cfg) == ['sm2']
}

fn test_timestamp_strict_and_offsets() {
	assert (timestamp('2024-02-29T23:00:00-01:00') or { panic(err) }) == (timestamp('2024-03-01T00:00:00.123456789Z') or { panic(err) })
	for s in ['2023-02-29T00:00:00Z', '2024-01-10t00:00:00z', '2024-01-10T24:00:00Z',
		'2024-01-10T00:00:00+24:00', '2024-01-10T00:00:00.Z'] {
		if _ := timestamp(s) {
			assert false, s
		}
	}
}

fn test_output_schema_arrays_and_excluded_order() {
	obj := json2.encode(OutputPayload{ targets: [TargetResult{ kind: 'user', id: '1', order: 3 }] })
	assert obj.contains('"items":[]')
	assert obj.contains('"type":"user"')
	assert !obj.contains('"order"')
}

fn test_retry_delay_capped_exponential() {
	assert retry_delay(1, 0) == 100 * time.millisecond
	assert retry_delay(10, 0) == 30 * time.second
	assert retry_delay(2, 3 * time.second) == 3 * time.second
}
