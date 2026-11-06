module main

import net
import os
import time

fn wire_test_serve(mut listener net.TcpListener, response []u8, pause time.Duration) {
	mut conn := listener.accept() or { return }
	defer { conn.close() or {} }
	mut request := []u8{len: 8192}
	conn.read(mut request) or { return }
	if pause > 0 { time.sleep(pause) }
	conn.write(response) or {}
}

fn wire_test_response(response string, timeout time.Duration, pause time.Duration) !WireResponse {
	old_no_proxy := os.getenv_opt('NO_PROXY')
	os.setenv('NO_PROXY', '*', true)
	defer {
		if old := old_no_proxy { os.setenv('NO_PROXY', old, true) } else { os.unsetenv('NO_PROXY') }
	}
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	listener.set_accept_timeout(2 * time.second)
	port := listener.addr()!.port()!
	server := spawn wire_test_serve(mut listener, response.bytes(), pause)
	defer {
		server.wait()
		listener.close() or {}
	}
	return transport_get('http://127.0.0.1:${port}/fixture', timeout)
}

fn test_transport_reads_all_http_framing_modes() {
	for raw in [
		'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello',
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhe\r\n3;name=value\r\nllo\r\n0\r\nX-Checksum: valid\r\n\r\n',
		'HTTP/1.0 200 OK\r\n\r\nhello',
		'HTTP/1.1 103 Early Hints\r\nLink: </a>\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello',
	] {
		result := wire_test_response(raw, time.second, 0) or { panic(err) }
		assert result.status == 200
		assert result.body.bytestr() == 'hello'
	}
}

fn test_transport_near_max_timeout_does_not_become_immediate_deadline() {
	result := wire_test_response('HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello', time.Duration(max_wait_ns - 1000000), 10 * time.millisecond) or { panic(err) }
	assert result.body.bytestr() == 'hello'
}

fn test_transport_rejects_ambiguous_or_truncated_framing() {
	for raw in [
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nabc',
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nshort',
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nshortXX0\r\n\r\n',
		'HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nContent-Length: 0\r\n\r\n',
		'HTTP/1.1 200 OK\r\nBad Header: x\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Length: 8388609\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Encoding: br\r\nContent-Length: 0\r\n\r\n',
	] {
		mut rejected := false
		wire_test_response(raw, time.second, 0) or {
			if !raw.contains('Bad Header') {
				assert err.code() == 20001
			}
			rejected = true
		}
		assert rejected, raw
	}
}

fn test_transport_bounds_headers_and_deadline() {
	mut rejected := false
	wire_test_response('HTTP/1.1 200 OK\r\nX-Large: ' + 'x'.repeat(wire_header_limit) + '\r\n\r\n', time.second, 0) or { rejected = true }
	assert rejected
	start := time.now()
	mut timed_out := false
	wire_test_response('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n', 30 * time.millisecond, 200 * time.millisecond) or {
		timed_out = true
		assert err.code() == 20002
	}
	assert timed_out
	assert time.since(start) < time.second
}

fn test_transport_error_status_does_not_read_body() {
	result := wire_test_response('HTTP/1.1 201 Created\r\nContent-Length: 999999999\r\n\r\n', time.second, 0) or { panic(err) }
	assert result.status == 201
	assert result.body.len == 0
	mut rejected := false
	wire_test_response('HTTP/1.1 200 OK\r\nContent-Length: 8388609\r\n\r\n', time.second, 0) or {
		rejected = true
		assert err.code() == 20001
		assert err.msg() == 'response body exceeds 8 MiB limit'
	}
	assert rejected
}

fn test_transport_gzip_callback_enforces_exact_expansion_limit() {
	mut state := WireInflate{ body: []u8{len: wire_body_limit - 1}, deadline: time.now().add(time.second) }
	assert wire_inflate_chunk([u8(1)], &state) == 1
	assert state.body.len == wire_body_limit
	assert wire_inflate_chunk([u8(2)], &state) == 0
	assert state.excess
	assert state.body.len == wire_body_limit
}

fn test_transport_no_proxy_host_port_and_ip_rules() {
	assert wire_no_proxy('api.example.com', '443', '.example.com')
	assert !wire_no_proxy('example.com', '443', '.example.com')
	assert wire_no_proxy('example.com', '443', 'example.com:443')
	assert !wire_no_proxy('example.com', '80', 'example.com:443')
	assert !wire_no_proxy('notexample.com', '443', 'example.com')
	assert wire_no_proxy('10.2.3.4', '80', '10.0.0.0/8')
	assert !wire_no_proxy('11.2.3.4', '80', '10.0.0.0/8')
	assert wire_no_proxy('2001:db8::1234', '443', '2001:db8::/32')
	assert wire_no_proxy('0:0:0:0:0:0:0:1', '443', '[::1]:443')
}

fn test_transport_chunk_extension_syntax() {
	assert wire_chunk_size('f')! == 15
	assert wire_chunk_size('a ; name = "quoted;value"; next=token')! == 10
	for line in ['1;=value', '1;name=', '1;name="unterminated', '1;name="bad\x01"', '1;name="ok"junk',
		'x', '1 '] {
		mut rejected := false
		wire_chunk_size(line) or { rejected = true }
		assert rejected, line
	}
}

fn wire_test_redirect_server(mut listener net.TcpListener, requests chan string, arrivals chan i64) {
	for i in 0 .. 2 {
		mut conn := listener.accept() or { return }
		mut data := []u8{len: 8192}
		n := conn.read(mut data) or { return }
		arrivals <- now_ns()
		requests <- data[..n].bytestr()
		conn.write_string(if i == 0 {
			'HTTP/1.1 302 Found\r\nLocation: ../final?ok=1\r\nContent-Length: 999999999\r\n\r\n'
		} else {
			'HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhello'
		}) or {}
		conn.close() or {}
	}
}

fn test_transport_follows_relative_redirect_without_reading_its_body() {
	old_no_proxy := os.getenv_opt('NO_PROXY')
	os.setenv('NO_PROXY', '*', true)
	defer {
		if old := old_no_proxy {
			os.setenv('NO_PROXY', old, true)
		} else {
			os.unsetenv('NO_PROXY')
		}
	}
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	listener.set_accept_timeout(time.second)
	port := listener.addr()!.port()!
	requests := chan string{cap: 2}
	arrivals := chan i64{cap: 2}
	server := spawn wire_test_redirect_server(mut listener, requests, arrivals)
	defer {
		server.wait()
		listener.close() or {}
	}
	cfg := parse_config(['--min-interval=80ms'])!
	mut c := new_control(cfg)!
	result := transport_get('http://127.0.0.1:${port}/old/start', time.second, c)!
	assert result.body.bytestr() == 'hello'
	assert (<-requests).starts_with('GET /old/start HTTP/1.1\r\n')
	assert (<-requests).starts_with('GET /final?ok=1 HTTP/1.1\r\n')
	first := <-arrivals
	assert (<-arrivals) - first >= 40 * time.millisecond
}

fn wire_test_pacing_server(mut listener net.TcpListener, arrivals chan i64) {
	for _ in 0 .. 2 {
		mut conn := listener.accept() or { return }
		mut data := []u8{len: 8192}
		conn.read(mut data) or { return }
		arrivals <- now_ns()
		conn.close() or {}
	}
}

fn test_transport_dispatch_pacing_survives_delayed_connection_setup() ! {
	cfg := parse_config(['--min-interval=80ms'])!
	mut c := new_control(cfg)!
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	listener.set_accept_timeout(time.second)
	port := listener.addr()!.port()!
	arrivals := chan i64{cap: 2}
	server := spawn wire_test_pacing_server(mut listener, arrivals)
	defer {
		server.wait()
		listener.close() or {}
	}
	mut first := net.dial_tcp('127.0.0.1:${port}')!
	mut second := net.dial_tcp('127.0.0.1:${port}')!
	defer {
		first.close() or {}
		second.close() or {}
	}
	// Delay the first dispatch until both permits have been granted. This models
	// a first request's connection setup taking longer than the pacing gap.
	first_permit := c.acquire_http(1)!
	second_permit := c.acquire_http(1)!
	assert second_permit.started - first_permit.started >= 80 * time.millisecond
	deadline := wall_deadline_after(time.now(), time.second)
	mut first_stream := WireStream{ tcp: first, deadline: deadline }
	mut second_stream := WireStream{ tcp: second, deadline: deadline }
	request := 'GET /fixture HTTP/1.1\r\nHost: localhost\r\n\r\n'
	c.write_http(mut first_stream, request)!
	first_arrival := <-arrivals
	c.write_http(mut second_stream, request)!
	assert (<-arrivals) - first_arrival >= 40 * time.millisecond
	c.finish_http(first_permit, 200, false, 0, 0)
	c.finish_http(second_permit, 200, false, 0, 0)
	assert c.active == 0
}

fn test_transport_dispatch_wait_checks_deadline_and_cancellation() ! {
	cfg := parse_config(['--min-interval=80ms'])!
	mut c := new_control(cfg)!
	c.next_dispatch = max_wait_ns
	mut stream := WireStream{ deadline: wall_deadline_after(time.now(), 30 * time.millisecond) }
	mut expired := false
	c.write_http(mut stream, '') or {
		assert err.code() == 20002
		expired = true
	}
	assert expired
	assert !c.dispatching
	c.stop = true
	stream.deadline = wall_deadline_after(time.now(), time.second)
	mut stopped := false
	c.write_http(mut stream, '') or {
		assert err.code() == 20003
		stopped = true
	}
	assert stopped
	assert !c.dispatching
}
