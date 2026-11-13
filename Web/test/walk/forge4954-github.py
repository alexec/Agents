#!/usr/bin/env python3
"""A fixture GitHub for the image viewer's sequence (#4954): forge4010-github.py's example/shop and
issue #50, plus issue #51, whose body holds three large images to go through, a small one (a logo
under 200 points) and a small one that is a link (a badge). The images are public organisations'
pictures on avatars.githubusercontent.com, which forge/image reads with no token. Scratch data only.
Point a run-app host at it with --env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>.

    python3 -I Web/test/walk/forge4954-github.py <port>
"""
import importlib.util
import os
import sys
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("forge4010", os.path.join(os.path.dirname(__file__), "forge4010-github.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
AVATARS = base.AVATARS

base.ITEMS[51] = {
    "title": "The receipt page on three widths", "state": "OPEN", "labels": ["story", "feature:checkout"],
    "body": f"[![CI](<{AVATARS}/44036562?s=40&v=4>)](https://github.com/{base.base.REPO}/actions) "
            f"![a small logo]({AVATARS}/9919?s=48&v=4)\n\n"
            "The receipt on a wide, a middle and a narrow window:\n\n"
            f"![Wide window]({AVATARS}/9919?s=640&v=4)\n\n"
            f"![Middle window]({AVATARS}/1342004?s=480&v=4)\n\n"
            f"![Narrow window]({AVATARS}/6154722?s=400&v=4)\n",
}

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), base.Handler).serve_forever()
