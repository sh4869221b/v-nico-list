module main

import sync
import time
import os
import json2
import encoding.utf8

struct Decision {
	elapsed_seconds f64
	from            int
	to              int
	generation      u64
	reason          string
}

struct Permit {
	started    i64
	generation u64
	rate_wait  i64
}

@[heap]
struct Control {
mut:
	mu               sync.Mutex
	cfg              Config
	started          i64
	budget           int = 8
	initial          int = 8
	maximum          int
	active           int
	pending          int
	target_pending   int
	page_pending     int
	next_start       i64
	cooldown         i64
	recovery_at      i64
	recovery_starts  int
	generation       u64
	pressure_cutoff  u64
	has_cutoff       bool
	window_started   i64
	last_change      i64
	services         []i64
	eligible         int
	overloads        int
	saturation       f64
	rate_time        i64
	service_time     i64
	baseline         i64
	previous_service i64
	window_max       i64
	healthy          int
	slow             int
	floor            int
	floor_p95        i64
	decisions        []Decision
	counters         map[string]i64
	durations        map[string]i64
	status_counts    map[string]i64
	log              os.File
	has_log          bool
	seen             map[string]bool
	output_count     int
	output_error     string
	stop             bool
}

fn now_ns() i64 { return time.sys_mono_now() }

fn new_control(cfg Config) !&Control {
	n := now_ns()
	mut c := &Control{ cfg: cfg, started: n, window_started: n, last_change: n }
	c.mu.init()
	if cfg.adaptive && cfg.explicit_http && cfg.http > 0 {
		c.maximum = cfg.http
		c.budget = int_min(8, c.maximum)
		c.initial = c.budget
	}
	if cfg.logfile != '' {
		c.log = os.open_file(cfg.logfile, 'a')!
		c.has_log = true
	}
	return c
}

fn ns_max(a i64, b i64) i64 { return if a > b { a } else { b } }

fn ns_min(a i64, b i64) i64 { return if a < b { a } else { b } }

fn cancelled() bool { return C.nico_cancelled() != 0 }

fn check_cancelled() ! { if cancelled() { return error('context canceled') } }

fn sleep_cancel(d i64) ! {
	until := now_ns() + d
	for {
		check_cancelled()!
		left := until - now_ns()
		if left <= 0 { return }
		time.sleep(time.Duration(ns_min(left, 20 * time.millisecond)))
	}
}

fn (mut c Control) log_event(level string, msg string, attrs map[string]json2.Any) {
	mut obj := attrs.clone()
	obj['time'] = time.utc().format_rfc3339()
	obj['level'] = level
	obj['msg'] = msg
	raw_line := json2.encode(obj) + '\n'
	line := if utf8.validate_str(raw_line) { raw_line } else { raw_line.runes().string() }
	c.mu.lock()
	if c.has_log { c.log.write_string(line) or {} } else { eprint(line) }
	c.mu.unlock()
}

fn (mut c Control) add_counter(name string, amount i64) {
	c.mu.lock()
	c.counters[name] += amount
	c.mu.unlock()
}

fn (mut c Control) stopped() bool {
	c.mu.lock()
	stop := c.stop
	c.mu.unlock()
	return stop || cancelled()
}

fn (mut c Control) acquire_http(attempt int) !Permit {
	wait_started := now_ns()
	c.mu.lock()
	c.pending++
	c.mu.unlock()
	for {
		if c.stopped() {
			c.mu.lock()
			c.pending--
			c.mu.unlock()
			return error('context canceled')
		}
		c.mu.lock()
		n := now_ns()
		limit := if c.cfg.adaptive && !c.cfg.explicit_http { c.budget } else { c.cfg.http }
		ready := !c.cfg.adaptive || (n >= c.cooldown && n >= c.recovery_at)
		// Rate permission and admission are committed atomically: queued work
		// never carries an old grant across an adaptive cooldown.
		if (limit == 0 || c.active < limit) && ready && n >= c.next_start {
			mut interval := i64(c.cfg.interval)
			if c.cfg.rate > 0 { interval = ns_max(interval, i64(f64(time.second) / c.cfg.rate)) }
			c.next_start = n + interval
			c.active++
			c.pending--
			c.counters['attempts']++
			if attempt > 1 { c.counters['retries']++ }
			c.counters['max_in_flight'] = ns_max(c.counters['max_in_flight'], c.active)
			if c.cfg.adaptive && c.recovery_starts > 0 {
				c.recovery_starts--
				pace := ns_min(250 * time.millisecond, ns_max(25 * time.millisecond, c.baseline / c.budget))
				c.recovery_at = n + pace
			}
			wait := n - wait_started
			c.durations['admission_wait_ns'] += wait
			permit := Permit{
				started:    n
				generation: c.generation
				rate_wait:  if interval > 0 {
					wait
				} else {
					0
				}
			}
			c.mu.unlock()
			return permit
		}
		c.mu.unlock()
		time.sleep(time.millisecond)
	}
}

fn (mut c Control) record(from int, reason string, n i64) {
	c.decisions << Decision{ elapsed_seconds: f64(n - c.started) / time.second, from: from, to: c.budget, generation: c.generation, reason: reason }
	if c.decisions.len > 32 { c.decisions.delete(0) }
}

fn (mut c Control) reset_window(n i64) {
	if c.window_max > 0 { c.previous_service = c.window_max }
	c.services.clear()
	c.eligible = 0
	c.overloads = 0
	c.saturation = 0
	c.rate_time = 0
	c.service_time = 0
	c.window_max = 0
	c.window_started = n
}

fn (mut c Control) decrease(reason string, n i64) {
	c.healthy = 0
	from := c.budget
	if c.budget > 1 && n - c.last_change >= 25 * time.millisecond {
		c.budget = int_max(1, c.budget / 2)
		c.pressure_cutoff = c.generation
		c.has_cutoff = true
		c.generation++
		c.last_change = n
		c.counters['adaptive_decreases']++
		c.slow = 0
		c.floor = 0
	}
	c.record(from, reason, n)
}

fn (mut c Control) throttle(p Permit, delay i64, n i64) {
	c.counters['adaptive_http_429']++
	c.cooldown = ns_max(c.cooldown, n + ns_max(delay, 100 * time.millisecond))
	c.healthy = 0
	c.slow = 0
	c.floor = 0
	from := c.budget
	if !c.has_cutoff || p.generation > c.pressure_cutoff {
		c.budget = int_max(1, c.budget / 2)
		c.pressure_cutoff = c.generation
		c.has_cutoff = true
		c.generation++
		c.last_change = n
		if c.budget < from { c.counters['adaptive_decreases']++ }
	}
	c.recovery_starts = c.budget
	c.record(from, 'http_429', n)
	c.reset_window(n)
}

fn (mut c Control) evaluate(n i64) {
	from := c.budget
	mut reason := 'insufficient_samples'
	if n < c.cooldown {
		reason = 'cooldown'
	} else if c.eligible >= 20 && c.overloads >= 4 && c.overloads * 10 >= c.eligible {
		c.decrease('retry_pressure', n)
		return
	} else if c.services.len >= 20 {
		c.services.sort()
		p95 := ns_max(1, c.services[(95 * c.services.len + 99) / 100 - 1])
		if c.baseline == 0 { c.baseline = p95 }
		if f64(p95) > 1.5 * f64(c.baseline) {
			c.healthy = 0
			c.slow++
			if c.budget == 1 && c.overloads == 0 {
				if c.floor == 0 || f64(p95) > 1.1 * f64(c.floor_p95) || f64(p95) < 0.9 * f64(c.floor_p95) {
					c.floor = 1
					c.floor_p95 = p95
				} else {
					c.floor++
				}
				if c.floor >= 4 {
					c.baseline = p95
					c.floor = 0
					c.slow = 0
					c.counters['adaptive_baseline_resets']++
					c.record(from, 'baseline_reset', n)
					return
				}
			}
			if c.slow >= 2 {
				c.decrease('latency', n)
				return
			}
			reason = 'latency'
		} else {
			c.slow = 0
			c.floor = 0
			if c.overloads == 0 && p95 < c.baseline { c.baseline -= (c.baseline - p95) / 5 }
			if c.rate_time > 0 && f64(c.rate_time) / f64(c.rate_time + c.service_time) > 0.1 {
				reason = 'rate_limited'
			} else if c.pending + c.target_pending + c.page_pending == 0 || c.saturation / f64(c.eligible) < 0.8 {
				reason = 'scheduler_limited'
			} else if c.overloads > 0 {
				reason = 'retry_pressure'
			} else {
				c.healthy++
				reason = 'healthy'
				if c.healthy >= 2 && n - c.last_change >= 25 * time.millisecond {
					step := if c.budget < 8 { 1 } else { 4 }
					if c.maximum == 0 || c.budget < c.maximum {
						c.budget = if c.maximum > 0 {
							int_min(c.maximum, c.budget + step)
						} else {
							c.budget + step
						}
						c.generation++
						c.counters['adaptive_increases']++
						c.last_change = n
						c.healthy = 0
					} else {
						reason = 'at_max'
					}
				}
			}
		}
	}
	if reason !in ['healthy', 'at_max', 'latency'] {
		c.healthy = 0
		c.slow = 0
		c.floor = 0
	}
	c.record(from, reason, n)
}

fn (mut c Control) finish_http(p Permit, status int, transport_error bool, bytes int, retry_delay i64) {
	n := now_ns()
	service := n - p.started
	c.mu.lock()
	c.active--
	c.status_counts[status.str()]++
	c.durations['request_ns'] += service
	c.counters['body_bytes'] += bytes
	if transport_error { c.counters['transport_errors']++ }
	if c.cfg.adaptive {
		if status == 429 { c.throttle(p, retry_delay, n) }
		if p.generation != c.generation {
			c.counters['adaptive_stale_completions']++
		} else {
			fresh := ns_max(time.second, ns_max(2 * ns_max(c.baseline, ns_max(c.previous_service, c.window_max)), 40 * ns_max(c.baseline, ns_max(c.previous_service, c.window_max)) / c.budget))
			if n - c.window_started > fresh {
				c.record(c.budget, 'insufficient_samples', n)
				c.reset_window(n)
			}
			success := status == 200 && !transport_error
			overload := status >= 500 || transport_error
			if success || overload {
				c.eligible++
				c.window_max = ns_max(c.window_max, service)
				c.service_time += service
				c.rate_time += p.rate_wait
				c.saturation += f64(int_min(c.budget, c.active + 1)) / f64(c.budget)
				if success {
					c.services << service
					c.counters['adaptive_successes']++
				} else {
					c.overloads++
				}
			}
			if c.eligible >= 32 || (n - c.window_started >= time.second && c.eligible >= 20) {
				c.counters['adaptive_windows']++
				c.evaluate(n)
				c.reset_window(n)
			}
		}
	}
	c.mu.unlock()
}

fn retry_after(headers map[string]string, status int) i64 {
	if status != 429 { return 0 }
	s := (headers['retry-after'] or { '' }).trim_space()
	if all_digits(s) {
		sec := s.i64()
		if sec > 0 && sec < 9223372036 { return sec * time.second }
		return 0
	}
	if t := time.parse_rfc2616(s) {
		delta := t - time.utc()
		if delta > 0 { return i64(delta) }
	}
	return 0
}

fn retry_delay(attempt int, header i64) i64 {
	shift := int_min(attempt - 1, 9)
	return ns_max(header, ns_min(30 * time.second, 100 * time.millisecond * (i64(1) << shift)))
}

fn (mut c Control) emit_items(items []string) {
	c.mu.lock()
	for id in items {
		if c.cfg.dedupe && id in c.seen { continue }
		if c.cfg.dedupe { c.seen[id] = true }
		line := (if c.cfg.url { 'https://www.nicovideo.jp/watch/' } else { '' }) + id + '\n'
		if C.nico_output(line.str, uint(line.len)) == 0 {
			c.output_error = 'failed to write stdout'
			c.stop = true
			C.nico_cancel()
			break
		}
		c.output_count++
	}
	c.mu.unlock()
}

fn (mut c Control) metrics_log() {
	c.mu.lock()
	mut http := map[string]json2.Any{}
	for k, v in c.counters { http[k] = v }
	for k, v in c.durations { http[k] = v }
	mut statuses := map[string]json2.Any{}
	for k, v in c.status_counts { statuses[k] = v }
	http['statuses'] = statuses
	if c.cfg.adaptive {
		http['adaptive'] = map[string]json2.Any{
			'initial':    c.initial
			'current':    c.budget
			'max':        c.maximum
			'generation': c.generation
			'decisions':  json2.decode[json2.Any](json2.encode(c.decisions)) or { json2.Any([]json2.Any{}) }
		}
	}
	c.mu.unlock()
	c.log_event('INFO', 'http_metrics', {
		'http': json2.Any(http)
	})
}
