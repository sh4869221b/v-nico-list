module main

import os
import time
import json2
import encoding.utf8

#include "@VMODROOT/src/native.h"

fn C.nico_signals()
fn C.nico_cancelled() int
fn C.nico_cancel()
fn C.nico_output(s &u8, n uint) int

struct InputEvent {
	present bool
	line    string
	error   string
}

struct InputCounts {
mut:
	total   int
	valid   int
	invalid int
}

struct OutputPayload {
	inputs       InputCounts
	invalid      []string
	targets      []TargetResult
	errors       []string
	output_count int
	items        []string
}

fn valid_payload_utf8(p OutputPayload) bool {
	for s in p.invalid { if !utf8.validate_str(s) { return false } }
	for s in p.errors { if !utf8.validate_str(s) { return false } }
	for s in p.items { if !utf8.validate_str(s) { return false } }
	for t in p.targets {
		if !utf8.validate_str(t.kind) || !utf8.validate_str(t.id) || !utf8.validate_str(t.error) {
			return false
		}
		for s in t.items { if !utf8.validate_str(s) { return false } }
	}
	return true
}

fn trim_input_line(s string) string {
	if s.is_pure_ascii() { return s.trim_space() }
	mut start := 0
	mut end := 0
	mut i := 0
	mut leading := true
	for i < s.len {
		r, width := utf8.decode_rune_at(s, i)
		if utf8.is_space(r) {
			if leading { start = i + width }
		} else {
			leading = false
			end = i + width
		}
		i += width
	}
	if start >= end { return '' }
	return s[start..end]
}

fn file_inputs(mut f os.File, ch chan InputEvent) ! {
	mut line := []u8{}
	for {
		check_cancelled()!
		data, n := os.fd_read(f.fd, 4096)
		if n < 0 { return error('input read error') }
		if n == 0 { break }
		for b in data {
			if b == `\n` {
				text := trim_input_line(line.bytestr())
				if text != '' { ch <- InputEvent{ present: true, line: text } }
				line.clear()
			} else {
				line << b
				if line.len >= 1024 * 1024 { return error('input line exceeds 1 MiB limit') }
			}
		}
	}
	if line.len > 0 {
		text := trim_input_line(line.bytestr())
		if text != '' { ch <- InputEvent{ present: true, line: text } }
	}
}

fn produce_inputs(cfg Config, ch chan InputEvent) {
	defer { ch.close() }
	for arg in cfg.args { ch <- InputEvent{ present: true, line: arg } }
	if cfg.input_file != '' {
		mut f := os.open(cfg.input_file) or {
			ch <- InputEvent{ error: err.msg() }
			return
		}
		file_inputs(mut f, ch) or {
			f.close()
			ch <- InputEvent{ error: err.msg() }
			return
		}
		f.close()
	}
	if cfg.stdin {
		mut f := os.stdin()
		file_inputs(mut f, ch) or {
			ch <- InputEvent{ error: err.msg() }
			return
		}
	}
}

fn compare_targets(a &TargetResult, b &TargetResult) int {
	if a.kind != b.kind { return if a.kind < b.kind { -1 } else { 1 } }
	left := a.id.trim_left('0')
	right := b.id.trim_left('0')
	if left.len != right.len { return if left.len < right.len { -1 } else { 1 } }
	if left != right { return if left < right { -1 } else { 1 } }
	if a.id != b.id { return if a.id < b.id { -1 } else { 1 } }
	return if a.error < b.error {
		-1
	} else if a.error > b.error {
		1
	} else {
		0
	}
}

fn run(cfg Config) ! {
	mut c := new_control(cfg)!
	defer {
		if cfg.metrics { c.metrics_log() }
		if c.has_log { c.log.close() }
	}
	input := chan InputEvent{cap: 16}
	done := chan TargetResult{cap: 16}
	spawn produce_inputs(cfg, input)
	mut counts := InputCounts{}
	mut invalid := []string{}
	mut results := []TargetResult{}
	mut errors := []string{}
	mut input_error := ''
	mut input_closed := false
	mut active := 0
	mut pending := Target{}
	mut has_pending := false
	mut fetch_ok := 0
	mut fetch_err := 0
	mut order := 0
	show_progress := !cfg.no_progress && (cfg.progress || os.is_atty(2) > 0)
	for !input_closed || active > 0 || has_pending {
		if c.stopped() {
			input_closed = true
			has_pending = false
		}
		if has_pending {
			c.mu.lock()
			limit := if cfg.adaptive && !cfg.explicit_targets { c.budget } else { cfg.targets }
			c.target_pending = if active >= limit { 1 } else { 0 }
			c.mu.unlock()
			if active < limit {
				spawn target_worker(cfg, pending, mut c, done)
				active++
				has_pending = false
			}
		}
		mut event := InputEvent{}
		mut got_input := false
		mut result := TargetResult{}
		mut got_result := false
		if has_pending || input_closed {
			if active == 0 { break }
			select {
				r := <-done {
					result = r
					got_result = true
				}
				time.millisecond {
				}
			}
		} else {
			select {
				e := <-input {
					if input.closed && !e.present && e.error == '' {
						input_closed = true
					} else {
						event = e
						got_input = true
					}
				}
				r := <-done {
					result = r
					got_result = true
				}
				time.millisecond {
				}
			}
		}
		if got_input {
			if event.error != '' {
				input_error = event.error
				input_closed = true
				C.nico_cancel()
			} else {
				counts.total++
				if t := parse_target(event.line) {
					counts.valid++
					pending = Target{ kind: t.kind, id: t.id, order: order }
					order++
					has_pending = true
				} else {
					counts.invalid++
					if cfg.json { invalid << event.line }
					c.log_event('WARN', 'invalid input', {
						'input': event.line
					})
				}
			}
		}
		if got_result {
			active--
			if !cfg.no_sort || cfg.json { results << result }
			if result.error != '' {
				fetch_err++
				if cfg.json || errors.len == 0 { errors << result.error }
				c.log_event('ERROR', 'failed to get video list', {
					'error': result.error
				})
			} else {
				fetch_ok++
			}
			if show_progress {
				eprint('\rprocessed ${fetch_ok + fetch_err + counts.invalid}/${counts.total}')
			}
		}
	}
	if counts.total == 0 && input_error == '' { input_error = 'no inputs provided' }
	mut items := []string{}
	if !cfg.no_sort || cfg.json {
		if cfg.no_sort { results.sort(a.order < b.order) }
		for result in results { items << result.items }
		if cfg.dedupe {
			mut seen := map[string]bool{}
			items = items.filter(fn [mut seen] (id string) bool {
				if id in seen { return false }
				seen[id] = true
				return true
			})
		}
		if !cfg.no_sort { items.sort_with_compare(compare_ids) }
		if cfg.json {
			results.sort_with_compare(compare_targets)
			payload := OutputPayload{ inputs: counts, invalid: invalid, targets: results, errors: errors, output_count: items.len, items: items }
			if !valid_payload_utf8(payload) {
				c.output_error = 'JSON output contains invalid UTF-8'
			} else {
				line := json2.encode(payload) + '\n'
				if C.nico_output(line.str, uint(line.len)) == 0 {
					c.output_error = 'failed to write stdout'
				}
			}
			c.output_count = items.len
		} else {
			c.emit_items(items)
		}
	}
	c.log_event('INFO', 'video list', {
		'count': c.output_count
	})
	if show_progress { eprintln('') }
	eprintln('summary inputs=${counts.total} valid=${counts.valid} invalid=${counts.invalid} fetch_ok=${fetch_ok} fetch_err=${fetch_err} output_count=${c.output_count}')
	if c.output_error != '' { return error(c.output_error) }
	if input_error != '' { return error(input_error) }
	if cfg.strict && counts.invalid > 0 { return error('invalid input detected') }
	if !cfg.best_effort && errors.len > 0 { return error(errors[0]) }
}

fn main() {
	C.nico_signals()
	cfg := parse_config(os.args[1..]) or {
		eprintln('Error: ${err.msg()}')
		exit(1)
	}
	if cfg.help {
		println(help_text)
		return
	}
	if cfg.version {
		println('v-nico-list version 0.1.0')
		return
	}
	run(cfg) or {
		eprintln('Error: ${err.msg()}')
		exit(1)
	}
}
