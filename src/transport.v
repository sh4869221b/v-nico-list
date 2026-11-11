module main

import compress.gzip
import encoding.base64
import io
import net
import net.ssl
import net.urllib
import os
import time

fn C.inet_pton(family i32, saddr &char, addr voidptr) i32

const wire_header_limit = 64 * 1024
const wire_encoded_limit = 16 * 1024 * 1024
const wire_body_limit = 8 * 1024 * 1024

struct WireResponse {
	version string
	status  int
	headers map[string]string
	body    []u8
}

// Successful HTTP responses whose representation cannot be decoded are terminal:
// retrying malformed or oversized content cannot make the request succeed.
struct BodyError {
	message string
}

fn (e BodyError) msg() string { return e.message }

fn (e BodyError) code() int { return 20001 }

@[heap]
struct WireStream {
mut:
	tcp      &net.TcpConn = unsafe { nil }
	tls      &ssl.SSLConn = unsafe { nil }
	secure   bool
	deadline time.Time
	buffer   []u8 = []u8{len: 8192}
	pos      int
	end      int
}

// Only the owning request touches TLS state. The watchdog only shuts down the
// OS socket; joining it before close prevents reuse of the descriptor racing it.
fn wire_watch(handle int, deadline time.Time, done chan bool) {
	for {
		select {
			_ := <-done {
				return
			}
			10 * time.millisecond {
			}
		}
		if cancelled() || time.now() >= deadline {
			net.shutdown(handle)
			return
		}
	}
}

fn wire_check(deadline time.Time) ! {
	if cancelled() { return error_with_code('context canceled', 20003) }
	if time.now() >= deadline { return error_with_code('context deadline exceeded', 20002) }
}

fn (s &WireStream) check() ! {
	wire_check(s.deadline)!
}

// TLS backends may round the remaining socket timeout down. Classify their
// timeout as the request deadline even if the wall clock is a fraction early;
// it must not become a retryable transport failure with partial CLI output.
fn wire_io_error(deadline time.Time, cause IError) IError {
	wire_check(deadline) or { return err }
	if cause.code() == net.err_timed_out.code() {
		return error_with_code('context deadline exceeded', 20002)
	}
	return cause
}

fn wire_remaining_timeout(deadline time.Time) time.Duration {
	remaining := wall_remaining(deadline, time.now())
	// The TLS backends call Time.add internally. For their extreme-duration
	// overflow range let the request watchdog enforce the actual deadline.
	if remaining > max_wait_ns - 2 * time.second { return net.infinite_timeout }
	return time.Duration(ns_max(1, remaining))
}

fn (mut s WireStream) write(text string) ! {
	s.check()!
	if s.secure {
		s.tls.set_read_timeout(wire_remaining_timeout(s.deadline))
		s.tls.write_string(text) or {
			return wire_io_error(s.deadline, err)
		}
	} else {
		s.tcp.write_string(text) or {
			return wire_io_error(s.deadline, err)
		}
	}
	s.check()!
}

fn (mut s WireStream) fill() !bool {
	s.check()!
	n := if s.secure {
		s.tls.set_read_timeout(wire_remaining_timeout(s.deadline))
		s.tls.read(mut s.buffer) or {
			s.check()!
			if err is io.Eof { return false }
			return wire_io_error(s.deadline, err)
		}
	} else {
		wire_tcp_read(mut s.tcp, s.deadline, s.buffer.data, s.buffer.len) or {
			s.check()!
			if err is io.Eof { return false }
			return wire_io_error(s.deadline, err)
		}
	}
	s.check()!
	s.pos = 0
	s.end = n
	return n > 0
}

fn (mut s WireStream) byte() !u8 {
	if s.pos == s.end && !s.fill()! { return error('truncated HTTP response') }
	b := s.buffer[s.pos]
	s.pos++
	return b
}

fn (mut s WireStream) line(limit int) !string {
	mut line := []u8{cap: 128}
	for {
		b := s.byte()!
		if b == `\r` {
			if s.byte()! != `\n` { return error('invalid HTTP line ending') }
			return line.bytestr()
		}
		if b == `\n` || line.len >= limit { return error('HTTP header or framing limit exceeded') }
		line << b
	}
	return error('invalid HTTP line')
}

fn wire_token_byte(b u8) bool {
	return b.is_alnum() || b in [`!`, `#`, `$`, `%`, `&`, `'`, `*`, `+`, `-`, `.`, `^`, `_`, u8(96),
		`|`, `~`]
}

fn wire_token(text string) bool {
	if text.len == 0 { return false }
	for b in text { if !wire_token_byte(b) { return false } }
	return true
}

fn wire_header(line string) !(string, string) {
	i := line.index(':') or { return error('malformed HTTP header') }
	key := line[..i]
	if !wire_token(key) { return error('invalid HTTP header name') }
	value := line[i + 1..].trim(' \t')
	for b in value {
		if (b < 32 && b != `\t`) || b == 127 { return error('invalid HTTP header value') }
	}
	return key.to_lower(), value
}

fn wire_number(text string, base int, maximum u64) !int {
	if text.len == 0 { return error('invalid HTTP length') }
	mut value := u64(0)
	for c in text {
		digit := if c >= `0` && c <= `9` {
			int(c - `0`)
		} else if c >= `a` && c <= `f` {
			int(c - `a`) + 10
		} else if c >= `A` && c <= `F` {
			int(c - `A`) + 10
		} else {
			-1
		}
		if digit < 0 || digit >= base || value > (maximum - u64(digit)) / u64(base) {
			return error('invalid or excessive HTTP length')
		}
		value = value * u64(base) + u64(digit)
	}
	return int(value)
}

fn (mut s WireStream) headers() !WireResponse {
	mut used := 0
	for _ in 0 .. 9 {
		line := s.line(wire_header_limit - used)!
		used += line.len + 2
		parts := line.split(' ')
		if parts.len < 2 || parts[0] !in ['HTTP/1.0', 'HTTP/1.1'] || parts[1].len != 3 {
			return error('invalid HTTP status line')
		}
		status := wire_number(parts[1], 10, 999)!
		if status < 100 { return error('invalid HTTP status') }
		for c in line {
			if (c < 32 && c != `\t`) || c == 127 { return error('invalid HTTP status line') }
		}
		mut headers := map[string]string{}
		for {
			if used >= wire_header_limit { return error('HTTP headers exceed 64 KiB') }
			h := s.line(wire_header_limit - used)!
			used += h.len + 2
			if used > wire_header_limit { return error('HTTP headers exceed 64 KiB') }
			if h == '' { break }
			key, value := wire_header(h)!
			if key in headers { headers[key] += ',' + value } else { headers[key] = value }
		}
		if status == 101 { return error('HTTP protocol upgrade is unsupported') }
		if status >= 200 {
			return WireResponse{ status: status, headers: headers, version: parts[0] }
		}
	}
	return error('too many informational HTTP responses')
}

fn (mut s WireStream) take(mut body []u8, count int, maximum int) ! {
	if count > maximum - body.len {
		if maximum == wire_encoded_limit {
			return error('encoded response body exceeds 16 MiB limit')
		}
		return error('response body exceeds 8 MiB limit')
	}
	mut left := count
	for left > 0 {
		if s.pos == s.end && !s.fill()! { return error('truncated HTTP response body') }
		n := if left < s.end - s.pos { left } else { s.end - s.pos }
		body << s.buffer[s.pos..s.pos + n]
		s.pos += n
		left -= n
	}
}

fn wire_content_length(headers map[string]string) !int {
	mut length := -1
	if 'content-length' in headers {
		for item in headers['content-length'].split(',') {
			n := wire_number(item.trim(' \t'), 10, u64(0x7fffffff))!
			if length >= 0 && length != n { return error('conflicting HTTP content lengths') }
			length = n
		}
	}
	return length
}

fn wire_chunk_size(line string) !int {
	mut i := 0
	for i < line.len && ((line[i] >= `0` && line[i] <= `9`) || (line[i] >= `a` && line[i] <= `f`) || (line[i] >= `A` && line[i] <= `F`)) {
		i++
	}
	length := wire_number(line[..i], 16, u64(0x7fffffff))!
	for i < line.len {
		for i < line.len && line[i] in [` `, `\t`] { i++ }
		if i == line.len || line[i] != `;` { return error('invalid HTTP chunk extension') }
		i++
		for i < line.len && line[i] in [` `, `\t`] { i++ }
		start := i
		for i < line.len && wire_token_byte(line[i]) { i++ }
		if i == start { return error('invalid HTTP chunk extension name') }
		for i < line.len && line[i] in [` `, `\t`] { i++ }
		if i < line.len && line[i] == `=` {
			i++
			for i < line.len && line[i] in [` `, `\t`] { i++ }
			if i < line.len && line[i] == `"` {
				i++
				mut closed := false
				for i < line.len {
					c := line[i]
					i++
					if c == `"` {
						closed = true
						break
					}
					if c == `\\` {
						if i == line.len { return error('invalid quoted HTTP chunk extension') }
						if (line[i] < 32 && line[i] != `\t`) || line[i] == 127 {
							return error('invalid quoted HTTP chunk extension')
						}
						i++
					} else if (c < 32 && c != `\t`) || c == 127 {
						return error('invalid quoted HTTP chunk extension')
					}
				}
				if !closed { return error('unterminated HTTP chunk extension') }
			} else {
				value_start := i
				for i < line.len && wire_token_byte(line[i]) { i++ }
				if i == value_start { return error('invalid HTTP chunk extension value') }
			}
		}
	}
	return length
}

fn (mut s WireStream) body(headers map[string]string, maximum int) ![]u8 {
	length := wire_content_length(headers)!
	transfer := headers['transfer-encoding'].to_lower().trim(' \t')
	if 'transfer-encoding' in headers && (transfer != 'chunked' || length >= 0) {
		return error('unsupported or ambiguous HTTP transfer encoding')
	}
	mut body := []u8{}
	if transfer == 'chunked' {
		mut framing := 0
		for {
			line := s.line(wire_header_limit - framing)!
			framing += line.len + 2
			if framing > wire_header_limit { return error('HTTP chunk framing exceeds 64 KiB') }
			n := wire_chunk_size(line)!
			if n == 0 { break }
			s.take(mut body, n, maximum)!
			if s.byte()! != `\r` || s.byte()! != `\n` { return error('invalid HTTP chunk ending') }
			framing += 2
		}
		mut trailers := 0
		for {
			line := s.line(wire_header_limit - trailers)!
			trailers += line.len + 2
			if trailers > wire_header_limit { return error('HTTP trailers exceed 64 KiB') }
			if line == '' { break }
			key, _ := wire_header(line)!
			if key in ['content-length', 'transfer-encoding', 'host', 'content-encoding', 'content-type',
				'content-range', 'trailer', 'connection', 'te', 'authorization', 'proxy-authorization',
				'proxy-authenticate', 'www-authenticate', 'cache-control', 'expect', 'max-forwards'] {
				return error('forbidden HTTP trailer')
			}
		}
	} else if length >= 0 {
		s.take(mut body, length, maximum)!
	} else {
		for {
			if s.pos == s.end && !s.fill()! { break }
			s.take(mut body, s.end - s.pos, maximum)!
		}
	}
	return body
}

struct WireInflate {
mut:
	body        []u8
	excess      bool
	interrupted bool
	deadline    time.Time
}

fn wire_inflate_chunk(chunk []u8, userdata voidptr) int {
	mut state := unsafe { &WireInflate(userdata) }
	if cancelled() || time.now() >= state.deadline {
		state.interrupted = true
		return 0
	}
	if chunk.len > wire_body_limit - state.body.len {
		state.excess = true
		return 0
	}
	state.body << chunk
	return chunk.len
}

fn wire_env(upper string, lower string) string {
	value := os.getenv(upper)
	return if value != '' { value } else { os.getenv(lower) }
}

fn wire_ip_bytes(text string) ![]u8 {
	mut bytes := []u8{len: 16}
	if C.inet_pton(i32(net.AddrFamily.ip), &char(text.str), bytes.data) == 1 {
		return bytes[..4].clone()
	}
	if C.inet_pton(i32(net.AddrFamily.ip6), &char(text.str), bytes.data) == 1 { return bytes }
	return error('not an IP literal')
}

fn wire_ip_excluded(host string, item string) bool {
	address := wire_ip_bytes(host) or { return false }
	if !item.contains('/') {
		other := wire_ip_bytes(item.trim('[]')) or { return false }
		return address == other
	}
	network := wire_ip_bytes(item.all_before('/')) or { return false }
	if address.len != network.len { return false }
	prefix := wire_number(item.all_after('/'), 10, u64(network.len * 8)) or { return false }
	for i in 0 .. prefix {
		mask := u8(0x80) >> u8(i % 8)
		if address[i / 8] & mask != network[i / 8] & mask { return false }
	}
	return true
}

fn wire_no_proxy(host string, port string, exclusions string) bool {
	h := host.to_lower().trim_right('.')
	for raw in exclusions.split(',') {
		mut item := raw.trim_space().to_lower()
		if item == '*' { return true }
		if item == '' { continue }
		if item.contains('/') {
			if wire_ip_excluded(h, item) { return true }
			continue
		}
		mut item_port := ''
		if item.starts_with('[') || item.count(':') == 1 {
			name, p := urllib.split_host_port(item)
			if p != '' {
				item = name.trim('[]')
				item_port = p
			}
		}
		if item_port != '' && item_port != port { continue }
		item = item.trim_right('.')
		if wire_ip_excluded(h, item) { return true }
		if item.starts_with('*.') { item = item[1..] }
		if item.starts_with('.') {
			if h.ends_with(item) { return true }
		} else if h == item || h.ends_with('.' + item) {
			return true
		}
	}
	return false
}

fn wire_url(raw string) !urllib.URL {
	u := urllib.parse(raw)!
	if u.scheme !in ['http', 'https'] || u.hostname() == '' || u.opaque != '' {
		return error('unsupported HTTP URL')
	}
	if user := u.user {
		if user.username != '' || user.password != '' || user.password_set {
			return error('HTTP URL credentials are unsupported')
		}
	}
	for c in u.host { if c <= 32 || c == 127 { return error('invalid HTTP host') } }
	if u.port() != '' {
		if wire_number(u.port(), 10, 65535)! == 0 { return error('invalid HTTP port') }
	}
	return u
}

// Admission precedes connection setup. Pace the final write as well so slow
// DNS, dialing or TLS cannot turn separately admitted requests into a burst.
fn (mut c Control) write_http(mut stream WireStream, request string) ! {
	mut interval := i64(c.cfg.interval)
	if c.cfg.rate > 0 { interval = ns_max(interval, rate_interval(c.cfg.rate)) }
	if interval == 0 {
		stream.write(request)!
		return
	}
	for {
		stream.check()!
		if c.stopped() { return error_with_code('context canceled', 20003) }
		n := now_ns()
		c.mu.lock()
		ready := !c.cfg.adaptive || n >= c.cooldown
		c.mu.unlock()
		c.dispatch_mu.lock()
		if ready && !c.dispatching && n >= c.next_dispatch {
			c.dispatching = true
			c.dispatch_mu.unlock()
			break
		}
		c.dispatch_mu.unlock()
		time.sleep(time.millisecond)
	}
	// The ownership flag serializes writes without holding either mutex across
	// network I/O. Other requests can still observe cancellation/deadlines.
	defer {
		c.dispatch_mu.lock()
		c.next_dispatch = deadline_after(now_ns(), interval)
		c.dispatching = false
		c.dispatch_mu.unlock()
	}
	stream.write(request)!
}

fn transport_get(raw_url string, timeout time.Duration, controllers ...&Control) !WireResponse {
	if cancelled() { return error_with_code('context canceled', 20003) }
	if timeout <= 0 { return error('HTTP timeout must be positive') }
	control := if controllers.len > 0 { controllers[0] } else { unsafe { nil } }
	deadline := wall_deadline_after(time.now(), timeout)
	mut current := raw_url
	for redirects in 0 .. 10 {
		response := transport_once(current, deadline, control)!
		if response.status !in [301, 302, 303, 307, 308] || response.headers['location'] == '' {
			return response
		}
		if redirects == 9 { return error('stopped after 10 redirects') }
		base := wire_url(current)!
		location := base.parse(response.headers['location'])!
		current = location.str()
	}
	return error('stopped after 10 redirects')
}

fn transport_once(raw_url string, deadline time.Time, control &Control) !WireResponse {
	wire_check(deadline)!
	pooling := control != unsafe { nil } && control.cfg.reuse_connections
	u := wire_url(raw_url)!
	port := if u.port() != '' {
		u.port()
	} else if u.scheme == 'https' {
		'443'
	} else {
		'80'
	}
	authority := urllib.join_host_port(u.hostname(), port)
	mut endpoint := authority
	mut proxy_auth := ''
	mut proxy := wire_env(if u.scheme == 'https' { 'HTTPS_PROXY' } else { 'HTTP_PROXY' }, if u.scheme == 'https' {
		'https_proxy'
	} else {
		'http_proxy'
	})
	if wire_no_proxy(u.hostname(), port, wire_env('NO_PROXY', 'no_proxy')) { proxy = '' }
	if proxy != '' {
		p := urllib.parse(proxy)!
		if p.scheme != 'http' || p.hostname() == '' || p.path !in ['', '/'] || p.raw_query != '' || p.fragment != '' {
			return error('only HTTP proxy URLs are supported')
		}
		proxy_port := if p.port() == '' { '80' } else { p.port() }
		if wire_number(proxy_port, 10, 65535)! == 0 { return error('invalid HTTP proxy port') }
		endpoint = urllib.join_host_port(p.hostname(), proxy_port)
		if user := p.user {
			if user.username != '' || user.password != '' || user.password_set {
				proxy_auth = 'Proxy-Authorization: Basic ' + base64.encode_str(user.username + ':' + user.password) + '\r\n'
			}
		}
	}
	key := if pooling {
		wire_pool_key(u.scheme, authority, proxy, os.getenv('SSL_CERT_FILE') + '\x00' + os.getenv('SSL_CERT_DIR'))
	} else {
		''
	}
	mut stream := &WireStream(unsafe { nil })
	if pooling {
		mut c := unsafe { control }
		stream = c.take_idle(key) or { unsafe { nil } }
	}
	reused := stream != unsafe { nil }
	if !reused {
		// The synchronous resolver/dial cannot be interrupted. Check immediately
		// afterward; all subsequent I/O remains deadline/cancellation bounded.
		tcp := net.dial_tcp(endpoint) or {
			wire_check(deadline)!
			return err
		}
		stream = &WireStream{ tcp: tcp, deadline: deadline }
	}
	stream.deadline = deadline
	mut tcp := stream.tcp
	done := chan bool{cap: 1}
	watch := spawn wire_watch(tcp.sock.handle, deadline, done)
	mut reusable := false
	defer {
		done <- true
		watch.wait()
		// No watchdog may retain a descriptor after its stream enters the pool.
		if reusable && !cancelled() && time.now() < deadline && pooling {
			mut c := unsafe { control }
			c.put_idle(key, mut stream)
		} else {
			stream.close()
		}
	}
	tcp.set_read_deadline(deadline)
	tcp.set_write_deadline(deadline)
	stream.check()!
	if !reused {
		if proxy != '' && u.scheme == 'https' {
			stream.write('CONNECT ${authority} HTTP/1.1\r\nHost: ${authority}\r\n${proxy_auth}Proxy-Connection: Keep-Alive\r\n\r\n')!
			tunnel := stream.headers()!
			if tunnel.status != 200 { return error('HTTP proxy CONNECT failed (${tunnel.status})') }
			if stream.pos != stream.end { return error('unexpected data after HTTP proxy CONNECT') }
		}
		if u.scheme == 'https' {
			stream.tls = ssl.new_ssl_conn(
				validate:       true
				verify:         os.getenv('SSL_CERT_FILE')
				alpn_protocols: ['http/1.1']
			)!
			tcp.set_read_timeout(wire_remaining_timeout(deadline))
			stream.connect_tls(u.hostname()) or {
				return wire_io_error(stream.deadline, err)
			}
			stream.secure = true
			stream.check()!
		}
	}
	mut target := u.request_uri()
	if proxy != '' && u.scheme == 'http' { target = '${u.scheme}://${u.host}${target}' }
	for c in target { if c <= 32 || c == 127 { return error('invalid HTTP request target') } }
	auth := if proxy != '' && u.scheme == 'http' { proxy_auth } else { '' }
	connection := if pooling { 'keep-alive' } else { 'close' }
	request := 'GET ${target} HTTP/1.1\r\nHost: ${u.host}\r\nUser-Agent: v-nico-list\r\nAccept: */*\r\nAccept-Encoding: gzip\r\nX-Frontend-Id: 6\r\nConnection: ${connection}\r\n${auth}\r\n'
	if control != unsafe { nil } {
		mut c := unsafe { control }
		c.write_http(mut stream, request)!
	} else {
		stream.write(request)!
	}
	response := stream.headers()!
	// Retry and terminal error status bodies are irrelevant to API decoding.
	if response.status != 200 { return response }
	encoding := response.headers['content-encoding'].trim(' \t').to_lower()
	if encoding !in ['', 'identity', 'gzip'] {
		return BodyError{ message: 'unsupported HTTP content encoding' }
	}
	maximum := if encoding == 'gzip' { wire_encoded_limit } else { wire_body_limit }
	mut encoded := stream.body(response.headers, maximum) or {
		stream.check()!
		if err.code() in [20002, 20003] { return err }
		return BodyError{ message: err.msg() }
	}
	mut body := encoded
	if encoding == 'gzip' {
		mut state := WireInflate{ deadline: deadline }
		mut decode_error := ''
		gzip.decompress_with_callback(encoded, wire_inflate_chunk, &state) or { decode_error = err.msg() }
		if state.interrupted {
			stream.check()!
			return error('HTTP gzip decoding interrupted')
		}
		if state.excess { return BodyError{ message: 'response body exceeds 8 MiB limit' } }
		if decode_error != '' { return BodyError{ message: decode_error } }
		body = state.body
	}
	stream.check()!
	reusable = wire_reusable(response) && stream.pos == stream.end && !stream.buffered_tls_data()
	return WireResponse{ status: response.status, headers: response.headers, body: body, version: response.version }
}
