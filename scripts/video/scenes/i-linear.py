"""I-Linear (#1794, the pilot of #1793): Linear on a real workspace. A personal API key made for
the video, Connect Linear in the window with the PKCE sign-in in the video Chrome, the Linear
issues page on the Mac and on the web page with Start Agent, and the ready-made workflow
**Work a Linear issue** starting an agent when a test issue gets the `agent` label.

After the take (make.py's revoke): the key is revoked on linear.app, the OAuth grant at
Linear's revoke endpoint, both must get 401, and the test issues are deleted.

Linear's pages are driven by what they say (`click` on a control's text) and by the token
patterns (`lin_api_…`), so a change to Linear's markup does not show a key: a pattern hides
every element whose text or value holds one, before it is drawn. The selectors on linear.app
were written before a take on it, and a take that cannot find a control stops and says which
(the page: ~/.cache/agents-video/web-failed.png, with every key on it hidden).

Needs: the video Chrome profile signed in to Linear (`scripts/video/make.sh --sign-in linear`,
#1793, What Alex does). AGENTS_VIDEO_LINEAR_TEAM picks the team by its key (the first team
otherwise).
"""
import json
import os
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

GROUP = "integration"
INTEGRATION = "linear"
TITLE = "Linear"
LAYOUT = "mac+browser"
BROWSER = (1280, 800)
# The bar is drawn once for the whole take, which shows linear.app and the scratch web page.
BROWSER_ADDRESS = "Chrome"
CHROME_PROFILE = "linear"
WINDOW = (1180, 740)

API = "https://api.linear.app/graphql"
KEY_NAME = f"agents-video-{time.strftime('%Y-%m-%d')}"
LABEL = "agent"
# Every place that shows a token, whatever element Linear puts it in.
KEY_PATTERN = r"lin_(api|oauth)_[A-Za-z0-9]{8,}"
# The new key, read in the page and handed to the scene over web.mjs's pipe, never printed.
FIND_KEY = """(() => {
  const re = new RegExp(%s);
  // The shortest match is the innermost element's: a parent's text runs on into its neighbours.
  const found = [...document.querySelectorAll("input, textarea, code, pre, span, div, p, td")]
    .map((el) => (el.value || el.textContent || "").match(re)?.[0]).filter(Boolean);
  return found.sort((a, b) => a.length - b.length)[0] ?? null;
})()""" % json.dumps(KEY_PATTERN)

LINES = {
    "intro": "Agents works with Linear. Here's a real workspace.",
    "key": "First, a personal API key, made only for this video, with read access. Its text stays hidden.",
    "connect": "In Agents, the project's Connectors page has Linear, under Tasks.",
    "approve": "Linear asks you to approve Agents. The sign-in uses PKCE, so there's no secret in the app.",
    "connected": "Agents is connected. The events server can use the connection, or the API key.",
    "page": "The Linear issues page lists the open issues, with Start Agent on each one.",
    "web": "The web page has the same page.",
    "start": "Start Agent opens a new agent for that issue.",
    "workflow": "The ready-made workflow Work a Linear issue starts an agent by itself.",
    "label": "Give an issue the agent label in Linear,",
    "started": "and an agent starts on it.",
    "end": "After the video, the key and the sign-in are revoked.",
}

TEST_ISSUES = [
    ("Video: tidy the README", "A test issue for the Agents video. It is deleted after the take."),
    ("Video: add a dark mode switch", "A test issue for the Agents video. It is deleted after the take."),
]


# --- Linear's API, with a token the scene holds (never printed) ---------------------------
def linear(token, query, variables=None, bearer=True):
    """(status, data or None). An error answer is summed up, never echoed: it can hold input."""
    request = urllib.request.Request(API, data=json.dumps({"query": query, "variables": variables or {}}).encode(),
                                     headers={"Content-Type": "application/json",
                                              "Authorization": f"Bearer {token}" if bearer else token})
    try:
        with urllib.request.urlopen(request, timeout=30) as answer:
            body = json.load(answer)
            return answer.status, body.get("data") if not body.get("errors") else None
    except urllib.error.HTTPError as error:
        return error.code, None


def refused(token, bearer):
    """True when Linear refuses the token: 401, or its GraphQL answer that says it is not
    authenticated (which Linear sends as 400)."""
    def ask():
        request = urllib.request.Request(API, data=b'{"query":"{ viewer { id } }"}', headers={
            "Content-Type": "application/json", "Authorization": f"Bearer {token}" if bearer else token})
        try:
            with urllib.request.urlopen(request, timeout=30):
                return False
        except urllib.error.HTTPError as error:
            if error.code == 401:
                return True
            try:
                kinds = [e.get("extensions", {}).get("type", "") for e in json.loads(error.read()).get("errors", [])]
            except Exception:
                return False
            return any("authentication" in k.lower() for k in kinds)
    return ask


def keychain_access(v):
    """The scratch host's Linear access token, from its own Keychain item (the service is the
    first four bytes of the root's SHA-256, connections.KeychainService). Read by `security`
    into this process, never printed."""
    import base64
    import hashlib
    roots = [v.root, os.path.realpath(v.root), f"{v.root}/host", os.path.realpath(f"{v.root}/host")]
    for root in dict.fromkeys(roots):
        service = "agents.connection." + hashlib.sha256(os.path.normpath(root).encode()).hexdigest()[:8]
        done = subprocess.run(["/usr/bin/security", "find-generic-password", "-s", service, "-a", "linear", "-w"],
                              capture_output=True, text=True)
        if done.returncode == 0:
            return json.loads(base64.b64decode(done.stdout.strip())).get("access")
    return None


# --- the set-up ----------------------------------------------------------------------------
def setup(v):
    folder = v.project("shop", {
        "README.md": "# Shop\n\nA small shop front.\n",
        ".agents/mcp.json": json.dumps({"mcpServers": {"linear": {"command": "linear-mcp", "hosted": True}}}, indent=2) + "\n",
        ".agents/pins.json": json.dumps({"pins": [{"pinned_by": {"person": True}, "title": "Linear issues",
                                                   "view": {"server": "linear", "tool": "show_issues",
                                                            "uri": "ui://linear/issues", "arguments": {}}}]}, indent=2) + "\n",
    })
    # A project that pushes to GitHub lists the ready-made workflows (#1342). Nothing is pushed:
    # the agent the workflow starts is stopped once it has started.
    subprocess.run(["git", "-C", str(folder), "remote", "add", "origin", "https://github.com/example/shop.git"], check=False)
    v.folder = folder
    approve(v, folder)
    v.rpc("workflows/enable", {"folder": f"file://{folder}", "workflowID": "work-a-linear-issue", "enabled": True})

    # The video Chrome, signed in once by the person. Every key is hidden before it is drawn.
    web = v.open_site("https://linear.app/")
    web("secret", pattern=KEY_PATTERN)
    v.wait_until(lambda: "/login" not in web("url") and re.match(r"https://linear\.app/[^/]+/", web("url")),
                 timeout=30, what="linear.app signed in (Alex signs in once: scripts/video/make.sh --sign-in linear)")
    v.workspace = urllib.parse.urlsplit(web("url")).path.strip("/").split("/")[0]
    v.issues = []
    # Made now, minutes before the take labels one: Linear keeps no history of an issue's first
    # minutes, so a label added then is no event (use-linear-issues.md).
    for title, description in TEST_ISSUES:
        web("open", url="https://linear.app/new?" + urllib.parse.urlencode(
            {"title": title, "description": description, **({"team": os.environ["AGENTS_VIDEO_LINEAR_TEAM"]}
                                                           if os.environ.get("AGENTS_VIDEO_LINEAR_TEAM") else {})}),
            width=BROWSER[0], height=BROWSER[1], tab="site")
        web("click", text="Create issue", timeout=20000)
        v.sleep(2.0)
    v.issues_made_at = time.time()
    web("open", url=f"https://linear.app/{v.workspace}/settings/account/security", width=BROWSER[0], height=BROWSER[1], tab="site")
    v.tidy()
    v.unfold("shop")


def approve(v, folder):
    """The project's linear entry approved, as Approve on the Connectors page does."""
    destination = {"kind": "project", "folder": str(folder)}
    for _ in range(20):
        servers = (v.rpc("mcp/list", {"destination": destination}) or {}).get("servers", [])
        entry = next((s for s in servers if s.get("name") == "linear"), None)
        if entry and entry.get("entryDigest"):
            v.rpc("mcp/approve", {"destination": destination, "name": "linear", "digest": entry["entryDigest"]})
            return
        time.sleep(0.5)
    raise RuntimeError("the project's linear server was not listed to approve")


# --- the take ------------------------------------------------------------------------------
def run(v):
    web = v.web
    v.sleep(1.0)
    v.say("intro")

    # 1. The key, on Linear's page: made, read into the scene, never drawn.
    v.say("key", wait=False)
    web("click", text="New API key")
    web("type", selector="input[name=label], input[placeholder*=name i], input[type=text]", text=KEY_NAME)
    web("tryClick", text="Read", within="body")
    web("click", text="Create")
    key = v.wait_until(lambda: web("eval", expr=FIND_KEY), timeout=30, what="the new key on Linear's page")
    v.secret("the API key", key, refused(key, bearer=False))
    v.sleep(max(0.5, v.takes["key"]["duration"] - 4))
    web("tryClick", text="Done", within="body")

    # 2. Connect Linear in the window; its sign-in in the video Chrome (the walk hand-off).
    v.say("connect", wait=False)
    v.select("Connectors")
    v.press("Open")  # the project's row: its Connectors page, Tasks first
    v.press("Linear…")
    v.sleep(v.takes["connect"]["duration"])
    hand_off = Path.home() / "Library/Containers/com.alexecollins.agents.store/Data/Library/Application Support" \
        / f"Agents/walks/run-vid-{v.scene.ID}/sign-in.json"
    hand_off.unlink(missing_ok=True)
    v.press("=Continue on linear.app")
    note = json.loads(v.wait_until(lambda: hand_off.exists() and hand_off.read_text(), timeout=20, what="the sign-in's address"))
    v.say("approve", wait=False)
    web("open", url=note["address"], width=BROWSER[0], height=BROWSER[1], tab="site")
    web("click", text="Authorize")
    back = web("waitUrl", prefix="https://agentloops.dev/oauth/callback", timeout=60000)
    query = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(back).query))
    v.secret("the sign-in's code", query.get("code"))  # spent once, below: only looked for
    v.rpc("connections/sign-in/complete", {"flowID": note["flowID"], "state": query.get("state", ""),
                                            **({"code": query["code"]} if "code" in query else {"error": query.get("error", "no code")})})
    access = v.wait_until(lambda: keychain_access(v), timeout=30, what="the connection")
    v.secret("the OAuth grant", access, refused(access, bearer=True))
    v.oauth = access
    v.say("connected")

    # 3. The Linear issues page, on the Mac and on the web page, and Start Agent.
    v.say("page", wait=False)
    v.select("Linear issues")
    v.wait_until(lambda: TEST_ISSUES[0][0] in v.find(TEST_ISSUES[0][0]), timeout=60, what="the test issue on the page")
    v.sleep(v.takes["page"]["duration"])
    v.say("web", wait=False)
    v.open_web_tab()
    web("click", text="Linear issues")
    web("waitFor", expr=f"document.body.innerText.includes({TEST_ISSUES[0][0]!r})", timeout=60000)
    v.sleep(v.takes["web"]["duration"])
    web("tab", name="site")
    v.say("start", wait=False)
    v.press("Start Agent")
    v.sleep(v.takes["start"]["duration"] + 1.0)
    v.key("escape")

    # 4. Work a Linear issue: the label, in Linear, and the agent it starts.
    v.say("workflow")
    before = {a.get("id") for a in v.rpc("agents/list", {"includeArchived": False}) or []}
    v.say("label", wait=False)
    web("open", url=f"https://linear.app/{v.workspace}/my-issues/created", width=BROWSER[0], height=BROWSER[1], tab="site")
    web("click", text=TEST_ISSUES[1][0])
    web("key", key="l")
    web("type", text=LABEL)
    web("key", key="Enter")
    web("key", key="Escape")
    with v.fast(3.0):
        # Linear is asked once a minute, and an issue's first minutes have no history.
        v.sleep(max(0.0, v.issues_made_at + 330 - time.time()))
        started = v.wait_until(lambda: [a for a in v.rpc("agents/list", {"includeArchived": False}) or []
                                        if a.get("id") not in before], timeout=300, every=3, what="the workflow's agent")
    v.say("started", wait=False)
    v.select_agent(started[0]["id"])
    v.sleep(v.takes["started"]["duration"] + 2.0)
    v.rpc("agents/stop", {"agentID": started[0]["id"]})
    v.say("end")


# --- after the take (make.py calls it, kept or not) ----------------------------------------
def revoke(v):
    """The key on Linear's page, the grant at Linear's revoke endpoint, the test issues."""
    if getattr(v, "oauth", None):
        for title, _ in TEST_ISSUES:
            _, data = linear(v.oauth, "query($t: String!) { issues(filter: { title: { eq: $t } }) { nodes { id } } }", {"t": title})
            for node in ((data or {}).get("issues") or {}).get("nodes", []):
                linear(v.oauth, "mutation($id: String!) { issueDelete(id: $id) { success } }", {"id": node["id"]})
        request = urllib.request.Request("https://api.linear.app/oauth/revoke",
                                         data=urllib.parse.urlencode({"token": v.oauth}).encode(),
                                         headers={"Content-Type": "application/x-www-form-urlencoded",
                                                  "Authorization": f"Bearer {v.oauth}"})
        try:
            urllib.request.urlopen(request, timeout=30).close()
        except urllib.error.HTTPError as error:
            print(f"revoke: Linear answered {error.code} to the grant's revoke")
        try:
            v.rpc("connections/disconnect", {"provider": "linear"})
        except Exception:
            pass
    if v.web:
        web = v.web
        web("open", url=f"https://linear.app/{getattr(v, 'workspace', '')}/settings/account/security".replace("//settings", "/settings"),
            width=BROWSER[0], height=BROWSER[1], tab="site")
        web("click", text=KEY_NAME)
        web("click", text="Revoke")
        web("tryClick", text="Revoke", within="[role=dialog]")
        time.sleep(2.0)
