#!/usr/bin/env python3
"""A sign-up code or link from the agents' mailbox, by the email MCP server (#3912).

  scripts/mail-code.py start --from '*@gitlab.com'          before the form sends the mail
  scripts/mail-code.py code  --from '*@gitlab.com'          the code, once the mail comes
  scripts/mail-code.py link  --from '*@digitalocean.com' --host '*.digitalocean.com'

It runs email-mcp (Agents carries it) over stdio and waits on its event email.received,
which watches INBOX and the Junk folder, so a code the server took for spam still comes
and Mail need not run. `start` keeps the event's cursor in ~/.agents/tmp/mail-code/
(mode 600); `code` and `link` wait from there (10 minutes at most, --timeout), read the
first matching mail with read_message, mark it read, and print only the code or the link.
Put it into a page with a script or browser_type; never into an issue, a commit or a log.
Never the mail's text: it is outside content.

Only mail whose sender the mail server authenticated (DMARC or aligned DKIM) counts;
--unauthenticated drops that. --subject narrows by subject (a glob). The mailbox is
EMAIL_IMAP_URL, EMAIL_USER and EMAIL_PASSWORD (from `agents-secret EMAIL_PASSWORD` when
unset); by default agentloops@fastmail.com on imaps://imap.fastmail.com (#1780).
EMAIL_MCP names the server when it is not on PATH or in Agent Loops.app (or Agents.app).
"""

import argparse
import base64
import fnmatch
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.parse

STATE = os.path.expanduser("~/.agents/tmp/mail-code")
APPS = ("~/Applications/Agent Loops.app", "/Applications/Agent Loops.app",
        "~/Applications/Agents.app", "/Applications/Agents.app")
# A one-time code: 4 to 12 letters, digits or dashes with a digit in it, after a word that
# says it is one. The workflow's skill (answer-a-sign-up-code) takes the same shape.
KEYWORDS = re.compile(r"code|verif|confirm|one-time|passcode|\bpin\b|sign[- ]?in|security", re.I)
CODE = re.compile(r"(?<![A-Za-z0-9-])(?=[A-Za-z0-9-]*\d)[A-Za-z0-9][A-Za-z0-9-]{2,10}[A-Za-z0-9](?![A-Za-z0-9-])")
LINK = re.compile(r"https://[^\s<>\"')\]]+")


def fail(message):
    print(f"mail-code: {message}", file=sys.stderr)
    sys.exit(1)


def server_path():
    if os.environ.get("EMAIL_MCP"):
        return os.environ["EMAIL_MCP"]
    found = shutil.which("email-mcp")
    if found:
        return found
    for app in APPS:
        path = os.path.join(os.path.expanduser(app), "Contents", "Helpers", "email-mcp")
        if os.access(path, os.X_OK):
            return path
    fail("no email-mcp: install Agents, or set EMAIL_MCP")


def environment():
    env = dict(os.environ)
    env.setdefault("EMAIL_IMAP_URL", "imaps://imap.fastmail.com")
    env.setdefault("EMAIL_USER", "agentloops@fastmail.com")
    if not env.get("EMAIL_PASSWORD"):
        try:
            env["EMAIL_PASSWORD"] = subprocess.run(["agents-secret", "EMAIL_PASSWORD"], capture_output=True,
                                                   text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            fail("no EMAIL_PASSWORD: set it, or keep it in Settings ▸ Secrets for agents-secret")
    return env


class Server:
    """email-mcp over stdio: one JSON-RPC message a line."""

    def __init__(self):
        self.proc = subprocess.Popen([server_path()], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, text=True, env=environment())
        self.next_id = 0
        self.call("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "mail-code", "version": "1"}})
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def send(self, message):
        self.proc.stdin.write(json.dumps(message) + "\n")
        self.proc.stdin.flush()

    def call(self, method, params):
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        for line in self.proc.stdout:
            message = json.loads(line)
            if message.get("id") != self.next_id:
                continue  # a notification
            if "error" in message:
                fail(message["error"].get("message", "the email server refused"))
            return message["result"]
        fail("the email server stopped")

    def tool(self, name, arguments):
        result = self.call("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError"):
            fail(f"{name} failed")
        return result.get("structuredContent") or {}

    def close(self):
        self.proc.stdin.close()
        self.proc.wait(timeout=10)


def event_arguments(args):
    out = {"from": args.sender}
    if args.subject:
        out["subject"] = args.subject
    if not args.unauthenticated:
        out["authenticated"] = "true"
    return out


def state_file(args):
    key = hashlib.sha256(json.dumps(event_arguments(args), sort_keys=True).encode()).hexdigest()[:16]
    return os.path.join(STATE, key + ".json")


def start(args):
    server = Server()
    answer = server.call("events/poll", {"name": "email.received", "arguments": event_arguments(args)})
    server.close()
    os.makedirs(STATE, mode=0o700, exist_ok=True)
    path = state_file(args)
    with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as f:
        json.dump({"cursor": answer["cursor"]}, f)
    print(f"mail-code: watching {watched(answer['cursor'])} for mail from {args.sender}", file=sys.stderr)


def watched(cursor):
    """The folder names in a cursor (base64url of JSON), for the words only."""
    try:
        raw = json.loads(base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4)))
        return " and ".join(p["folder"] for p in raw["places"])
    except (ValueError, KeyError, TypeError):
        return "the mailbox"


def wait(args):
    path = state_file(args)
    try:
        with open(path) as f:
            cursor = json.load(f)["cursor"]
    except (OSError, ValueError, KeyError):
        fail(f"run `scripts/mail-code.py start --from '{args.sender}'` first, before the mail is sent")
    server = Server()
    deadline = time.monotonic() + args.timeout
    while True:
        answer = server.call("events/poll", {"name": "email.received", "arguments": event_arguments(args),
                                             "cursor": cursor})
        cursor = answer["cursor"]
        for event in answer.get("events", []):
            message = server.tool("read_message", {"id": event["data"]["id"]})
            text = (message.get("body") or {}).get("text", "")
            found = find_code(text) if args.what == "code" else find_link(text, args.host)
            if found:
                server.tool("mark_read", {"id": event["data"]["id"]})
                server.close()
                os.remove(path)
                print(found)
                return
        if time.monotonic() > deadline:
            server.close()
            with open(path, "w") as f:
                json.dump({"cursor": cursor}, f)
            fail(f"no {args.what} from {args.sender} in {args.timeout}s")
        if not answer.get("hasMore"):
            time.sleep(min(answer.get("nextPollMs", 10000), 10000) / 1000)


def find_code(text):
    for line in text.splitlines():
        if not KEYWORDS.search(line):
            continue
        # The code is on the line that names it, or alone on one of the next lines.
        for match in CODE.finditer(line[KEYWORDS.search(line).end():]):
            return match.group(0)
    lines = [line.strip() for line in text.splitlines()]
    for i, line in enumerate(lines):
        if KEYWORDS.search(line):
            for after in lines[i + 1:i + 4]:
                if CODE.fullmatch(after):
                    return after
    return None


def find_link(text, host):
    for match in LINK.finditer(text):
        link = match.group(0).rstrip(".,;")
        name = urllib.parse.urlsplit(link).hostname or ""
        if fnmatch.fnmatchcase(name.lower(), host.lower()):
            return link
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("what", choices=("start", "code", "link"))
    parser.add_argument("--from", dest="sender", required=True, help="the sender's address, a glob: *@gitlab.com")
    parser.add_argument("--subject", help="the whole subject, a glob: *verification*")
    parser.add_argument("--host", help="link: the link's host, a glob: *.digitalocean.com")
    parser.add_argument("--timeout", type=int, default=600, help="seconds to wait (600)")
    parser.add_argument("--unauthenticated", action="store_true", help="take mail the server did not authenticate")
    args = parser.parse_args()
    if args.what == "link" and not args.host:
        parser.error("link needs --host")
    if args.what == "start":
        start(args)
    else:
        wait(args)


if __name__ == "__main__":
    main()
