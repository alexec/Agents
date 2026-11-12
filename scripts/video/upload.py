#!/usr/bin/env python3
"""Uploads a finished video to YouTube (#1793, #1794, #4836), with the YouTube Data API v3.

    scripts/video/upload.py --sign-in           once: the person approves with the Google
                                                account of the channel
    scripts/video/upload.py --sign-in --no-browser
                                                the same, but only print the consent address,
                                                so an agent opens it in the agents' Chrome (#4840)
    scripts/video/upload.py <scene id> [mp4]    upload ~/Movies/agents-video/out/<id>.mp4
    scripts/video/make.sh u1 --upload           make it, check it, then upload it
    scripts/video/upload.py --self-test         prove each API call against a fake YouTube

Every video is **private** (an API project that Google has not audited can upload only
private videos anyway; a flag for public comes later) and goes on the Loops channel, in the
playlist of its scene's GROUP: "Loops usage", "Loops marketing" or "Loops integrations",
each made private the first time. The title is `<TITLE> — Loops <x.y>`: the release being
made (LOOPS_RELEASE=v<version>, from the release skill), else the last tag (#4962). The
description gives the full `git describe`, the commit, the date, the scene file and the docs page, so a video
always says which build it shows. The captions are the take's `<id>.vtt` (English), and the
thumbnail is a frame of the take, at one of the contact sheet's moments. A new take of a
video replaces the old one in its playlist: the old video is made private and taken out of
the playlist, never deleted. The local files are deleted after a good upload.

The OAuth client (a Desktop app) is ~/.agents/secrets/youtube-client.json, made by the person
(#1793). Its refresh token is kept in ~/.agents/secrets/youtube-token.json, mode 600. No token
is printed.
"""
import base64
import hashlib
import http.server
import json
import os
import re
import secrets
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import webbrowser
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
SECRETS = Path.home() / ".agents/secrets"
CLIENT = SECRETS / "youtube-client.json"
TOKEN = SECRETS / "youtube-token.json"
OUT = Path(os.environ.get("AGENTS_VIDEO_OUT", Path.home() / "Movies/agents-video/out"))
CHANNEL = "Loops"
# A playlist per scene GROUP (#4836): its title and its description.
PLAYLISTS = {
    "usage": ("Loops usage", "How to use Loops: Agent Workflows, a step at a time. Each video is made by a script (#1078)."),
    "marketing": ("Loops marketing", "What Loops: Agent Workflows does, in short videos. Each video is made by a script (#1078)."),
    "integration": ("Loops integrations", "Loops' integrations, each in a video made by a script on a real account (#1793)."),
}
DOCS = "https://docs.agentloops.dev/"
# The contact sheet takes a frame every two seconds (make.contact_sheet): the thumbnail is
# one of those moments.
SHEET_EVERY = 2
# Upload, playlists, a video's privacy and captions: the one scope that has all four.
# `youtube` alone has no captions.insert (403 insufficientPermissions, #4838).
SCOPE = "https://www.googleapis.com/auth/youtube.force-ssl"
API = "https://www.googleapis.com/youtube/v3"
UPLOAD = "https://www.googleapis.com/upload/youtube/v3/videos"
CAPTIONS = "https://www.googleapis.com/upload/youtube/v3/captions"
THUMBNAILS = "https://www.googleapis.com/upload/youtube/v3/thumbnails/set"
SCIENCE_AND_TECHNOLOGY = "28"


class NotSignedIn(RuntimeError):
    """There is no working sign-in yet: the video stays in out/."""


# How a sign-in is done again, by an agent (#4840): only a new Google sign-in in that Chrome
# (the account's password) needs Alex.
SIGN_IN_AGAIN = ("an agent runs `scripts/video/upload.py --sign-in --no-browser` and approves in the "
                 "agents' Chrome (scripts/video/README.md, #4840)")


class GoogleError(RuntimeError):
    """Google's OAuth error answer: `error` is its code, such as invalid_grant."""

    def __init__(self, code, error, description):
        super().__init__(f"Google answered {code}: {error} {description}".strip())
        self.error = error


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


# --- OAuth -------------------------------------------------------------------------------
def client():
    if not CLIENT.exists():
        raise NotSignedIn(f"no YouTube OAuth client at {CLIENT}: Alex makes it (#1793, What Alex does)")
    data = json.loads(CLIENT.read_text())
    return data.get("installed") or data.get("web") or data


def post_form(url, form):
    request = urllib.request.Request(url, data=urllib.parse.urlencode(form).encode(),
                                     headers={"Content-Type": "application/x-www-form-urlencoded"})
    try:
        with urllib.request.urlopen(request, timeout=60) as answer:
            return json.load(answer)
    except urllib.error.HTTPError as error:
        # Google's error answer names the error, never the token sent.
        body = json.loads(error.read() or b"{}")
        raise GoogleError(error.code, body.get("error", ""), body.get("error_description", "")) from None


def sign_in(browser=True):
    """The loopback flow with PKCE (Google's way for a desktop app): the browser goes to
    Google, the person approves, Google sends the code to a port on this Mac.

    The consent address is always printed: it holds the client id, the PKCE challenge and
    the state, and no secret. With `browser` False it is not opened, so an agent opens it in
    a browser it can drive (#1856)."""
    c = client()
    verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    state = secrets.token_hex(16)
    got = {}

    class Back(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            if query.get("state", [""])[0] == state:
                got.update({k: v[0] for k, v in query.items()})
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.end_headers()
            self.wfile.write("Agents videos: you can close this tab.\n".encode())

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Back)
    redirect = f"http://127.0.0.1:{server.server_port}"
    address = c.get("auth_uri", "https://accounts.google.com/o/oauth2/auth") + "?" + urllib.parse.urlencode({
        "client_id": c["client_id"], "redirect_uri": redirect, "response_type": "code", "scope": SCOPE,
        "state": state, "code_challenge": challenge, "code_challenge_method": "S256",
        "access_type": "offline", "prompt": "consent"})
    threading.Thread(target=server.serve_forever, daemon=True).start()
    log("approve in the browser, with the Google account of the YouTube channel")
    print(f"consent address: {address}", flush=True)
    if browser:
        webbrowser.open(address)
    else:
        log(f"not opened (--no-browser): open the address above; this waits on {redirect} for 10 minutes")
    end = time.time() + 600
    while "code" not in got and "error" not in got and time.time() < end:
        time.sleep(0.3)
    server.shutdown()
    if "code" not in got:
        raise SystemExit(f"no approval: {got.get('error', 'timed out')}")
    answer = post_form(c.get("token_uri", "https://oauth2.googleapis.com/token"), {
        "code": got["code"], "client_id": c["client_id"], "client_secret": c.get("client_secret", ""),
        "redirect_uri": redirect, "grant_type": "authorization_code", "code_verifier": verifier})
    if not answer.get("refresh_token"):
        raise SystemExit("Google gave no refresh token: remove Agents from the account's third-party access and sign in again")
    SECRETS.mkdir(parents=True, exist_ok=True)
    fd = os.open(TOKEN, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump({"refresh_token": answer["refresh_token"]}, out)
    log(f"signed in: the refresh token is in {TOKEN}")


def access_token():
    """An access token, and the scopes the sign-in gave."""
    if not TOKEN.exists():
        raise NotSignedIn(f"not signed in to YouTube: {SIGN_IN_AGAIN}")
    c = client()
    refresh = json.loads(TOKEN.read_text()).get("refresh_token")
    if not refresh:
        # A copy of the client file in its place (seen 2026-10-21) is not a sign-in.
        raise NotSignedIn(f"{TOKEN} has no refresh token: {SIGN_IN_AGAIN}")
    try:
        answer = post_form(c.get("token_uri", "https://oauth2.googleapis.com/token"), {
            "refresh_token": refresh, "client_id": c["client_id"], "client_secret": c.get("client_secret", ""),
            "grant_type": "refresh_token"})
    except GoogleError as error:
        if error.error != "invalid_grant":
            raise
        # The account took its access back, its password changed, or the app went back to
        # Testing (a token then lasts 7 days): a new consent is the fix (#4840).
        raise NotSignedIn(f"the YouTube refresh token was revoked or has expired (invalid_grant): {SIGN_IN_AGAIN}") from None
    return answer["access_token"], set(answer.get("scope", "").split())


# --- the API -----------------------------------------------------------------------------
class APIError(RuntimeError):
    def __init__(self, method, url, code, body):
        path = urllib.parse.urlsplit(url).path
        super().__init__(f"YouTube {method} {path}: {code} {body[:400].decode(errors='replace')}")
        self.code = code


class YouTube:
    """The calls upload.py makes. Every request goes through `send`, which the self-test's
    fake replaces."""

    def __init__(self, token=None):
        self.token, self.scopes = (token, {SCOPE}) if token else access_token()
        self.waits = (5, 10, 20, 30)  # seconds, while a new playlist is 404

    def send(self, method, url, data=None, headers=None, timeout=120):
        """One request: the answer's headers and body. Fails with APIError on an HTTP error."""
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}", **(headers or {})})
        try:
            with urllib.request.urlopen(request, timeout=timeout) as answer:
                return dict(answer.headers), answer.read()
        except urllib.error.HTTPError as error:
            raise APIError(method, url, error.code, error.read()) from None

    def call(self, method, path, query=None, body=None):
        url = f"{API}/{path}" + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        _, raw = self.send(method, url, data, {"Content-Type": "application/json"} if data else None)
        return json.loads(raw) if raw else {}

    def pages(self, path, query):
        query = dict(query)
        while True:
            answer = self.call("GET", path, query)
            yield from answer.get("items", [])
            if not answer.get("nextPageToken"):
                return
            query["pageToken"] = answer["nextPageToken"]

    def settled(self, call, *args):
        """`call(*args)`, again after a wait while it is 404: YouTube answers 404
        (playlistNotFound) for a playlist made a few seconds before (#4838)."""
        for wait in (*self.waits, None):
            try:
                return call(*args)
            except APIError as error:
                if error.code != 404 or wait is None:
                    raise
                log(f"YouTube does not know the playlist yet (404): again in {wait} s")
                time.sleep(wait)

    def channel(self):
        """The signed-in channel's title, or None when the sign-in has no channel."""
        mine = self.call("GET", "channels", {"part": "snippet", "mine": "true"}).get("items", [])
        return mine[0]["snippet"]["title"] if mine else None

    def playlist(self, title, description):
        """The playlist's id, made (private) the first time."""
        for item in self.pages("playlists", {"part": "snippet", "mine": "true", "maxResults": 50}):
            if item["snippet"]["title"] == title:
                return item["id"]
        made = self.call("POST", "playlists", {"part": "snippet,status"}, {
            "snippet": {"title": title, "description": description},
            "status": {"privacyStatus": "private"}})
        log(f"made the playlist {title!r}, private")
        return made["id"]

    def upload(self, mp4, snippet):
        """A resumable upload, in one piece."""
        size = mp4.stat().st_size
        headers, _ = self.send("POST", f"{UPLOAD}?uploadType=resumable&part=snippet,status",
                               json.dumps({"snippet": snippet, "status": {
                                   "privacyStatus": "private", "selfDeclaredMadeForKids": False}}).encode(),
                               {"Content-Type": "application/json; charset=UTF-8",
                                "X-Upload-Content-Type": "video/mp4", "X-Upload-Content-Length": str(size)},
                               timeout=60)
        where = {k.lower(): v for k, v in headers.items()}["location"]
        with open(mp4, "rb") as body:  # streamed: a take can be hundreds of MB
            _, raw = self.send("PUT", where, body, {"Content-Type": "video/mp4", "Content-Length": str(size)},
                               timeout=3600)
        return json.loads(raw)["id"]

    def captions(self, video, vtt, language="en", name="English"):
        """captions.insert: the take's WebVTT as the video's captions, in one multipart request."""
        boundary = "agents-" + secrets.token_hex(8)
        meta = json.dumps({"snippet": {"videoId": video, "language": language, "name": name, "isDraft": False}})
        body = (f"--{boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n{meta}\r\n"
                f"--{boundary}\r\nContent-Type: text/vtt\r\n\r\n").encode() + vtt.read_bytes() + f"\r\n--{boundary}--\r\n".encode()
        _, raw = self.send("POST", f"{CAPTIONS}?uploadType=multipart&part=snippet", body,
                           {"Content-Type": f"multipart/related; boundary={boundary}"})
        return json.loads(raw)["id"]

    def thumbnail(self, video, jpg):
        """thumbnails.set: a JPEG of at most 2 MB."""
        self.send("POST", f"{THUMBNAILS}?{urllib.parse.urlencode({'videoId': video})}", jpg.read_bytes(),
                  {"Content-Type": "image/jpeg"})


def check_channel(yt):
    """Why the sign-in cannot upload, or None: it must be the Loops channel's, with SCOPE."""
    if SCOPE not in yt.scopes:
        return f"the YouTube sign-in lacks {SCOPE} (captions need it): sign in again with `scripts/video/upload.py --sign-in`"
    title = yt.channel()
    if title is None:
        return "the YouTube sign-in has no channel"
    if title != CHANNEL:
        return f"the YouTube sign-in is the channel {title!r}, not {CHANNEL!r}: sign in again and pick {CHANNEL}"
    return None


def playlist_of(scene):
    """The playlist (title, description) of the scene's GROUP."""
    group = getattr(scene, "GROUP", "")
    if group not in PLAYLISTS:
        raise SystemExit(f"{scene.ID}: GROUP {group!r} has no playlist (one of {', '.join(PLAYLISTS)})")
    return PLAYLISTS[group]


# --- what a video says of itself ---------------------------------------------------------
def git(*args):
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True).stdout.strip()


def marker(scene_id):
    """The line in a description that says which scene made the video."""
    return f"Scene: scripts/video/scenes/{scene_id}.py"


def docs_page(scene):
    """The docs page the scene is for: DOCS is a path on the docs site (the site's home when
    the scene has none)."""
    return DOCS + getattr(scene, "DOCS", "").lstrip("/")


def release(given=None, last_tag=None):
    """The release a video's title names (#4962): `<x>.<y>` of the release being made
    (LOOPS_RELEASE, which the release skill passes, such as `v0.19.0`), else of the last
    `v*` tag, with no count and hash, else "unreleased". A viewer sees a version, not a
    build id; the description keeps the full `git describe`."""
    given = os.environ.get("LOOPS_RELEASE", "") if given is None else given
    tag = given.strip() or (git("describe", "--tags", "--match", "v*", "--abbrev=0") if last_tag is None else last_tag)
    match = re.match(r"v?(\d+)\.(\d+)", tag or "")
    return f"{match[1]}.{match[2]}" if match else "unreleased"


def describe(scene):
    version = release()
    build = git("describe", "--tags", "--match", "v*") or "no tag"
    commit = git("rev-parse", "HEAD")
    changed = " (with changes not committed)" if git("status", "--porcelain", "--untracked-files=no") else ""
    name = getattr(scene, "TITLE", scene.ID)
    group = getattr(scene, "GROUP", "")
    from voice import plain  # a line's words, without its directions (#4964)
    lines = [plain(line) for line in getattr(scene, "LINES", {}).values()]
    description = "\n".join([
        f"{name}, in Loops {version}.",
        "",
        f"Docs: {docs_page(scene)}",
        "",
        f"Build: {build}",
        f"Commit: {commit}{changed}",
        f"Made: {time.strftime('%Y-%m-%d %H:%M %Z')}",
        marker(scene.ID),
        "",
        *(["Made by a script on a real account (#1793). The tokens it made were revoked after the take.", ""]
          if group == "integration" else ["Made by a script, on a scratch set-up (#1078).", ""]),
        "What it says:",
        *lines,
    ])
    return {"title": f"{name} — Loops {version}"[:100], "description": description[:4900],
            "categoryId": SCIENCE_AND_TECHNOLOGY,
            "tags": ["Loops", "Agents", group, getattr(scene, "INTEGRATION", scene.ID)]}


def duration(mp4):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(mp4)],
                         capture_output=True, text=True, check=True).stdout
    return float(out.strip() or 0)


def thumbnail_of(scene, mp4, jpg):
    """A frame of the take, 1280 wide, as JPEG: the scene's THUMBNAIL second, or two fifths
    in, each put on the contact sheet's two-second step."""
    length = duration(mp4)
    at = getattr(scene, "THUMBNAIL", length * 0.4)
    at = max(0, min(round(at / SHEET_EVERY) * SHEET_EVERY, int(length // SHEET_EVERY) * SHEET_EVERY))
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-ss", str(at), "-i", str(mp4), "-frames:v", "1",
                    "-vf", "scale=1280:-2", "-q:v", "3", str(jpg)], check=True)
    return at


def upload(scene, mp4, yt=None):
    """Uploads `mp4` with its captions and a thumbnail, puts it first in its group's
    playlist, and replaces older takes of the scene there."""
    title, about = playlist_of(scene)
    vtt = mp4.with_suffix(".vtt")
    if not vtt.exists():
        raise SystemExit(f"no captions at {vtt}: make the video again (scripts/video/make.sh {scene.ID})")
    if yt is None:
        try:
            yt = YouTube()
        except NotSignedIn as why:
            log(f"not uploaded, {mp4} is kept: {why}")
            return None
    playlist = yt.playlist(title, about)
    older = [(item["id"], item["snippet"]["resourceId"]["videoId"])
             for item in yt.settled(lambda: list(yt.pages("playlistItems", {
                 "part": "snippet", "playlistId": playlist, "maxResults": 50})))
             if marker(scene.ID) in item["snippet"].get("description", "")]
    log(f"uploading {mp4.name} ({mp4.stat().st_size // 1_000_000} MB), private, to {title!r}")
    video = yt.upload(mp4, describe(scene))
    yt.settled(yt.call, "POST", "playlistItems", {"part": "snippet"}, {"snippet": {
        "playlistId": playlist, "position": 0, "resourceId": {"kind": "youtube#video", "videoId": video}}})
    for item, old in older:
        yt.call("PUT", "videos", {"part": "status"}, {"id": old, "status": {"privacyStatus": "private"}})
        yt.call("DELETE", "playlistItems", {"id": item})
        log(f"the older take {old} is private and out of the playlist (not deleted)")
    yt.captions(video, vtt)
    log("captions: English, from", vtt.name)
    jpg = mp4.with_suffix(".jpg")
    try:
        at = thumbnail_of(scene, mp4, jpg)
        yt.thumbnail(video, jpg)
        log(f"thumbnail: the frame at {at}s")
    except APIError as error:
        # A channel must be verified (a phone number) before it can set a thumbnail.
        log(f"no thumbnail ({error}): the channel may not be verified yet; YouTube picks one")
    finally:
        jpg.unlink(missing_ok=True)
    log(f"uploaded: https://youtu.be/{video}")
    mp4.unlink()
    vtt.unlink(missing_ok=True)
    return video


# --- the self-test: every call against a fake YouTube (#4836) ----------------------------
class FakeYouTube(YouTube):
    """Answers as the API does, from state in memory, and keeps every request."""

    def __init__(self, channel=CHANNEL, thumbnails=True, unknown_for=0, scopes=(SCOPE,)):
        self.token = "fake"
        self.scopes = scopes
        self.waits = (0, 0, 0, 0)
        self.requests = []
        self.playlists, self.items, self.videos = {}, {}, {}
        self.captions_of, self.thumbnails = {}, {}
        self.channel_title, self.thumbnails_allowed = channel, thumbnails
        self.n = 0
        self.unknown_for = unknown_for  # playlistItems calls that 404 after a playlist is made
        self.unknown = {}

    def new_id(self, kind):
        self.n += 1
        return f"{kind}{self.n}"

    def send(self, method, url, data=None, headers=None, timeout=120):
        self.requests.append((method, url, data, headers or {}))
        parts = urllib.parse.urlsplit(url)
        query = {k: v[0] for k, v in urllib.parse.parse_qs(parts.query).items()}
        body = json.loads(data) if data and (headers or {}).get("Content-Type", "").startswith("application/json") else None
        path = parts.path
        answer = lambda value: ({}, json.dumps(value).encode())
        if path.endswith("/channels"):
            return answer({"items": [{"snippet": {"title": self.channel_title}}] if self.channel_title else []})
        if path.endswith("/youtube/v3/playlists") and method == "GET":
            return answer({"items": [{"id": i, "snippet": p["snippet"]} for i, p in self.playlists.items()]})
        if path.endswith("/youtube/v3/playlists") and method == "POST":
            made = self.new_id("PL")
            self.playlists[made] = body
            self.unknown[made] = self.unknown_for
            return answer({"id": made})
        if path.endswith("/playlistItems") and method in ("GET", "POST"):
            playlist = query.get("playlistId") or body["snippet"]["playlistId"]
            if self.unknown.get(playlist):
                self.unknown[playlist] -= 1
                raise APIError(method, url, 404, b'{"error": {"errors": [{"reason": "playlistNotFound"}]}}')
        if path.endswith("/playlistItems") and method == "GET":
            return answer({"items": [{"id": i, "snippet": {**self.videos[v["snippet"]["resourceId"]["videoId"]]["snippet"],
                                                           "resourceId": v["snippet"]["resourceId"]}}
                                     for i, v in self.items.items() if v["snippet"]["playlistId"] == query["playlistId"]]})
        if path.endswith("/playlistItems") and method == "POST":
            made = self.new_id("PI")
            self.items[made] = body
            return answer({"id": made})
        if path.endswith("/playlistItems") and method == "DELETE":
            del self.items[query["id"]]
            return {}, b""
        if path.endswith("/youtube/v3/videos") and method == "PUT":
            self.videos[body["id"]]["status"] = body["status"]
            return answer({"id": body["id"]})
        if path.endswith("/youtube/v3/videos") and method == "DELETE":
            raise AssertionError("a video was deleted")
        if path.endswith("/upload/youtube/v3/videos") and method == "POST":
            made = self.new_id("V")
            self.videos[made] = dict(body, bytes=None)
            return {"Location": f"https://upload.example/{made}"}, b""
        if parts.netloc == "upload.example" and method == "PUT":
            made = path.strip("/")
            self.videos[made]["bytes"] = data.read()
            return answer({"id": made})
        if path.endswith("/upload/youtube/v3/captions"):
            boundary = headers["Content-Type"].split("boundary=")[1]
            meta, vtt = [chunk.split(b"\r\n\r\n", 1)[1].rsplit(b"\r\n", 1)[0]
                         for chunk in data.split(f"--{boundary}".encode())[1:3]]
            meta = json.loads(meta)
            self.captions_of[meta["snippet"]["videoId"]] = (meta, vtt)
            return answer({"id": self.new_id("C")})
        if path.endswith("/thumbnails/set"):
            if not self.thumbnails_allowed:
                raise APIError(method, url, 403, b'{"error": "forbidden"}')
            self.thumbnails[query["videoId"]] = data
            return answer({})
        raise AssertionError(f"an unexpected call: {method} {url}")


def self_test():
    import shutil
    import tempfile
    import types

    if not shutil.which("ffmpeg"):
        raise SystemExit("--self-test needs ffmpeg (brew install ffmpeg)")
    work = Path(tempfile.mkdtemp(prefix="upload-self-test-"))
    vtt_text = b"WEBVTT\n\n00:00.000 --> 00:02.000\nThis is Loops.\n"

    def take(scene_id, seconds=6):
        mp4 = work / f"{scene_id}.mp4"
        subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc=size=640x360:rate=10:duration={seconds}",
                        "-pix_fmt", "yuv420p", str(mp4)], check=True)
        mp4.with_suffix(".vtt").write_bytes(vtt_text)
        return mp4

    def scene(scene_id, group, **more):
        return types.SimpleNamespace(ID=scene_id, GROUP=group, TITLE=f"Scene {scene_id}",
                                     LINES={"a": "This is Loops."}, **more)

    for given, last_tag, want in (("v0.19.0", "v0.18.0", "0.19"), ("0.19", None, "0.19"),
                                  ("", "v0.18.0", "0.18"), ("", "", "unreleased")):
        got = release(given, last_tag)
        assert got == want and "-g" not in got, (given, last_tag, got)
    print("ok: a title names the release (LOOPS_RELEASE, else the last tag), never a -g<hash>")

    try:
        yt = FakeYouTube()
        u1 = scene("u1", "usage", DOCS="tutorials/first-agent/")
        first = upload(u1, take("u1"), yt)
        (playlist, made), = yt.playlists.items()
        assert made["snippet"]["title"] == "Loops usage" and made["status"]["privacyStatus"] == "private", made
        video = yt.videos[first]
        assert video["status"]["privacyStatus"] == "private", video
        assert re.fullmatch(r"Scene u1 — Loops (\d+\.\d+|unreleased)", video["snippet"]["title"]), video["snippet"]["title"]
        about = video["snippet"]["description"]
        for want in ("Build: ", "Commit: ", "Made: ", marker("u1"), "Docs: https://docs.agentloops.dev/tutorials/first-agent/"):
            assert want in about, (want, about)
        assert video["bytes"] and video["bytes"][4:8] == b"ftyp", "the mp4 was not sent"
        (item,) = yt.items.values()
        assert item["snippet"] == {"playlistId": playlist, "position": 0,
                                   "resourceId": {"kind": "youtube#video", "videoId": first}}, item
        meta, vtt = yt.captions_of[first]
        assert meta["snippet"] == {"videoId": first, "language": "en", "name": "English", "isDraft": False}, meta
        assert vtt == vtt_text, vtt
        assert yt.thumbnails[first][:2] == b"\xff\xd8", "the thumbnail is not a JPEG"
        assert not (work / "u1.mp4").exists() and not (work / "u1.vtt").exists() and not (work / "u1.jpg").exists()
        print("ok: a usage take goes private to 'Loops usage' (made private), with its captions and a thumbnail")

        second = upload(u1, take("u1"), yt)
        assert len(yt.playlists) == 1, "the playlist was made twice"
        assert [i["snippet"]["resourceId"]["videoId"] for i in yt.items.values()] == [second], yt.items
        assert first in yt.videos and yt.videos[first]["status"] == {"privacyStatus": "private"}, yt.videos[first]
        print("ok: a new take replaces the old one in its playlist; the old one stays, private")

        for scene_id, group, title in (("a2", "marketing", "Loops marketing"), ("i-x", "integration", "Loops integrations")):
            made = upload(scene(scene_id, group, INTEGRATION="x"), take(scene_id), yt)
            (home,) = [i["snippet"]["playlistId"] for i in yt.items.values() if i["snippet"]["resourceId"]["videoId"] == made]
            assert yt.playlists[home]["snippet"]["title"] == title, yt.playlists[home]
            if group == "marketing":
                assert "Docs: https://docs.agentloops.dev/\n" in yt.videos[made]["snippet"]["description"]
        assert len(yt.playlists) == 3, yt.playlists
        print("ok: a playlist per group: Loops usage, Loops marketing, Loops integrations")

        sent = len(yt.requests)
        try:
            upload(scene("x1", "nothing"), take("x1"), yt)
            raise AssertionError("a scene with no group's playlist was uploaded")
        except SystemExit:
            pass
        assert len(yt.requests) == sent, "a call was made for a scene with no playlist"
        print("ok: a GROUP with no playlist fails before any call")

        bare = FakeYouTube(thumbnails=False)
        made = upload(scene("u3", "usage"), take("u3"), bare)
        assert made in bare.captions_of and not bare.thumbnails
        print("ok: a channel that cannot set a thumbnail still gets the video and its captions")

        slow = FakeYouTube(unknown_for=2)
        made = upload(scene("u4", "usage"), take("u4"), slow)
        assert [i["snippet"]["resourceId"]["videoId"] for i in slow.items.values()] == [made], slow.items
        print("ok: a playlist YouTube does not know yet (404) is asked again")

        assert check_channel(FakeYouTube()) is None
        assert "not 'Loops'" in check_channel(FakeYouTube(channel="Someone else"))
        assert "no channel" in check_channel(FakeYouTube(channel=None))
        assert "lacks" in check_channel(FakeYouTube(scopes=("https://www.googleapis.com/auth/youtube",)))
        print("ok: --preflight takes only the Loops channel's sign-in, with the captions scope")

        global CLIENT, TOKEN, post_form
        kept = CLIENT, TOKEN, post_form
        try:
            CLIENT, TOKEN = work / "client.json", work / "token.json"
            CLIENT.write_text(json.dumps({"installed": {"client_id": "id", "client_secret": "s"}}))
            TOKEN.write_text(json.dumps({"refresh_token": "r"}))

            def revoked(url, form):
                raise GoogleError(400, "invalid_grant", "Token has been expired or revoked.")
            post_form = revoked
            try:
                access_token()
                raise AssertionError("a revoked token was taken")
            except NotSignedIn as why:
                assert "revoked" in str(why) and "--sign-in --no-browser" in str(why), why

            def down(url, form):
                raise GoogleError(500, "internal_failure", "")
            post_form = down
            try:
                access_token()
                raise AssertionError("an error was taken for a token")
            except NotSignedIn:
                raise AssertionError("an outage was taken for a revoked token") from None
            except GoogleError:
                pass
        finally:
            CLIENT, TOKEN, post_form = kept
        print("ok: a revoked refresh token is a missing sign-in, and says how to sign in again")
        assert not [r for r in yt.requests if r[0] == "DELETE" and "/videos" in r[1]], "a video was deleted"
        print("self-test passed")
    finally:
        shutil.rmtree(work, ignore_errors=True)


def main():
    args = sys.argv[1:]
    if args == ["--self-test"]:
        return self_test()
    if "--sign-in" in args:
        unknown = set(args) - {"--sign-in", "--no-browser"}
        if unknown:
            raise SystemExit(f"--sign-in takes only --no-browser, not {' '.join(sorted(unknown))}")
        return sign_in(browser="--no-browser" not in args)
    if not sys.argv[1:] or sys.argv[1].startswith("-"):
        raise SystemExit(__doc__)
    sys.path.insert(0, str(HERE))
    from make import load_scene
    scene = load_scene(sys.argv[1])
    mp4 = Path(sys.argv[2]) if len(sys.argv) > 2 else OUT / f"{scene.ID}.mp4"
    if not mp4.exists():
        raise SystemExit(f"no video at {mp4}: make it first (scripts/video/make.sh {scene.ID})")
    upload(scene, mp4)


if __name__ == "__main__":
    main()
