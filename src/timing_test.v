module main

import time

fn test_saturated_deadlines_and_products_keep_long_waits_future() {
	assert deadline_after(100, 20) == 120
	assert deadline_after(100, 0) == 100
	assert deadline_after(100, max_wait_ns) == max_wait_ns
	assert deadline_after(max_wait_ns - 10, 10) == max_wait_ns
	assert deadline_after(max_wait_ns - 10, 11) == max_wait_ns
	assert positive_product(9223372036, time.second) == 9223372036000000000
	assert positive_product(9223372037, time.second) == max_wait_ns
}

fn test_rate_intervals_saturate_before_conversion_and_never_disable_positive_rate() {
	assert rate_interval(0) == 0
	assert rate_interval(20) == 50 * time.millisecond
	assert rate_interval(1e-300) == max_wait_ns
	assert rate_interval(1e-10) == max_wait_ns
	assert rate_interval(f64(time.second) / f64(max_wait_ns)) == max_wait_ns
	assert rate_interval(1e300) == 1
	assert rate_interval(1e-9) == 1000000000000000000
}

fn timing_test_acquire(mut c Control, done chan string) {
	c.acquire_http(1) or {
		done <- err.msg()
		return
	}
	done <- 'granted'
}

fn test_extreme_pacing_grants_first_only_and_remains_cancellable() {
	for args in [['--rate-limit=1e-300'], ['--min-interval=9223372036854000000ns', '-A']] {
		cfg := parse_config(args) or { panic(err) }
		mut c := new_control(cfg) or { panic(err) }
		p := c.acquire_http(1) or { panic(err) }
		c.finish_http(p, 200, false, 0, 0)
		assert c.next_start == max_wait_ns
		done := chan string{cap: 1}
		worker := spawn timing_test_acquire(mut c, done)
		select {
			_ := <-done {
				assert false, 'extreme pacing granted a second immediate dispatch'
			}
			40 * time.millisecond {
			}
		}
		c.mu.lock()
		c.stop = true
		c.mu.unlock()
		mut cancel_error := ''
		mut completed := false
		select {
			message := <-done {
				cancel_error = message
				completed = true
			}
			500 * time.millisecond {
			}
		}
		assert completed, 'extreme pacing did not cancel promptly'
		assert cancel_error == 'context canceled'
		if completed { worker.wait() }
		assert c.pending == 0
	}
}

fn test_extreme_retry_after_seconds_and_dates_saturate_without_overflow() {
	current := time.unix_nanosecond(1704067200, 900000000)
	for value in ['9223372037', '+9223372036854775807', '9223372036854775807',
		'9999999999999999999999999999999999', 'Fri, 31 Dec 9999 23:59:59 GMT'] {
		assert retry_after_at({
			'retry-after': value
		}, 429, current) == max_wait_ns, value
	}
	assert retry_after_at({
		'retry-after': '9223372036'
	}, 429, current) == 9223372036000000000
	assert retry_after_at({
		'retry-after': '00000000000000000000000000000001'
	}, 429, current) == time.second
	assert retry_after_at({
		'retry-after': 'Mon, 01 Jan 2024 00:00:02 GMT'
	}, 429, current) == 1100 * time.millisecond
	assert retry_after_at({
		'retry-after': '-1'
	}, 429, current) == 0
	assert retry_after_at({
		'retry-after': '9223372037'
	}, 503, current) == 0
	cfg := parse_config(['-A']) or { panic(err) }
	mut c := new_control(cfg) or { panic(err) }
	c.mu.lock()
	c.throttle(Permit{}, max_wait_ns, 12345)
	c.mu.unlock()
	assert c.cooldown == max_wait_ns
}

fn test_extreme_wall_timeout_addition_and_subtraction_preserve_duration() {
	start := time.unix_nanosecond(1704067200, 999999999)
	for duration in [i64(1), i64(time.second), max_wait_ns - 1000000, max_wait_ns] {
		deadline := wall_deadline_after(start, duration)
		assert deadline > start
		assert wall_remaining(deadline, start) == duration
		assert wall_remaining(start, deadline) == 0
	}
}
