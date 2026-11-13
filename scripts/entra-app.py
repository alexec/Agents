#!/usr/bin/env python3
"""Make (or find) the Entra app "Agents" for Azure DevOps's sign-in (#3921, #4873).

    scripts/entra-app.py [--tenant <id or domain>] [--name Agents] [--code-file <path>]

It signs in to Microsoft Graph with the device flow of Microsoft Graph Command Line Tools,
Microsoft's own public client for scripts, so no app is needed to make the app. The user
code goes to --code-file (mode 600, default ~/.agents/scratch/entra-device-code), never to
the output: an agent types it on https://microsoft.com/devicelogin in the agents' real Chrome
(`chrome-profile-microsoft`) with `cdp.mjs keys … env:…`, and signs in there.

Then it finds the app by its name, or makes it, and sets what the sign-in needs:
- signInAudience AzureADMultipleOrgs: any work or school account;
- isFallbackPublicClient: "Allow public client flows", so the device flow needs no secret;
- the delegated permission Azure DevOps user_impersonation.
It prints the app's client id (appId), which is public: it goes into
Go/internal/connections/azuredevops.go as AzureDevOpsClientID. It makes no secret.
"""

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# Microsoft Graph Command Line Tools: a public client of Microsoft's, made for scripts.
GRAPH_CLI = "14d82eec-204b-4c2f-b7e8-296a70dab67e"
GRAPH = "https://graph.microsoft.com/v1.0"
LOGIN = "https://login.microsoftonline.com/"
# Azure DevOps's fixed application id, and its user_impersonation scope.
AZURE_DEVOPS = "499b84ac-1321-427f-aa17-267ca6975798"
USER_IMPERSONATION = "ee69721e-6c3a-468f-a9ec-302d16a4c599"


def post_form(url, fields):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode())
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return json.load(e)


def graph(token, method, path, body=None):
    req = urllib.request.Request(GRAPH + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        sys.exit(f"Graph {method} {path}: {e.code} {e.read().decode(errors='replace')[:400]}")


def sign_in(tenant, code_file):
    base = LOGIN + urllib.parse.quote(tenant) + "/oauth2/v2.0/"
    start = post_form(base + "devicecode", {"client_id": GRAPH_CLI, "scope": "Application.ReadWrite.All"})
    if "user_code" not in start:
        sys.exit("devicecode: " + start.get("error_description", json.dumps(start))[:400])
    os.makedirs(os.path.dirname(code_file), exist_ok=True)
    fd = os.open(code_file, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(start["user_code"])
    print(f"Sign in at {start['verification_uri']} with the code in {code_file}", flush=True)
    deadline = time.time() + int(start.get("expires_in", 900))
    wait = int(start.get("interval", 5))
    try:
        while time.time() < deadline:
            time.sleep(wait)
            got = post_form(base + "token", {"client_id": GRAPH_CLI, "device_code": start["device_code"],
                                             "grant_type": "urn:ietf:params:oauth:grant-type:device_code"})
            if "access_token" in got:
                return got["access_token"]
            err = got.get("error")
            if err == "slow_down":
                wait += 5
            elif err != "authorization_pending":
                sys.exit("token: " + got.get("error_description", err or "no answer")[:400])
        sys.exit("token: the code expired")
    finally:
        os.remove(code_file)


def main():
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--tenant", default="organizations", help="the tenant to make the app in (id or domain)")
    p.add_argument("--name", default="Agents")
    p.add_argument("--code-file", default=os.path.expanduser("~/.agents/scratch/entra-device-code"))
    a = p.parse_args()

    token = sign_in(a.tenant, a.code_file)
    want = {
        "displayName": a.name,
        "signInAudience": "AzureADMultipleOrgs",
        "isFallbackPublicClient": True,
        "publicClient": {"redirectUris": ["https://login.microsoftonline.com/common/oauth2/nativeclient"]},
        "requiredResourceAccess": [{"resourceAppId": AZURE_DEVOPS,
                                    "resourceAccess": [{"id": USER_IMPERSONATION, "type": "Scope"}]}],
    }
    name = a.name.replace("'", "''")
    found = graph(token, "GET", "/applications?$filter=" + urllib.parse.quote(f"displayName eq '{name}'"))["value"]
    if found:
        app = found[0]
        graph(token, "PATCH", "/applications/" + app["id"], want)
        print(f"Updated the app {a.name}.")
    else:
        app = graph(token, "POST", "/applications", want)
        print(f"Made the app {a.name}.")
    print("appId:", app["appId"])


if __name__ == "__main__":
    main()
