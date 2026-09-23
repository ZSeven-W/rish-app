#!/usr/bin/env python3
"""A counting HTTP CONNECT proxy for the Git proxy acceptance tests.

Standard library only; nothing is installed. It tunnels CONNECT host:port to
the real host and counts every tunnel, so a test can prove its traffic went
*through* the proxy rather than merely succeeding. Two control requests, sent
to the proxy itself as plain HTTP:

  GET  /__rish_stats            {"connects": {"github.com:443": 2}, "upstream_failed": {}, "refused": 0, "mode": "tunnel"}
  POST /__rish_mode?mode=refuse CONNECT answers 403 from now on (mode=tunnel restores)
  POST /__rish_reset            counters to zero

Usage:
  git-test-proxy.py --port 18734 [--bind 127.0.0.1]

The Android emulator reaches it at http://10.0.2.2:PORT/, the iOS simulator
at http://127.0.0.1:PORT/. Bind to loopback only: it is an open proxy.
"""

import argparse
import asyncio
import json
import sys
from urllib.parse import parse_qs, urlparse

STATE = {"connects": {}, "upstream_failed": {}, "refused": 0, "mode": "tunnel"}


async def pipe(reader, writer):
    try:
        while True:
            data = await reader.read(65536)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def respond(writer, status, body=b"", content_type="application/json"):
    head = f"HTTP/1.1 {status}\r\nContent-Type: {content_type}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n\r\n"
    writer.write(head.encode() + body)
    await writer.drain()
    writer.close()


async def handle(reader, writer):
    try:
        request = await reader.readuntil(b"\r\n\r\n")
    except (asyncio.IncompleteReadError, asyncio.LimitOverrunError, ConnectionError):
        writer.close()
        return
    line = request.split(b"\r\n", 1)[0].decode("latin-1")
    parts = line.split(" ")
    if len(parts) != 3:
        await respond(writer, "400 Bad Request")
        return
    method, target, _ = parts
    if method == "CONNECT":
        if STATE["mode"] == "refuse":
            STATE["refused"] += 1
            await respond(writer, "403 Forbidden", b"refused by test proxy", "text/plain")
            return
        host, _, port = target.rpartition(":")
        try:
            upstream_reader, upstream_writer = await asyncio.wait_for(
                asyncio.open_connection(host.strip("[]"), int(port)), timeout=60)
        except Exception as error:  # noqa: BLE001 - reported to the client
            # Counted apart: a tunnel that never opened carried nothing, and
            # a test counting it as traffic would prove less than it claims.
            STATE["upstream_failed"][target] = STATE["upstream_failed"].get(target, 0) + 1
            await respond(writer, "502 Bad Gateway", str(error).encode(), "text/plain")
            return
        STATE["connects"][target] = STATE["connects"].get(target, 0) + 1
        writer.write(b"HTTP/1.1 200 Connection Established\r\n\r\n")
        await writer.drain()
        await asyncio.gather(pipe(reader, upstream_writer), pipe(upstream_reader, writer))
        return
    url = urlparse(target)
    if url.path == "/__rish_stats" and method == "GET":
        await respond(writer, "200 OK", json.dumps(STATE).encode())
    elif url.path == "/__rish_mode" and method == "POST":
        mode = parse_qs(url.query).get("mode", ["tunnel"])[0]
        STATE["mode"] = "refuse" if mode == "refuse" else "tunnel"
        await respond(writer, "200 OK", json.dumps(STATE).encode())
    elif url.path == "/__rish_reset" and method == "POST":
        STATE["connects"] = {}
        STATE["upstream_failed"] = {}
        STATE["refused"] = 0
        await respond(writer, "200 OK", json.dumps(STATE).encode())
    else:
        # Plain-HTTP forwarding is deliberately absent: the app only sends
        # HTTPS remotes through a proxy.
        await respond(writer, "405 Method Not Allowed", b"CONNECT only", "text/plain")


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--bind", default="127.0.0.1")
    args = parser.parse_args()
    server = await asyncio.start_server(handle, args.bind, args.port)
    print(f"git-test-proxy listening on {args.bind}:{args.port}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
