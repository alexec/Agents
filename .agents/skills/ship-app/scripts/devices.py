#!/usr/bin/env python3
"""Choose the devices ship.sh installs the Remote on (#1310).

Reads the JSON of `xcrun devicectl list devices --json-output FILE` and prints one line
per device:

    install <udid> <name>: <why>
    skip <udid> <name>: <why>

devicectl does not always fill in hardwareProperties: on 2026-10-17 a locked iPhone came
with no `reality` (and some come with no hardwareProperties at all). So each fact is read
from the first place that has it: hardwareProperties, then properties.hardware,
deviceProperties, connectionProperties and properties.connection. A paired device that is
not a simulator is installed on unless a field says it is not an iPhone or iPad; a device
is never dropped without a line that says why.
"""
import json
import re
import sys

# The hardware UDID, as devicectl's potentialHostnames carry it: 00008130-001E4D403432001C.
HOSTNAME_UDID = re.compile(r"^([0-9A-F]{8}-[0-9A-F]{16})\.coredevice\.local$", re.I)


def first(*values):
    for v in values:
        if v not in (None, ""):
            return v
    return None


def udid_of(d):
    hw = d.get("hardwareProperties") or {}
    phw = (d.get("properties") or {}).get("hardware") or {}
    found = first(hw.get("udid"), phw.get("udid"))
    if found:
        return found
    for host in (d.get("connectionProperties") or {}).get("potentialHostnames") or []:
        m = HOSTNAME_UDID.match(host)
        if m:
            return m.group(1)
    # devicectl takes its own identifier for --device too.
    return d.get("identifier")


def decide(d):
    """(install, udid, name, why) for one device of devicectl's list."""
    hw = d.get("hardwareProperties") or {}
    props = d.get("properties") or {}
    phw = props.get("hardware") or {}
    dev = d.get("deviceProperties") or {}
    conn = d.get("connectionProperties") or {}
    pconn = props.get("connection") or {}
    pstate = props.get("state") or {}

    udid = udid_of(d) or "?"
    name = first(dev.get("name"), pstate.get("name"), "unnamed")
    reality = first(hw.get("reality"), phw.get("reality"))
    platform = first(hw.get("platform"), phw.get("platform"))
    kind = first(hw.get("deviceType"), phw.get("deviceType"))
    product = first(hw.get("productType"), phw.get("productType")) or ""
    pairing = first(conn.get("pairingState"), pconn.get("pairingState"))
    visibility = first(d.get("visibilityClass"), pstate.get("visibilityClass"))
    transport = first(conn.get("transportType"), pconn.get("transportType"))

    if (reality == "simulated" or visibility == "simulators"
            or "CoreSimulator" in (dev.get("provider") or "") or transport == "sameMachine"):
        return False, udid, name, "a simulator"
    if pairing != "paired":
        return False, udid, name, f"not paired (pairingState {pairing or 'not given'})"
    if udid == "?":
        return False, udid, name, "devicectl gave no UDID or identifier"

    if not kind and product:
        kind = re.match(r"[A-Za-z]*", product).group(0) or None
    if platform and platform != "iOS":
        return False, udid, name, f"a {platform} device, not an iPhone or iPad"
    if kind and kind not in ("iPhone", "iPad"):
        return False, udid, name, f"a {kind}, not an iPhone or iPad"

    gaps = []
    if not hw and not phw:
        gaps.append("no hardware details")
    else:
        if not reality:
            gaps.append("no reality")
        if not platform:
            gaps.append("no platform")
    if gaps:
        return True, udid, name, f"paired, not a simulator; devicectl gave {', '.join(gaps)} (locked?)"
    return True, udid, name, f"paired {kind or platform}"


def choose(listing):
    devices = ((listing or {}).get("result") or {}).get("devices") or []
    return [decide(d) for d in devices]


def main(argv):
    if len(argv) != 2:
        print("usage: devices.py DEVICES.json", file=sys.stderr)
        return 2
    try:
        with open(argv[1]) as f:
            listing = json.load(f)
    except (OSError, ValueError) as e:
        print(f"cannot read the device list {argv[1]}: {e}", file=sys.stderr)
        return 1
    for install, udid, name, why in choose(listing):
        print(f"{'install' if install else 'skip'} {udid} {name}: {why}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
