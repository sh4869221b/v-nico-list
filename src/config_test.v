module main

import time

fn test_defaults_repeated_and_explicit_overrides() {
	cfg := parse_config(['--concurrency-adaptive', '-T2', '--concurrency-targets=4', '-H0', '--json',
		'--json=false', '-uc5']) or { panic(err) }
	assert cfg.targets == 4 && cfg.explicit_targets
	assert cfg.http == 0 && cfg.explicit_http
	assert cfg.pages == 1 && !cfg.explicit_pages
	assert cfg.adaptive && !cfg.json && cfg.url && cfg.comment == 5
}

fn test_removed_flags_unknown_and_invalid_config() {
	for args in [['--concurrency', '2'], ['--concurrency-target', '2'], ['--c', '2'], ['--T', '2'],
		['-T0'], ['--retries=0'], ['--rate-limit=NaN'], ['--dateafter=20240230'],
		['--dateafter=20250101', '--datebefore=20240101'], ['--min-interval='], ['--min-interval=-']] {
		if _ := parse_config(args) {
			assert false, 'accepted ${args}'
		}
	}
}

fn test_go_duration_units_and_signs() {
	assert (parse_duration('1h2m3.5s') or { panic(err) }) == time.hour + 2 * time.minute + 3500 * time.millisecond
	assert (parse_duration('+20ms') or { panic(err) }) == 20 * time.millisecond
	assert (parse_duration('-0') or { panic(err) }) == 0
	for s in ['', '-', '10', '1x', '1..2s'] {
		if _ := parse_duration(s) {
			assert false, s
		}
	}
}

fn test_native_integer_flags_accept_go_base_prefixes_and_64bit_comments() {
	cfg := parse_config(['-c0x80000000', '-T0x2', '-P010']) or { panic(err) }
	assert cfg.comment == 2147483648
	assert cfg.targets == 2
	assert cfg.pages == 8
}

fn test_explicit_http_fixed_while_adaptive_feedback_changes_budget() {
	cfg := parse_config(['-A', '-H2']) or { panic(err) }
	mut c := new_control(cfg) or { panic(err) }
	p1 := c.acquire_http(1) or { panic(err) }
	c.mu.lock()
	c.budget = 1
	c.mu.unlock()
	p2 := c.acquire_http(1) or { panic(err) }
	assert c.active == 2
	c.finish_http(p1, 200, false, 0, 0)
	c.finish_http(p2, 200, false, 0, 0)
	assert c.active == 0
}

fn test_adaptive_429_decreases_once_per_generation() {
	cfg := parse_config(['-A']) or { panic(err) }
	mut c := new_control(cfg) or { panic(err) }
	p1 := c.acquire_http(1) or { panic(err) }
	p2 := c.acquire_http(1) or { panic(err) }
	c.finish_http(p1, 429, false, 0, time.second)
	assert c.budget == 4
	c.finish_http(p2, 429, false, 0, time.second)
	assert c.budget == 4
	assert c.cooldown > now_ns()
}

fn test_adaptive_page_supply_grows_without_changing_explicit_target_limit() {
	cfg := parse_config(['-A', '-T1']) or { panic(err) }
	mut c := new_control(cfg) or { panic(err) }
	c.last_change = now_ns() - time.second
	c.page_pending = 1
	for _ in 0 .. 64 {
		c.active = c.budget
		p := Permit{ started: now_ns() - 100 * time.millisecond, generation: c.generation }
		c.finish_http(p, 200, false, 0, 0)
	}
	assert c.budget == 12
	assert c.cfg.targets == 1 && c.cfg.explicit_targets
	assert c.counters['adaptive_increases'] == 1
}

fn test_reuse_connections_is_explicit_opt_in() {
	assert !(parse_config([]string{}) or { panic(err) }).reuse_connections
	assert (parse_config(['--reuse-connections']) or { panic(err) }).reuse_connections
	assert !(parse_config(['--reuse-connections', '--reuse-connections=false']) or { panic(err) }).reuse_connections
}
