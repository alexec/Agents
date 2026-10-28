#!/usr/bin/env python3
"""Each App Store profile allows every entitlement its target asks for (#2781).

    scripts/check-store-profiles.py SECRET=path/to/profile [SECRET=path …]
    scripts/check-store-profiles.py --selftest   the table below matches project.yml (lint)

SECRET is the `release` environment's secret that holds the profile (PROFILE_UNIVERSAL_MAC,
PROFILE_REMOTE, PROFILE_REMOTE_NOTIFY or PROFILE_REMOTE_WIDGET); the path is the profile as
installed (the testflight job decodes each secret to one). The target's .entitlements file is
the one its Release configuration signs with in project.yml. A profile made before an
entitlement was added (v0.12.1: Sign in with Apple, #2507) fails here, naming the entitlement
and the secret, before an archive spends a tag on it. It never prints a profile's contents.

The sandbox's own keys (com.apple.security.*, apart from application-groups) are not in a
profile and are not checked. On macOS a team-prefixed app group needs no profile entry, so it
is checked only when the profile lists app groups. Needs macOS (`security cms`).
"""
import fnmatch
import plistlib
import subprocess
import sys

ENTITLEMENTS = {
    "PROFILE_UNIVERSAL_MAC": "App/Agents-Store.entitlements",
    "PROFILE_REMOTE": "Remote/Remote-AppStore.entitlements",
    "PROFILE_REMOTE_NOTIFY": "RemoteNotify/RemoteNotify.entitlements",
    "PROFILE_REMOTE_WIDGET": "RemoteWidget/RemoteWidget.entitlements",
}
# The profile each secret holds, as scripts/release-secrets.sh --store finds it by name.
PROFILES = {
    "PROFILE_UNIVERSAL_MAC": "Agents Universal Mac App Store",
    "PROFILE_REMOTE": "Agents Remote App Store",
    "PROFILE_REMOTE_NOTIFY": "Agents Remote Notify App Store",
    "PROFILE_REMOTE_WIDGET": "Agents Remote Widget App Store",
}
GROUPS = "com.apple.security.application-groups"


def values(v):
    return v if isinstance(v, list) else [v]


def allowed(want, have, prefix):
    """True when every value of `want` matches a value (or wildcard) of `have`."""
    if isinstance(want, bool):
        return bool(have) or not want
    patterns = [str(p) for p in values(have)]
    return all(
        any(fnmatch.fnmatchcase(str(w).replace("$(AppIdentifierPrefix)", prefix), p) for p in patterns)
        for w in values(want)
    )


def check(secret, path):
    """The problems with one profile, one line each."""
    if secret not in ENTITLEMENTS:
        return [f"{secret} is not one of {', '.join(ENTITLEMENTS)}"]
    decoded = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True)
    try:
        profile = plistlib.loads(decoded.stdout)
    except Exception:
        return [f"{secret} does not decode to a provisioning profile"]
    granted = profile.get("Entitlements", {})
    team = (profile.get("TeamIdentifier") or [""])[0]
    prefix = (profile.get("ApplicationIdentifierPrefix") or [team])[0] + "."
    mac = "OSX" in profile.get("Platform", [])
    source = ENTITLEMENTS[secret]
    with open(source, "rb") as f:
        wanted = plistlib.load(f)
    problems = []
    for key, want in sorted(wanted.items()):
        if key.startswith("com.apple.security.") and key != GROUPS:
            continue
        if key == GROUPS and mac and key not in granted:
            want = [g for g in values(want) if not str(g).startswith(f"{team}.")]
            if not want:
                continue
        if key not in granted:
            problems.append(f"{secret} ({profile.get('Name', '?')}) has no {key}, which {source} asks for")
        elif not allowed(want, granted[key], prefix):
            problems.append(f"{secret} ({profile.get('Name', '?')}) does not allow {key} as {source} asks for it")
    return problems


def selftest():
    """Each profile's target in project.yml signs its Release build with the file above."""
    import re
    text = open("project.yml").read()
    signs = {}
    # A target is a two-space key; its Release override comes after its base settings, so
    # the last CODE_SIGN_ENTITLEMENTS in the block is the one the archive signs with.
    for block in re.split(r"^  \w[\w-]*:\n", text, flags=re.M):
        profile = re.search(r"PROVISIONING_PROFILE_SPECIFIER: (.+)", block)
        files = re.findall(r"CODE_SIGN_ENTITLEMENTS: (\S+)", block)
        if profile and files:
            signs[profile.group(1).strip()] = files[-1]
    bad = [f"{secret}: project.yml signs \"{name}\" with {signs.get(name)}, not {ENTITLEMENTS[secret]}"
           for secret, name in PROFILES.items() if signs.get(name) != ENTITLEMENTS[secret]]
    for line in bad:
        print(f"BAD {line} (scripts/check-store-profiles.py)")
    if not bad:
        print("check-store-profiles.py's table matches project.yml.")
    return 1 if bad else 0


def main(args):
    if args == ["--selftest"]:
        return selftest()
    if not args or any("=" not in a for a in args):
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    problems = []
    for arg in args:
        secret, path = arg.split("=", 1)
        found = check(secret, path)
        problems += found
        if not found:
            print(f"{secret} allows every entitlement in {ENTITLEMENTS[secret]}.")
    for p in problems:
        print(f"::error::{p}. Make the profile again in the developer site, install it and run "
              "scripts/release-secrets.sh --store (docs/how-to/release-agents-host.md).")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
