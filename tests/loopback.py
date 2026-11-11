"""Synthetic niconico fixture server; never contacts niconico or the Internet."""

from __future__ import annotations

import dataclasses
import gzip
import http.server
import json
import select
import socket
import socketserver
import ssl
import threading
import time
import urllib.parse
from collections import Counter
from typing import Callable


def video(identifier: str, comments: int = 1, date: str = "2026-01-01T00:00:00Z") -> dict:
    return {"id": identifier, "registeredAt": date, "count": {"comment": comments}}


def payload(kind: str, videos=(), total=None, total_key="totalCount") -> bytes:
    if kind == "user":
        data = {"items": [{"essential": item} for item in videos]}
        if total is not None:
            data[total_key] = total
    else:
        mylist = {"items": [{"video": item} for item in videos]}
        data = {"mylist": mylist}
        if total is not None:
            if total_key == "data.totalCount":
                data["totalCount"] = total
            else:
                mylist[total_key] = total
    return json.dumps({"meta": {"status": 200}, "data": data}, separators=(",", ":")).encode()


@dataclasses.dataclass
class Reply:
    body: bytes = b""
    status: int = 200
    headers: dict = dataclasses.field(default_factory=dict)
    delay: float = 0
    body_delay: float = 0
    chunked: bool = False
    compressed: bool = False
    close_after: bool = False


@dataclasses.dataclass
class Request:
    kind: str
    identifier: str
    page: int
    attempt: int
    started: float
    headers: dict
    path: str


class Fixture:
    def __init__(self, respond: Callable[[Request], Reply], tls_context=None):
        self.respond = respond
        self.records: list[Request] = []
        self.errors: list[str] = []
        self.lock = threading.Lock()
        self.attempts = Counter()
        self.active = 0
        self.peak = 0
        self.connections = 0
        self.active_targets = Counter()
        self.target_peaks = Counter()
        owner = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self):
                super().setup()
                with owner.lock:
                    owner.connections += 1
                # Avoid Nagle/delayed-ACK penalties when headers and small JSON
                # bodies are separate writes on reused Go HTTP connections.
                self.connection.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)

            def handle(self):
                try:
                    super().handle()
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass  # Expected close of an idle keep-alive connection.

            def log_message(self, *_):
                pass

            def do_GET(self):
                parsed = urllib.parse.urlsplit(self.path)
                parts = parsed.path.strip("/").split("/")
                valid_user = len(parts) == 4 and parts[0:2] == ["v3", "users"] and parts[3] == "videos"
                valid_mylist = len(parts) == 3 and parts[0:2] == ["v3", "mylists"]
                if not (valid_user or valid_mylist):
                    with owner.lock:
                        owner.errors.append("unexpected endpoint: " + self.path)
                    self.send_error(400)
                    return
                query = urllib.parse.parse_qs(parsed.query)
                if query.get("pageSize") != ["100"] or len(query.get("page", [])) != 1:
                    with owner.lock:
                        owner.errors.append("unexpected query: " + self.path)
                kind, identifier = ("user" if valid_user else "mylist"), parts[2]
                page = int(query.get("page", ["1"])[0])
                with owner.lock:
                    owner.attempts[kind, identifier, page] += 1
                    request = Request(kind, identifier, page, owner.attempts[kind, identifier, page],
                                      time.monotonic(), dict(self.headers), self.path)
                    owner.records.append(request)
                    owner.active += 1
                    owner.peak = max(owner.peak, owner.active)
                    owner.active_targets[kind, identifier] += 1
                    owner.target_peaks[kind, identifier] = max(owner.target_peaks[kind, identifier], owner.active_targets[kind, identifier])
                try:
                    reply = owner.respond(request)
                    time.sleep(reply.delay)
                    body = gzip.compress(reply.body) if reply.compressed else reply.body
                    self.send_response(reply.status)
                    self.send_header("Content-Type", "application/json")
                    if reply.compressed:
                        self.send_header("Content-Encoding", "gzip")
                    for name, value in reply.headers.items():
                        self.send_header(name, value)
                    if reply.chunked:
                        self.send_header("Transfer-Encoding", "chunked")
                    else:
                        self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    if reply.body_delay:
                        time.sleep(reply.body_delay)
                    if reply.chunked:
                        for offset in range(0, len(body), 16384):
                            chunk = body[offset:offset + 16384]
                            self.wfile.write(f"{len(chunk):x}\r\n".encode() + chunk + b"\r\n")
                        self.wfile.write(b"0\r\n\r\n")
                    else:
                        self.wfile.write(body)
                    self.wfile.flush()
                    if reply.close_after:
                        self.close_connection = True
                except (BrokenPipeError, ConnectionResetError, ssl.SSLError):
                    pass  # Expected when a client enforces a body limit or cancels.
                except Exception as exc:
                    with owner.lock:
                        owner.errors.append(repr(exc))
                finally:
                    with owner.lock:
                        owner.active -= 1
                        owner.active_targets[kind, identifier] -= 1

        class Server(http.server.ThreadingHTTPServer):
            request_queue_size = 128

        self.server = Server(("127.0.0.1", 0), Handler)
        self.server.daemon_threads = True
        self.server.block_on_close = False
        if tls_context:
            self.server.socket = tls_context.wrap_socket(self.server.socket, server_side=True)
        self.url = f"{'https' if tls_context else 'http'}://127.0.0.1:{self.server.server_port}/v3"
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)


def single_page(request: Request) -> Reply:
    return Reply(payload(request.kind, [video("sm" + request.identifier)] if request.page == 1 else []))


class TunnelProxy:
    """A CONNECT fixture restricted to one predetermined loopback destination."""

    def __init__(self, port):
        self.records = []
        owner = self

        class Handler(socketserver.StreamRequestHandler):
            def handle(self):
                self.connection.settimeout(5)
                line = self.rfile.readline(8192).decode("ascii").strip()
                headers = {}
                while True:
                    header = self.rfile.readline(8192)
                    if header == b"\r\n":
                        break
                    if not header:
                        return
                    name, value = header.decode("ascii").strip().split(":", 1)
                    headers[name.lower()] = value.strip()
                owner.records.append((line, headers))
                if line != f"CONNECT 127.0.0.1:{port} HTTP/1.1":
                    self.connection.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
                    return
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=5) as target:
                        self.connection.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
                        while True:
                            ready, _, _ = select.select([self.connection, target], [], [], 5)
                            if not ready:
                                return
                            for source in ready:
                                data = source.recv(65536)
                                if not data:
                                    return
                                (target if source is self.connection else self.connection).sendall(data)
                except (OSError, ssl.SSLError):
                    pass

        class Server(socketserver.ThreadingTCPServer):
            daemon_threads = True
            block_on_close = False

        self.server = Server(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
