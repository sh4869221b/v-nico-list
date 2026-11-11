module main

import os
import time
import json2

struct Sample {
	nanoseconds     i64
	iterations      int
	checksum        i64
	allocated_bytes u64
	heap_before     u64
	heap_after      u64
}

fn main() {
	body := os.read_file(os.args[1]) or { panic(err) }
	kind := os.args[2]
	if os.args[3] == 'verify' {
		page := parse_page(body, kind) or { panic(err) }
		println(json2.encode(page))
		println(json2.encode(strict_json(body) or { panic(err) }))
		return
	}
	iterations := os.args[3].int()
	warmups := os.args[4].int()
	assert iterations > 0 && warmups > 0
	mut last := Page{}
	mut checksum := i64(0)
	for _ in 0 .. warmups {
		last = parse_page(body, kind) or { panic(err) }
		checksum += last.items.len
	}
	// Keep normal production GC behavior. No forced collection or disabled GC.
	before := gc_heap_usage()
	started := time.sys_mono_now()
	for _ in 0 .. iterations {
		last = parse_page(body, kind) or { panic(err) }
		checksum += last.items.len + last.status + last.total
	}
	elapsed := time.sys_mono_now() - started
	after := gc_heap_usage()
	assert after.total_bytes >= before.total_bytes
	println(json2.encode(Sample{
		nanoseconds:     elapsed
		iterations:      iterations
		checksum:        checksum
		allocated_bytes: u64(after.total_bytes) - u64(before.total_bytes)
		heap_before:     u64(before.heap_size)
		heap_after:      u64(after.heap_size)
	}))
	// All fields and all items are checked by Python outside the timed region.
	println(json2.encode(last))
}
