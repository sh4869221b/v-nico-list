module main

import math
import time

const max_wait_ns = i64(9223372036854775807)

// Scheduling durations are nonnegative. Saturate instead of letting an extreme
// user interval or Retry-After turn a far-future deadline into an elapsed one.
fn deadline_after(start i64, delay i64) i64 {
	if delay <= 0 { return start }
	if start > max_wait_ns - delay { return max_wait_ns }
	return start + delay
}

fn positive_product(value i64, factor i64) i64 {
	if value <= 0 || factor <= 0 { return 0 }
	if value > max_wait_ns / factor { return max_wait_ns }
	return value * factor
}

fn rate_interval(rate f64) i64 {
	if rate <= 0 { return 0 }
	ns := f64(time.second) / rate
	// f64(max_wait_ns) rounds up to 2^63, which cannot be cast to i64.
	if !math.is_finite(ns) || ns >= f64(max_wait_ns) { return max_wait_ns }
	return ns_max(1, i64(ns))
}

// time.Time.add adds the full duration to its nanosecond field before splitting
// it; split first so a near-MaxInt64 duration cannot overflow that intermediate.
fn wall_deadline_after(start time.Time, delay i64) time.Time {
	if delay <= 0 { return start }
	nanos := i64(start.nanosecond) + delay % time.second
	seconds := start.unix() + delay / time.second + nanos / time.second
	return time.unix_nanosecond(seconds, int(nanos % time.second))
}

// Subtract in seconds/nanoseconds with a borrow before multiplying. In
// particular a Retry-After date in year 9999 must remain a long positive wait.
fn wall_remaining(deadline time.Time, current time.Time) i64 {
	if deadline <= current { return 0 }
	mut seconds := deadline.unix() - current.unix()
	mut nanos := i64(deadline.nanosecond) - current.nanosecond
	if nanos < 0 {
		seconds--
		nanos += time.second
	}
	return deadline_after(positive_product(seconds, time.second), nanos)
}
