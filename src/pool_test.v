module main

import net
import os
import time

fn test_pool_identity_covers_route_and_trust() {
	base := wire_pool_key('https', 'example:443', '', 'ca')
	assert base != wire_pool_key('http', 'example:443', '', 'ca')
	assert base != wire_pool_key('https', 'other:443', '', 'ca')
	assert base != wire_pool_key('https', 'example:443', 'http://proxy:80', 'ca')
	assert base != wire_pool_key('https', 'example:443', '', 'other-ca')
	assert wire_pool_key('https', 'example:443', 'http://a:p@proxy', 'ca') != wire_pool_key('https', 'example:443', 'http://b:p@proxy', 'ca')
	assert wire_pool_key('ab', 'c', '', '') != wire_pool_key('a', 'bc', '', '')
}

fn wire_pool_serve(mut listener net.TcpListener, raw string, keep bool) {
	mut conn := listener.accept() or { return }
	defer { conn.close() or {} }
	conn.set_read_timeout(2 * time.second)
	mut request := []u8{len: 8192}
	conn.read(mut request) or { return }
	conn.write_string(raw) or { return }
	if keep {
		conn.read(mut request) or { return }
		conn.write_string(raw) or { return }
		// Command/pool cleanup must close the connection without waiting for EOF.
		n := conn.read(mut request) or {
			assert err.code() != net.err_timed_out.code()
			0
		}
		assert n == 0
	}
}

fn test_pool_reuses_only_successful_unambiguous_complete_responses() {
	old := os.getenv_opt('NO_PROXY')
	os.setenv('NO_PROXY', '*', true)
	defer {
		if value := old { os.setenv('NO_PROXY', value, true) } else { os.unsetenv('NO_PROXY') }
	}
	for raw in [
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok',
		'HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok',
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: keep-alive, CLOSE\r\n\r\nok',
		'HTTP/1.1 200 OK\r\n\r\nok',
		'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nokEXTRA',
		'HTTP/1.1 429 Slow\r\nContent-Length: 0\r\n\r\n',
		'HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nok',
	] {
		keep := raw == 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok'
		mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
		port := listener.addr() or { panic(err) }.port() or { panic(err) }
		server := spawn wire_pool_serve(mut listener, raw, keep)
		mut c := new_control(Config{ reuse_connections: true }) or { panic(err) }
		url := 'http://127.0.0.1:${port}/fixture'
		transport_get(url, time.second, c) or { WireResponse{} }
		assert c.idle.len == if keep { 1 } else { 0 }
		if keep {
			// The second request occurs in a new call and refreshes its deadline.
			result := transport_get(url, 2 * time.second, c) or { panic(err) }
			assert result.body.bytestr() == 'ok'
			assert c.idle.len == 1
		}
		c.close_idle()
		assert c.idle.len == 0
		assert c.pool_closed
		server.wait()
		listener.close() or {}
	}
}

fn test_pool_caps_expires_isolates_and_closes_idle_sockets() {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	address := listener.addr() or { panic(err) }.str()
	mut peers := []&net.TcpConn{}
	mut c := new_control(Config{ reuse_connections: true }) or { panic(err) }
	for i in 0 .. wire_idle_limit + 1 {
		conn := net.dial_tcp(address) or { panic(err) }
		peer := listener.accept() or { panic(err) }
		peers << peer
		mut stream := &WireStream{ tcp: conn }
		c.put_idle('key-${i}', mut stream)
	}
	assert c.idle.len == wire_idle_limit
	// Overflow socket closes immediately, rather than growing the pool.
	mut buffer := []u8{len: 1}
	mut overflow := peers.last()
	overflow.set_read_timeout(time.second)
	assert (overflow.read(mut buffer) or {
		assert err.code() != net.err_timed_out.code()
		0
	}) == 0
	assert c.take_idle('other-origin') == none
	mut selected := c.take_idle('key-1') or { panic('missing idle connection') }
	assert c.idle.len == wire_idle_limit - 1
	selected.close()
	// Force expiry without making tests sleep five seconds.
	entry := c.idle[0]
	c.idle[0] = WireIdle{ key: entry.key, stream: entry.stream, returned: now_ns() - wire_idle_lifetime }
	assert c.take_idle(entry.key) == none
	assert c.idle.len == wire_idle_limit - 2
	c.close_idle()
	c.close_idle() // Cleanup is idempotent.
	for mut peer in peers {
		peer.set_read_timeout(time.second)
		assert (peer.read(mut buffer) or {
			assert err.code() != net.err_timed_out.code()
			0
		}) == 0
		peer.close() or {}
	}
	conn := net.dial_tcp(address) or { panic(err) }
	mut peer := listener.accept() or { panic(err) }
	mut late := &WireStream{ tcp: conn }
	c.put_idle('late', mut late)
	assert c.idle.len == 0
	peer.set_read_timeout(time.second)
	assert (peer.read(mut buffer) or {
		assert err.code() != net.err_timed_out.code()
		0
	}) == 0
	peer.close() or {}
}
