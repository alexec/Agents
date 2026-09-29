#!/usr/bin/env python3
"""Recorded HTTP fixtures for 059's tests (tasks T005).

Builds a real git repository, `fixture-owner/fixture-skills`, holding the three fixture skills
under `skills/`, and writes what skills.sh and GitHub would answer about it:

  info-refs.txt           git's smart-HTTP ref list (HEAD, its symref, one branch)
  tree.json               GET /repos/fixture-owner/fixture-skills/git/trees/<commit>?recursive=1
  download-<skill>.json   skills.sh /api/download snapshot: text files only, as skills.sh leaves
                          out binaries (research R3)
  tarball.tar.gz          codeload's archive of the commit, top folder fixture-skills-<commit>/
  search-fixture.json     a skills.sh search answer naming the fixture skills, one non-GitHub
                          row and one known owner
  search-swiftui.json     a real skills.sh answer, trimmed to five rows (shape check only)
  rate-limited.json       api.github.com's 403 body when the anonymous limit is spent
  meta.json               the commit, for the tests

Everything here is produced by git and by the services' own shapes, not by the Swift under test.
Run from the repository root: python3 specs/059-marketplace/walk/make-http-fixtures.py
"""
import json, os, shutil, subprocess, sys, tempfile, urllib.request

ROOT = os.getcwd()
FIX = os.path.join(ROOT, "Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/catalog")
OUT = os.path.join(FIX, "http")
os.makedirs(OUT, exist_ok=True)

def git(*args, cwd):
    env = dict(os.environ, GIT_AUTHOR_DATE="2026-09-20T12:00:00Z", GIT_COMMITTER_DATE="2026-09-20T12:00:00Z",
               GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="fixture@example.com",
               GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="fixture@example.com")
    return subprocess.run(["git", "-c", "core.fsmonitor=false", "-c", "maintenance.auto=false", *args],
                          cwd=cwd, env=env, check=True, capture_output=True, timeout=30).stdout

work = tempfile.mkdtemp(prefix="059-fixture-")
repo = os.path.join(work, "fixture-skills")
os.makedirs(repo)
shutil.copytree(os.path.join(FIX, "skills"), os.path.join(repo, "skills"))
with open(os.path.join(repo, "README.md"), "w") as f:
    f.write("Fixture skills for 059.\n")
git("init", "-q", "-b", "main", cwd=repo)
git("add", "-A", cwd=repo)
git("commit", "-q", "-m", "fixture", cwd=repo)
commit = git("rev-parse", "HEAD", cwd=repo).decode().strip()

# info/refs, in pkt-line form, as github.com answers it.
def pkt(line: bytes) -> bytes:
    return b"%04x" % (len(line) + 4) + line
caps = b"multi_ack thin-pack side-band side-band-64k ofs-delta shallow no-progress include-tag symref=HEAD:refs/heads/main object-format=sha1 agent=git/github-fixture"
refs = pkt(b"# service=git-upload-pack\n") + b"0000" + pkt(commit.encode() + b" HEAD\x00" + caps + b"\n") \
     + pkt(commit.encode() + b" refs/heads/main\n") + b"0000"
open(os.path.join(OUT, "info-refs.txt"), "wb").write(refs)

# The recursive tree, in the REST API's shape.
entries = []
for line in git("ls-tree", "-r", "-t", "-l", commit, cwd=repo).decode().splitlines():
    meta, path = line.split("\t", 1)
    mode, typ, sha, size = meta.split()
    entry = {"path": path, "mode": mode, "type": typ, "sha": sha,
             "url": f"https://api.github.com/repos/fixture-owner/fixture-skills/git/{typ}s/{sha}"}
    if typ == "blob":
        entry["size"] = int(size)
    entries.append(entry)
root_tree = git("rev-parse", f"{commit}^{{tree}}", cwd=repo).decode().strip()
json.dump({"sha": root_tree, "url": f"https://api.github.com/repos/fixture-owner/fixture-skills/git/trees/{root_tree}",
           "tree": entries, "truncated": False}, open(os.path.join(OUT, "tree.json"), "w"), indent=2)

# skills.sh snapshots: text files only, contents as strings, as the real endpoint sends them.
for skill in ("plain", "mixed", "nested"):
    base = os.path.join(repo, "skills", skill)
    files = []
    for dirpath, _, names in os.walk(base):
        for name in names:
            full = os.path.join(dirpath, name)
            data = open(full, "rb").read()
            try:
                text = data.decode("utf-8")
            except UnicodeDecodeError:
                continue
            files.append({"path": os.path.relpath(full, base), "contents": text})
    files.sort(key=lambda f: f["path"])
    json.dump({"files": files, "hash": "not-used-by-the-app"}, open(os.path.join(OUT, f"download-{skill}.json"), "w"), indent=2)

# codeload's tarball of the commit.
tar = git("archive", "--format=tar.gz", f"--prefix=fixture-skills-{commit}/", commit, cwd=repo)
open(os.path.join(OUT, "tarball.tar.gz"), "wb").write(tar)

# Search answers.
json.dump({"query": "fixture", "searchType": "fuzzy", "skills": [
    {"id": "fixture-owner/fixture-skills/nested", "source": "fixture-owner/fixture-skills", "skillId": "nested", "name": "nested", "installs": 5120},
    {"id": "fixture-owner/fixture-skills/plain", "source": "fixture-owner/fixture-skills", "skillId": "plain", "name": "plain", "installs": 812},
    {"id": "notion/notion-skill", "source": "https://www.notion.so/.well-known/skills", "skillId": "notion-skill", "name": "Notion", "installs": 700},
    {"id": "Anthropics/skills/mixed", "source": "Anthropics/skills", "skillId": "mixed", "name": "mixed", "installs": 42},
], "count": 4}, open(os.path.join(OUT, "search-fixture.json"), "w"), indent=2)

try:
    real = json.load(urllib.request.urlopen("https://skills.sh/api/search?q=swiftui", timeout=15))
    real["skills"] = real["skills"][:5]
    real["count"] = len(real["skills"])
    json.dump(real, open(os.path.join(OUT, "search-swiftui.json"), "w"), indent=2)
except Exception as e:  # offline: keep whatever was recorded before
    print("search-swiftui.json not refreshed:", e, file=sys.stderr)

json.dump({"message": "API rate limit exceeded for 127.0.0.1. (But here's the good news: Authenticated requests get a higher rate limit. Check out the documentation for more details.)",
           "documentation_url": "https://docs.github.com/rest/overview/resources-in-the-rest-api#rate-limiting"},
          open(os.path.join(OUT, "rate-limited.json"), "w"), indent=2)

# A second commit, for updates (US3): nested's SKILL.md changes and a file is added; plain is
# untouched. Served as http/next/ once the stand-in is told to move on.
NEXT = os.path.join(OUT, "next")
os.makedirs(NEXT, exist_ok=True)
with open(os.path.join(repo, "skills/nested/SKILL.md"), "a") as f:
    f.write("\nAlso run scripts/lint.sh before committing.\n")
with open(os.path.join(repo, "skills/nested/references/y.md"), "w") as f:
    f.write("Reference y.\n")
env2 = dict(os.environ, GIT_AUTHOR_DATE="2026-09-24T12:00:00Z", GIT_COMMITTER_DATE="2026-09-24T12:00:00Z")
subprocess.run(["git", "-c", "core.fsmonitor=false", "add", "-A"], cwd=repo, check=True, timeout=30)
subprocess.run(["git", "-c", "core.fsmonitor=false", "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com",
                "commit", "-q", "-m", "nested: one more line"], cwd=repo, env=env2, check=True, timeout=30)
commit2 = git("rev-parse", "HEAD", cwd=repo).decode().strip()
refs2 = pkt(b"# service=git-upload-pack\n") + b"0000" + pkt(commit2.encode() + b" HEAD\x00" + caps + b"\n") \
      + pkt(commit2.encode() + b" refs/heads/main\n") + b"0000"
open(os.path.join(NEXT, "info-refs.txt"), "wb").write(refs2)
entries2 = []
for line in git("ls-tree", "-r", "-t", "-l", commit2, cwd=repo).decode().splitlines():
    meta, path = line.split("\t", 1)
    mode, typ, sha, size = meta.split()
    e = {"path": path, "mode": mode, "type": typ, "sha": sha}
    if typ == "blob":
        e["size"] = int(size)
    entries2.append(e)
json.dump({"sha": git("rev-parse", f"{commit2}^{{tree}}", cwd=repo).decode().strip(), "tree": entries2,
           "truncated": False}, open(os.path.join(NEXT, "tree.json"), "w"), indent=2)
# The files that changed, as raw would serve them at the new commit.
for rel in ("skills/nested/SKILL.md", "skills/nested/references/y.md"):
    dest = os.path.join(NEXT, "raw", rel)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    shutil.copy(os.path.join(repo, rel), dest)

json.dump({"owner": "fixture-owner", "repo": "fixture-skills", "commit": commit, "branch": "main", "next": commit2},
          open(os.path.join(OUT, "meta.json"), "w"), indent=2)
shutil.rmtree(work)
print(commit)
