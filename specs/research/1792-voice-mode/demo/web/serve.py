#!/usr/bin/env python3
"""Serves the #1792 web page on loopback and writes what it measured to result.json.

    serve.py FOLDER PORT [HOST]   (FOLDER holds index.html and phonemes.json)

HOST is 127.0.0.1 unless given; 0.0.0.0 lets a phone on the same network open it.
"""
import http.server
import os
import sys

folder, port = sys.argv[1], int(sys.argv[2])
host = sys.argv[3] if len(sys.argv) > 3 else "127.0.0.1"


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=folder, **kwargs)

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(os.path.join(folder, "result.json"), "wb") as f:
            f.write(body)
        self.send_response(204)
        self.end_headers()


http.server.ThreadingHTTPServer((host, port), Handler).serve_forever()
