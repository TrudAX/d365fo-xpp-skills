#!/usr/bin/env python3
"""Local token-refresh proxy for the Dynamics 365 ERP MCP server.

    Claude Code  ->  http://127.0.0.1:<port>/mcp     (no auth)
       proxy     ->  <upstream>/mcp  with a fresh app-only Bearer token

The proxy holds the Entra client-credentials app registration, mints and
refreshes the token (v1 endpoint, `resource` param, to match the token that
was verified against /mcp), and injects it on every forwarded request.
Server-Sent-Events responses are streamed through unbuffered.

Config is read from config.json next to this file. Bind is 127.0.0.1 only.
"""
import json, os, sys, threading, time
import urllib.request, urllib.parse, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

CFG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.json")
with open(CFG_PATH, "r", encoding="utf-8") as fh:
    CFG = json.load(fh)

TENANT        = CFG["tenant"]
CLIENT_ID     = CFG["client_id"]
# Secret comes from the environment (never stored on disk); config.json fallback optional.
CLIENT_SECRET = os.environ.get("D365MCP_CLIENT_SECRET") or CFG.get("client_secret")
if not CLIENT_SECRET:
    sys.stderr.write("[proxy] ERROR: set the D365MCP_CLIENT_SECRET environment variable "
                     "before launching.\n")
    sys.exit(2)
RESOURCE      = CFG["resource"].rstrip("/")           # https://...dynamics.com
UPSTREAM      = CFG["upstream"].rstrip("/")           # https://...dynamics.com/mcp
LISTEN_HOST   = CFG.get("listen_host", "127.0.0.1")
LISTEN_PORT   = int(CFG.get("listen_port", 8899))
UP_BASE       = UPSTREAM[:-4] if UPSTREAM.endswith("/mcp") else UPSTREAM
TOKEN_URL     = "https://login.microsoftonline.com/%s/oauth2/token" % TENANT  # v1 + resource

_lock = threading.Lock()
_tok  = {"value": None, "exp": 0.0}

def get_token():
    with _lock:
        now = time.time()
        if _tok["value"] and now < _tok["exp"] - 120:
            return _tok["value"]
        data = urllib.parse.urlencode({
            "grant_type":    "client_credentials",
            "client_id":     CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "resource":      RESOURCE,
        }).encode()
        req = urllib.request.Request(TOKEN_URL, data=data, method="POST")
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
        with urllib.request.urlopen(req, timeout=30) as r:
            j = json.loads(r.read().decode())
        _tok["value"] = j["access_token"]
        _tok["exp"]   = now + int(j.get("expires_in", 3600))
        sys.stderr.write("[proxy] token refreshed (expires_in=%s)\n" % j.get("expires_in"))
        sys.stderr.flush()
        return _tok["value"]

HOP = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
       "te", "trailers", "transfer-encoding", "upgrade", "content-length", "host"}
FWD_REQ = {"content-type", "accept", "mcp-session-id", "mcp-protocol-version",
           "client-request-id", "last-event-id"}

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("[proxy] " + (fmt % args) + "\n"); sys.stderr.flush()

    def do_OPTIONS(self):
        self.send_response(204)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
        self.send_header("Access-Control-Allow-Headers",
                         "authorization, content-type, mcp-session-id, mcp-protocol-version, client-request-id")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):    self._proxy()
    def do_POST(self):   self._proxy()
    def do_DELETE(self): self._proxy()

    def _proxy(self):
        length = int(self.headers.get("Content-Length", 0) or 0)
        body = self.rfile.read(length) if length else None
        try:
            token = get_token()
        except Exception as e:
            self.send_error(502, "token error: %s" % e); return

        url = UP_BASE + self.path
        req = urllib.request.Request(url, data=body, method=self.command)
        for k, v in self.headers.items():
            if k.lower() in FWD_REQ:
                req.add_header(k, v)
        req.add_header("Authorization", "Bearer " + token)

        try:
            resp = urllib.request.urlopen(req, timeout=300)
        except urllib.error.HTTPError as e:
            resp = e                       # forward upstream 4xx/5xx as-is
        except Exception as e:
            self.send_error(502, "upstream error: %s" % e); return

        status  = getattr(resp, "status", None) or resp.getcode()
        headers = resp.headers
        stream  = "text/event-stream" in (headers.get("Content-Type", "").lower())

        if stream:
            self.send_response(status)
            for k, v in headers.items():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                while True:
                    line = resp.readline()
                    if not line:
                        break
                    self.wfile.write(("%X\r\n" % len(line)).encode() + line + b"\r\n")
                    self.wfile.flush()
                self.wfile.write(b"0\r\n\r\n"); self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        else:
            data = resp.read()
            self.send_response(status)
            for k, v in headers.items():
                if k.lower() not in HOP:
                    self.send_header(k, v)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

def main():
    srv = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    sys.stderr.write("[proxy] listening on http://%s:%d/mcp  ->  %s\n"
                     % (LISTEN_HOST, LISTEN_PORT, UPSTREAM))
    sys.stderr.flush()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()

if __name__ == "__main__":
    main()
