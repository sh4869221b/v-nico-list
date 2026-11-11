module main

import net
import time

const wire_idle_limit = 16
const wire_idle_lifetime = 5 * time.second

struct WireIdle {
	key      string
	stream   &WireStream
	returned i64
}

fn (mut s WireStream) close() {
	net.shutdown(s.tcp.sock.handle)
	if s.tls != unsafe { nil } {
		s.tls.set_read_timeout(time.millisecond)
		s.tls.close() or {}
	}
	s.tcp.close() or {}
}

// Pool keys are length-delimited, including the effective route and trust file.
// A CONNECT tunnel is never shared across origins, proxies, or credentials.
fn wire_pool_key(scheme string, authority string, proxy string, trust string) string {
	return '${scheme.len}:${scheme}${authority.len}:${authority}${proxy.len}:${proxy}${trust.len}:${trust}'
}

fn (mut c Control) take_idle(key string) ?&WireStream {
	mut expired := []&WireStream{}
	mut found := &WireStream(unsafe { nil })
	n := now_ns()
	c.pool_mu.lock()
	for i := c.idle.len - 1; i >= 0; i-- {
		entry := c.idle[i]
		if n - entry.returned >= wire_idle_lifetime {
			expired << entry.stream
			c.idle.delete(i)
		} else if found == unsafe { nil } && entry.key == key {
			found = entry.stream
			c.idle.delete(i)
		}
	}
	c.pool_mu.unlock()
	for mut stream in expired { stream.close() }
	if found == unsafe { nil } { return none }
	return found
}

fn (mut c Control) put_idle(key string, mut stream WireStream) {
	c.pool_mu.lock()
	if !c.pool_closed && c.idle.len < wire_idle_limit && !cancelled() {
		c.idle << WireIdle{ key: key, stream: &stream, returned: now_ns() }
		c.pool_mu.unlock()
		return
	}
	c.pool_mu.unlock()
	stream.close()
}

fn (mut c Control) close_idle() {
	c.pool_mu.lock()
	c.pool_closed = true
	idle := c.idle.clone()
	c.idle.clear()
	c.pool_mu.unlock()
	for entry in idle {
		mut stream := entry.stream
		stream.close()
	}
}

// Called only after body framing and representation decoding succeeded. Header
// presence alone must never authorize returning an unread response to the pool.
fn wire_reusable(response WireResponse) bool {
	if response.status != 200 || response.version != 'HTTP/1.1' { return false }
	for token in response.headers['connection'].to_lower().split(',') {
		if token.trim(' \t') == 'close' { return false }
	}
	return 'content-length' in response.headers || response.headers['transfer-encoding'].to_lower().trim(' \t') == 'chunked'
}
