#!/usr/bin/env python3
"""Loopback-only immutable artifacts for the native download integrity test."""
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import sys


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        body = {"/good": b"abc", "/tampered": b"xyz", "/truncated": b"ab"}.get(self.path, b"abc")
        self.send_response(503 if self.path == "/failed" else 200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


server = HTTPServer(("127.0.0.1", 0), Fixture)
Path(sys.argv[1]).write_text(str(server.server_port))
server.serve_forever()
