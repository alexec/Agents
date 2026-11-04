#!/usr/bin/env python3
"""A fixture GitHub for the Docs section on Work's pages (#3322): forge3268-github.py's example/shop,
with issue #50, whose body names a spec of the repo by its path, and an issue that names none.
Scratch data only. Point a run-app host at it with --env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>,
and give its folder the origin https://github.com/example/shop.

    python3 Web/test/walk/forge3322-github.py <port>
"""
import importlib.util
import os
import sys
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("forge3268", os.path.join(os.path.dirname(__file__), "forge3268-github.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

base.ITEMS.clear()
base.ITEMS.update({
    50: {"title": "Refund a gift card payment", "state": "OPEN", "labels": ["story", "feature:checkout"],
         "body": "A refund puts the money back on the gift card it came from.\n\n"
                 "Spec: `specs/gift-cards/spec.md`, \"Refunds\"."},
    51: {"title": "Checkout shows the gift card balance", "state": "OPEN", "labels": ["story"],
         "body": "After paying, the page says what is left on the card."},
})

if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), base.Handler).serve_forever()
