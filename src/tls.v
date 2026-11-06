module main

import net
import time
import io

$if !use_openssl ? {
	#include "@VMODROOT/src/native_tls.h"
	fn C.nico_tls_connect(context voidptr, io voidptr, hostname &u8, send_callback fn (voidptr, &u8, uint) i32, recv_callback fn (voidptr, &u8, uint) i32) i32
}

// A local socket shutdown need not wake a Windows select already in progress.
// Bound each wait so cancellation is observed without closing a socket that its
// owning thread may still be using, or retrying a failed TLS context.
fn wire_tcp_read(mut tcp net.TcpConn, deadline time.Time, buffer &u8, length int) !int {
	for {
		wire_check(deadline)!
		poll := wall_deadline_after(time.now(), 20 * time.millisecond)
		tcp.set_read_deadline(if poll < deadline { poll } else { deadline })
		n := tcp.read_ptr(buffer, length) or {
			wire_check(deadline)!
			if err.code() == net.err_timed_out.code() { continue }
			if err is io.Eof { return 0 }
			return err
		}
		wire_check(deadline)!
		return n
	}
}

$if !use_openssl ? {
	fn wire_tls_receive(context voidptr, buffer &u8, length uint) i32 {
		mut stream := unsafe { &WireStream(context) }
		count := wire_tcp_read(mut stream.tcp, stream.deadline, buffer, int(length)) or {
			return i32(C.MBEDTLS_ERR_NET_RECV_FAILED)
		}
		return i32(count)
	}

	fn wire_tls_send(context voidptr, buffer &u8, length uint) i32 {
		mut stream := unsafe { &WireStream(context) }
		wire_check(stream.deadline) or { return i32(C.MBEDTLS_ERR_NET_SEND_FAILED) }
		count := stream.tcp.write_ptr(buffer, int(length)) or {
			return i32(C.MBEDTLS_ERR_NET_SEND_FAILED)
		}
		return i32(count)
	}
}

fn (mut stream WireStream) connect_tls(hostname string) ! {
	$if use_openssl ? {
		stream.tls.connect(mut stream.tcp, hostname)!
	} $else {
		stream.tls.handle = stream.tcp.sock.handle
		stream.tls.server_fd.fd = stream.tcp.sock.handle
		stream.tls.set_read_timeout(wire_remaining_timeout(stream.deadline))
		result := C.nico_tls_connect(&stream.tls.ssl, &stream, hostname.str,
			wire_tls_send, wire_tls_receive)
		if result != 0 {
			// transport_once's owner defer releases context and borrowed socket.
			stream.check()!
			return error_with_code('TLS handshake failed (${result})', result)
		}
		stream.tls.opened = true
	}
}
