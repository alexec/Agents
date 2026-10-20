#!/usr/bin/env python3
"""Uploads a finished video to YouTube (#1793, #1794), with the YouTube Data API v3.

    scripts/video/upload.py --sign-in           once: the person approves with the Google
                                                account of the channel
    scripts/video/upload.py <scene id> [mp4]    upload ~/Movies/agents-video/out/<id>.mp4
    scripts/video/make.sh i-linear --upload     make it, check it, then upload it

Every video is **private** (an API project that Google has not audited can upload only
private videos anyway) and goes in the playlist "Agents integrations". The title names the
integration and the app version (`git describe`); the description gives the commit, the date
and the scene file, so a video always says which build it shows. A new take of a video
replaces the old one in the playlist: the old video is made private and taken out of the
playlist, never deleted. The local file is deleted after a good upload.

The OAuth client (a Desktop app) is ~/.agents/secrets/youtube-client.json, made by the person
(#1793). Its refresh token is kept in ~/.agents/secrets/youtube-token.json, mode 600. No token
is printed.
"""
import base64
import hashlib
import http.server
import json
import os
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
PLAYLIST = "Agents integrations"
# Upload, playlists and a video's privacy: the one scope that has all three.
SCOPE = "https://www.googleapis.com/auth/youtube"
API = "https://www.googleapis.com/youtube/v3"
UPLOAD = "https://www.googleapis.com/upload/youtube/v3/videos"
SCIENCE_AND_TECHNOLOGY = "28"


class NotSignedIn(RuntimeError):
    """The person's steps on #1793 are not done yet: the video stays in out/."""


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
        raise RuntimeError(f"Google answered {error.code}: {body.get('error', '')} {body.get('error_description', '')}".strip()) from None


def sign_in():
    """The loopback flow with PKCE (Google's way for a desktop app): the browser goes to
    Google, the person approves, Google sends the code to a port on this Mac."""
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
    webbrowser.open(address)
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
    if not TOKEN.exists():
        raise NotSignedIn("not signed in to YouTube: Alex runs `scripts/video/upload.py --sign-in` (#1793, What Alex does)")
    c = client()
    refresh = json.loads(TOKEN.read_text())["refresh_token"]
    return post_form(c.get("token_uri", "https://oauth2.googleapis.com/token"), {
        "refresh_token": refresh, "client_id": c["client_id"], "client_secret": c.get("client_secret", ""),
        "grant_type": "refresh_token"})["access_token"]


# --- the API -----------------------------------------------------------------------------
class YouTube:
    def __init__(self):
        self.token = access_token()

    def call(self, method, path, query=None, body=None):
        url = f"{API}/{path}" + ("?" + urllib.parse.urlencode(query) if query else "")
        data = json.dumps(body).encode() if body is not None else None
        request = urllib.request.Request(url, data=data, method=method, headers={
            "Authorization": f"Bearer {self.token}", **({"Content-Type": "application/json"} if data else {})})
        try:
            with urllib.request.urlopen(request, timeout=120) as answer:
                raw = answer.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"YouTube {method} {path}: {error.code} {error.read()[:400].decode(errors='replace')}") from None

    def pages(self, path, query):
        query = dict(query)
        while True:
            answer = self.call("GET", path, query)
            yield from answer.get("items", [])
            if not answer.get("nextPageToken"):
                return
            query["pageToken"] = answer["nextPageToken"]

    def playlist(self):
        """The playlist's id, made (private) the first time."""
        for item in self.pages("playlists", {"part": "snippet", "mine": "true", "maxResults": 50}):
            if item["snippet"]["title"] == PLAYLIST:
                return item["id"]
        made = self.call("POST", "playlists", {"part": "snippet,status"}, {
            "snippet": {"title": PLAYLIST, "description": "Agents' integrations, each in a video made by a script on a real account (#1793)."},
            "status": {"privacyStatus": "private"}})
        log(f"made the playlist {PLAYLIST!r}")
        return made["id"]

    def upload(self, mp4, snippet):
        """A resumable upload, in one piece."""
        size = mp4.stat().st_size
        start = urllib.request.Request(f"{UPLOAD}?uploadType=resumable&part=snippet,status", method="POST",
                                       data=json.dumps({"snippet": snippet, "status": {
                                           "privacyStatus": "private", "selfDeclaredMadeForKids": False}}).encode(),
                                       headers={"Authorization": f"Bearer {self.token}",
                                                "Content-Type": "application/json; charset=UTF-8",
                                                "X-Upload-Content-Type": "video/mp4",
                                                "X-Upload-Content-Length": str(size)})
        with urllib.request.urlopen(start, timeout=60) as answer:
            where = answer.headers["Location"]
        with open(mp4, "rb") as body:
            put = urllib.request.Request(where, data=body, method="PUT", headers={
                "Content-Type": "video/mp4", "Content-Length": str(size)})
            with urllib.request.urlopen(put, timeout=3600) as answer:
                return json.load(answer)["id"]


# --- what a video says of itself ---------------------------------------------------------
def git(*args):
    return subprocess.run(["git", "-C", str(REPO), *args], capture_output=True, text=True).stdout.strip()


def marker(scene_id):
    """The line in a description that says which scene made the video."""
    return f"Scene: scripts/video/scenes/{scene_id}.py"


def describe(scene):
    version = git("describe", "--tags", "--match", "v*") or "unreleased"
    commit = git("rev-parse", "HEAD")
    changed = " (with changes not committed)" if git("status", "--porcelain", "--untracked-files=no") else ""
    title = f"{getattr(scene, 'TITLE', scene.ID)}: Agents {version}"
    lines = [*getattr(scene, "LINES", {}).values()]
    description = "\n".join([
        f"{getattr(scene, 'TITLE', scene.ID)}, in Agents {version}.",
        "",
        f"Commit: {commit}{changed}",
        f"Made: {time.strftime('%Y-%m-%d %H:%M %Z')}",
        marker(scene.ID),
        "",
        "Made by a script on a real account (#1793). The tokens it made were revoked after the take.",
        "",
        "What it says:",
        *lines,
    ])
    return {"title": title[:100], "description": description[:4900], "categoryId": SCIENCE_AND_TECHNOLOGY,
            "tags": ["Agents", "integration", getattr(scene, "INTEGRATION", scene.ID)]}


def upload(scene, mp4):
    """Uploads `mp4`, puts it first in the playlist, and replaces older takes of the scene."""
    try:
        yt = YouTube()
    except NotSignedIn as why:
        log(f"not uploaded, {mp4} is kept: {why}")
        return None
    playlist = yt.playlist()
    older = []
    for item in yt.pages("playlistItems", {"part": "snippet", "playlistId": playlist, "maxResults": 50}):
        if marker(scene.ID) in item["snippet"].get("description", ""):
            older.append((item["id"], item["snippet"]["resourceId"]["videoId"]))
    log(f"uploading {mp4.name} ({mp4.stat().st_size // 1_000_000} MB), private")
    video = yt.upload(mp4, describe(scene))
    yt.call("POST", "playlistItems", {"part": "snippet"}, {"snippet": {
        "playlistId": playlist, "position": 0, "resourceId": {"kind": "youtube#video", "videoId": video}}})
    for item, old in older:
        yt.call("PUT", "videos", {"part": "status"}, {"id": old, "status": {"privacyStatus": "private"}})
        yt.call("DELETE", "playlistItems", {"id": item})
        log(f"the older take {old} is private and out of the playlist (not deleted)")
    log(f"uploaded: https://youtu.be/{video}")
    mp4.unlink()
    mp4.with_suffix(".vtt").unlink(missing_ok=True)
    return video


def main():
    if sys.argv[1:] == ["--sign-in"]:
        return sign_in()
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
