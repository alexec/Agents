#!/usr/bin/env python3
"""The three advisory calls a release makes, and nothing else.

  advisory.py create < advisory.json     makes a draft advisory: summary, description,
                                         severity and vulnerabilities only
  advisory.py fork GHSA-xxxx-xxxx-xxxx   makes its private fork
  advisory.py fixed GHSA-xxxx-xxxx-xxxx <sha>
                                         adds "Fixed by <sha> on main." to its description,
                                         and sends only the description
  advisory.py --selftest                 checks the above against a stand-in gh

.claude/settings.json allows this script, not `gh api` on advisories: any other change
to an advisory stays Alex's. ADVISORY_GH names another gh.
"""

import json
import os
import re
import subprocess
import sys
import tempfile

REPO = "repos/alexec/Agents/security-advisories"
GHSA = re.compile(r"^GHSA(-[23456789cfghjmpqrvwx]{4}){3}$")
SHA = re.compile(r"^[0-9a-f]{7,40}$")
SEVERITIES = {"critical", "high", "medium", "low"}


class Refused(Exception):
    pass


def gh(*args, data=None):
    cmd = [os.environ.get("ADVISORY_GH", "gh"), "api", *args]
    if data is not None:
        cmd += ["--input", "-"]
    out = subprocess.run(cmd, input=None if data is None else json.dumps(data), capture_output=True, text=True)
    if out.returncode != 0:
        raise Refused(out.stderr.strip() or f"gh failed: {out.returncode}")
    return out.stdout


def ghsa(value):
    if not GHSA.match(value):
        raise Refused(f"not an advisory id: {value!r}")
    return value


def create(text):
    try:
        given = json.loads(text)
    except json.JSONDecodeError as e:
        raise Refused(f"the advisory is not JSON: {e}") from None
    if not isinstance(given, dict) or set(given) != {"summary", "description", "severity", "vulnerabilities"}:
        raise Refused("an advisory has summary, description, severity and vulnerabilities, and nothing else")
    if not all(isinstance(given[k], str) and given[k].strip() for k in ("summary", "description")):
        raise Refused("summary and description are text")
    if given["severity"] not in SEVERITIES:
        raise Refused(f"severity is one of {', '.join(sorted(SEVERITIES))}")
    vulns = given["vulnerabilities"]
    if not isinstance(vulns, list) or not vulns or any(
        not isinstance(v, dict) or set(v) != {"package"} or not isinstance(v["package"], dict)
        or set(v["package"]) != {"ecosystem", "name"} for v in vulns
    ):
        raise Refused('vulnerabilities are [{"package": {"ecosystem": …, "name": …}}] only')
    return gh("-X", "POST", REPO, "--jq", ".ghsa_id", data=given)


def fork(advisory):
    return gh("-X", "POST", f"{REPO}/{ghsa(advisory)}/forks", "--jq", ".full_name")


def fixed(advisory, sha):
    ghsa(advisory)
    if not SHA.match(sha):
        raise Refused(f"not a commit: {sha!r}")
    current = json.loads(gh(f"{REPO}/{advisory}"))
    description = (current.get("description") or "").rstrip()
    line = f"Fixed by {sha} on main."
    if line in description:
        return "already says so\n"
    return gh("-X", "PATCH", f"{REPO}/{advisory}", "--jq", ".state",
              data={"description": f"{description}\n\n{line}"})


def main(argv):
    if argv == ["create"]:
        out = create(sys.stdin.read())
    elif len(argv) == 2 and argv[0] == "fork":
        out = fork(argv[1])
    elif len(argv) == 3 and argv[0] == "fixed":
        out = fixed(argv[1], argv[2])
    elif argv == ["--selftest"]:
        return selftest()
    else:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    sys.stdout.write(out)
    return 0


def selftest():
    failed = []
    with tempfile.TemporaryDirectory() as work:
        log = os.path.join(work, "calls")
        fake = os.path.join(work, "gh")
        with open(fake, "w") as f:
            f.write(f"""#!/bin/sh
printf '%s\\n' "$*" >> {log}
case "$*" in *--input*) cat >> {log}; echo >> {log};; esac
case "$*" in "api repos/"*) echo '{{"description": "Found.", "state": "draft"}}';; *) echo ok;; esac
""")
        os.chmod(fake, 0o700)
        os.environ["ADVISORY_GH"] = fake

        def calls():
            if not os.path.exists(log):
                return ""
            with open(log) as f:
                text = f.read()
            os.remove(log)
            return text

        def expect(name, ok, f, *args):
            try:
                f(*args)
                if not ok:
                    failed.append(f"{name}: not refused")
            except Refused:
                if ok:
                    failed.append(f"{name}: refused")

        good = {"summary": "S1: a title", "description": "Found.", "severity": "medium",
                "vulnerabilities": [{"package": {"ecosystem": "swift", "name": "Agents"}}]}
        expect("create", True, create, json.dumps(good))
        if f"-X POST {REPO} --jq .ghsa_id --input -" not in calls():
            failed.append("create: wrong call")
        for extra in ({"state": "published"}, {"credits": [{"login": "someone", "type": "reporter"}]},
                      {"collaborating_users": ["someone"]}, {"start_private_fork": True}):
            expect(f"create with {list(extra)[0]}", False, create, json.dumps(good | extra))
        expect("create with no summary", False, create, json.dumps({k: v for k, v in good.items() if k != "summary"}))
        expect("create with a severity", False, create, json.dumps(good | {"severity": "none"}))
        expect("fork", True, fork, "GHSA-fr4m-fq7w-g52q")
        if f"-X POST {REPO}/GHSA-fr4m-fq7w-g52q/forks" not in calls():
            failed.append("fork: wrong call")
        for bad in ("GHSA-fr4m-fq7w-g52q/cve", "GHSA-fr4m-fq7w-g52q -f state=published", "../x"):
            expect(f"fork {bad}", False, fork, bad)
        expect("fixed", True, fixed, "GHSA-fr4m-fq7w-g52q", "c09e91f1")
        sent = calls()
        if f"-X PATCH {REPO}/GHSA-fr4m-fq7w-g52q --jq .state --input -" not in sent or \
                '{"description": "Found.\\n\\nFixed by c09e91f1 on main."}' not in sent:
            failed.append(f"fixed: wrong call: {sent}")
        expect("fixed with a word for a sha", False, fixed, "GHSA-fr4m-fq7w-g52q", "main -f state=published")
        calls()
    for f in failed:
        print(f"advisory.py selftest: {f}", file=sys.stderr)
    if not failed:
        print("advisory.py selftest: ok")
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except Refused as e:
        print(f"advisory.py: {e}", file=sys.stderr)
        sys.exit(1)
