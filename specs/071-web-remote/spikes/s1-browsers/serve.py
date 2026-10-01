#!/usr/bin/env python3
"""Serve the S1 spike page on loopback, under the web remote's CSP (071 T001).

    python3 serve.py [port]      # default 8893; open http://localhost:<port>/

Only index.html, spike.js and vectors.json (from Web/test/) are served.
"""
import http.server, pathlib, sys

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[3]
FILES = {
    "/": (HERE / "index.html", "text/html; charset=utf-8"),
    "/index.html": (HERE / "index.html", "text/html; charset=utf-8"),
    "/spike.js": (HERE / "spike.js", "text/javascript; charset=utf-8"),
    "/vectors.json": (ROOT / "Web/test/vectors.json", "application/json"),
}
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' blob: data:; "
       "connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'; "
       "frame-src 'none'; object-src 'none'; worker-src 'none'; manifest-src 'none'; "
       "require-trusted-types-for 'script'; trusted-types 'none'")

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        entry = FILES.get(self.path.split("?")[0])
        body, kind, status = (entry[0].read_bytes(), entry[1], 200) if entry else (b"", "text/plain", 404)
        self.send_response(status)
        for name, value in [("Content-Type", kind), ("Content-Security-Policy", CSP),
                            ("X-Content-Type-Options", "nosniff"), ("Referrer-Policy", "no-referrer"),
                            ("Cross-Origin-Opener-Policy", "same-origin"),
                            ("Cross-Origin-Resource-Policy", "same-origin"),
                            ("Cache-Control", "no-cache"), ("Content-Length", str(len(body)))]:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, fmt, *args):
        sys.stderr.write("spike %s %s\n" % (self.command, self.path))

port = int(sys.argv[1]) if len(sys.argv) > 1 else 8893
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
