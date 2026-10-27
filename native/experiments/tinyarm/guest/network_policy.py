"""Host-owned, deny-by-default HTTPS broker for the simulator research guest."""

import base64
import hashlib
import http.client
import ipaddress
import json
import os
import socket
import ssl
import time
from urllib.parse import urlsplit


RESPONSE_LIMIT = 8 * 1024 * 1024
SESSION_LIMIT = 16 * 1024 * 1024


class NetworkPolicy:
    def __init__(self, repositories=(), downloads=None, record_to=None):
        self.repositories = tuple(repositories)
        self.downloads = dict(downloads or {})  # exact URL -> SHA256
        self.requests = 0
        self.bytes = 0
        self.audit = []
        self.record_to = record_to
        if record_to is not None:
            record_to.mkdir(mode=0o700, parents=True, exist_ok=True)

    def authorize(self, request):
        url, method = request.get("url"), request.get("method")
        if not isinstance(url, str) or len(url) > 2048:
            raise ValueError("Invalid URL")
        parsed = urlsplit(url)
        if (parsed.scheme != "https" or not parsed.hostname or parsed.username is not None
                or parsed.password is not None or parsed.port not in (None, 443)
                or parsed.fragment or any(ord(c) <= 32 or ord(c) == 127 for c in url)):
            raise ValueError("Only credential-free HTTPS on port 443 is permitted")
        allowed = method == "GET" and url in self.downloads
        for repository in self.repositories:
            allowed |= (method == "GET" and url == repository + "/info/refs?service=git-upload-pack")
            allowed |= (method == "POST" and url == repository + "/git-upload-pack")
        if not allowed:
            raise ValueError("Destination or operation is not approved for this session")
        body = base64.b64decode(request.get("body", ""), validate=True)
        if len(body) > 64 * 1024 or (method == "GET" and body):
            raise ValueError("Request body exceeds policy")
        if self.bytes >= SESSION_LIMIT:
            raise ValueError("Session network budget exhausted")
        return parsed, body

    def fetch(self, request):
        parsed, body = self.authorize(request)
        deadline = time.monotonic() + 30
        # Reject every private/loopback/link-local answer, then connect to the
        # checked address rather than resolving again (DNS rebinding).
        addresses = socket.getaddrinfo(parsed.hostname, 443, type=socket.SOCK_STREAM)
        if not addresses or any(not ipaddress.ip_address(a[4][0]).is_global
                                or ipaddress.ip_address(a[4][0]).is_multicast for a in addresses):
            raise ValueError("Non-public destination address denied")
        address = addresses[0][4][0]
        connection = http.client.HTTPSConnection(parsed.hostname, timeout=15)
        try:
            raw = socket.create_connection((address, 443), timeout=15)
            try:
                connection.sock = ssl.create_default_context().wrap_socket(raw, server_hostname=parsed.hostname)
            except Exception:
                raw.close()
                raise
            headers = {"User-Agent": "Habibi-TinyARM-Lab", "Accept-Encoding": "identity"}
            if request.get("gitProtocol") == "version=2":
                headers["Git-Protocol"] = "version=2"
            if request["method"] == "POST":
                headers["Content-Type"] = "application/x-git-upload-pack-request"
            path = parsed.path + ("?" + parsed.query if parsed.query else "")
            connection.request(request["method"], path, body=body, headers=headers)
            response = connection.getresponse()
            # No redirect following: even a public allowed URL cannot pivot to
            # localhost, metadata services, another repository or another host.
            if response.status != 200:
                raise ValueError("Upstream status %s denied; redirects are not followed" % response.status)
            limit = min(RESPONSE_LIMIT, SESSION_LIMIT - self.bytes)
            length = response.getheader("Content-Length")
            if length is not None and not 0 <= int(length) <= limit:
                raise ValueError("Response exceeds network budget")
            data = bytearray()
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise ValueError("Network deadline exceeded")
                connection.sock.settimeout(min(15, remaining))
                chunk = response.read1(min(65536, limit + 1 - len(data)))
                if not chunk:
                    break
                self.bytes += len(chunk)
                data.extend(chunk)
                if len(data) > limit:
                    raise ValueError("Response exceeds network budget")
            digest = self.downloads.get(request["url"])
            if digest is not None and hashlib.sha256(data).hexdigest() != digest:
                raise ValueError("Download SHA256 mismatch")
            return {"status": 200, "contentType": response.getheader("Content-Type", "application/octet-stream"),
                    "body": base64.b64encode(data).decode()}
        finally:
            connection.close()

    def handle(self, request):
        try:
            if self.requests >= 64:
                raise ValueError("Session network request budget exhausted")
            self.requests += 1
            result = {"ok": True, **self.fetch(request)}
        except Exception as error:
            result = {"ok": False, "error": str(error)[:300]}
        if len(self.audit) < 64:
            # Never record URL credentials or arbitrary query values. Bodies
            # are opt-in and may still contain sensitive source/page content.
            try:
                parsed = urlsplit(request.get("url", ""))
                url = parsed._replace(netloc=parsed.hostname or "", query="", fragment="").geturl()
            except ValueError:
                url = "invalid-url"
            entry = {"url": url, "method": request.get("method"), "ok": result["ok"],
                     "bytesSoFar": self.bytes,
                     **({"error": result["error"]} if not result["ok"] else {})}
            if self.record_to is not None:
                name = "%02d" % self.requests
                if result["ok"]:
                    entry.update(status=result["status"], contentType=result["contentType"])
                    for kind, data in (("request", base64.b64decode(request.get("body", ""))),
                                       ("response", base64.b64decode(result["body"]))):
                        filename = name + "-" + kind + ".bin"
                        with os.fdopen(os.open(self.record_to / filename, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as file:
                            file.write(data)
                        entry[kind] = {"file": filename, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
                with os.fdopen(os.open(self.record_to / (name + ".json"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as file:
                    json.dump(entry, file, indent=2)
            self.audit.append(entry)
        return result
