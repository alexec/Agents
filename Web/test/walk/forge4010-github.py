#!/usr/bin/env python3
"""A fixture GitHub for images on a Work page (#4010): forge3268-github.py's example/shop, plus issue
#50, whose body and comment hold images on avatars.githubusercontent.com (public organisations'
pictures, which forge/image reads with no token, so a scratch connection's fake one does), one as
Markdown and one as GitHub's <img>, and one on a host forge/image refuses, which is drawn as its
alternative text. Scratch data only. Point a run-app host at it with
--env AGENTS_TEST_GITHUB_URL=http://127.0.0.1:<port>.

    python3 Web/test/walk/forge4010-github.py <port>
"""
import importlib.util
import os
import sys
from http.server import ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("forge3268", os.path.join(os.path.dirname(__file__), "forge3268-github.py"))
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)
ITEMS = base.ITEMS
AVATARS = "https://avatars.githubusercontent.com/u"

ITEMS[50] = {
    "title": "The receipt page cuts off the total", "state": "OPEN", "labels": ["story", "feature:checkout"],
    "body": "On a narrow window the total is cut off at the right:\n\n"
            f"![The shop's logo, cut off]({AVATARS}/9919?s=640&v=4)\n\n"
            "It should wrap, as the line items do.\n\n"
            '<img alt="From another site" src="https://example.com/receipt.png">',
}
COMMENTS = {
    50: [{"author": {"login": "sam", "__typename": "User"}, "createdAt": "2026-11-02T17:00:00Z",
          "url": f"https://github.com/{base.REPO}/issues/50#issuecomment-1",
          "body": f'The same on the phone:\n\n<img width="320" alt="The logo on the phone" src="{AVATARS}/44036562?s=320&v=4">'}],
}


class Handler(base.Handler):
    def answer(self, code, body):
        got = (body.get("data") or {}).get("repository", {}).get("issueOrPullRequest") if isinstance(body, dict) else None
        if got and got.get("number") in COMMENTS:
            got["comments"]["nodes"] = COMMENTS[got["number"]]
        super().answer(code, body)


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
