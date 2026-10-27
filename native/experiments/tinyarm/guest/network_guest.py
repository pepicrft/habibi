#!/usr/bin/env python3
"""Guest loopback HTTP adapter. All external traffic requires the host broker."""

import base64
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
from pathlib import Path
import sys


class Proxy(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.forward("GET")

    def do_POST(self):
        self.forward("POST")

    def forward(self, method):
        try:
            # /https/github.com/owner/repo.git -> https://github.com/owner/repo.git
            if not self.path.startswith("/https/") or self.headers.get("Transfer-Encoding"):
                raise ValueError("Only bounded HTTPS requests are supported")
            size = int(self.headers.get("Content-Length", "0"))
            if not 0 <= size <= 64 * 1024:
                raise ValueError("Request body exceeds 64KiB")
            request = {"event": "network", "url": "https://" + self.path[len("/https/"):],
                       "method": method, "body": base64.b64encode(self.rfile.read(size)).decode(),
                       "gitProtocol": self.headers.get("Git-Protocol", "")}
            sys.stdout.write(json.dumps(request) + "\n")
            sys.stdout.flush()
            line = sys.stdin.buffer.readline(12 * 1024 * 1024)
            if not line.endswith(b"\n"):
                raise ValueError("Host response exceeded transport budget")
            result = json.loads(line)
            if not result.get("ok"):
                raise ValueError(result.get("error", "Network denied"))
            data = base64.b64decode(result["body"], validate=True)
            self.send_response(200)
            self.send_header("Content-Type", result["contentType"])
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except Exception as error:
            self.send_error(403, str(error)[:300])


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", 8080), Proxy)
    Path("/run/network-ready").touch(mode=0o600)
    server.serve_forever()
