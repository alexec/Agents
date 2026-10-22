#!/usr/bin/env python3
"""Walk the scratch window through its walk socket (#1172): it draws and presses itself.

    walk.py ROOT ping | windows [--all]           --all: minimised and hidden ones too, with identifiers
    walk.py ROOT minimize|close|back [--window N|TITLE]   a window minimised, closed or sent behind (#1454)
    walk.py ROOT shot OUT.png [--render] [--window N|TITLE] [--view CLASS]
    walk.py ROOT dock OUT.png                    the icon the app gives the Dock tile (#1317), and its badge
    walk.py ROOT tree [DEPTH] [--window …]       the accessibility tree, read in process
    walk.py ROOT find TEXT                       every element whose label holds TEXT
    walk.py ROOT press TEXT                      the innermost match that takes a press
    walk.py ROOT press --x X --y Y               what is at a point of the shot, for a control left out of the tree
    walk.py ROOT select TEXT                     a sidebar or list row
    walk.py ROOT unfold|fold TEXT                a sidebar project, a disclosure row
    walk.py ROOT set TEXT VALUE                  type VALUE into the field labelled TEXT
    walk.py ROOT scroll TEXT                     bring TEXT into view
    walk.py ROOT scroll [TEXT] --to top|bottom | --y N | --by N
    walk.py ROOT size WIDTH HEIGHT [--x X --y Y]  the window's frame (top left from the main screen's)
    walk.py ROOT menu Session "New Session"      a menu item, in place of its shortcut
    walk.py ROOT context TEXT [ITEM…]            TEXT's context menu (#1123): its items, or ITEM chosen
    walk.py ROOT click TEXT [--count 2]          a click on TEXT's middle, for a tap gesture
    walk.py ROOT click --x X --y Y               a click at a point of the shot
    walk.py ROOT key return|escape|right|pageup|end|a… [--mods cmd,shift]   a key to the window
    walk.py ROOT info TEXT                       the match and what is above it: class, actions
    walk.py ROOT views [DEPTH] | layers [DEPTH] --view CLASS[#N]   when a shot or press goes wrong
    walk.py ROOT wait TEXT [SECONDS]             until TEXT is on the window (exit 1 if not)
    walk.py ROOT gone TEXT [SECONDS]             until TEXT has left it

ROOT `remote` walks the Remote in the walk simulator (#1182; `remote.sh up` first): the same
verbs, less menu, size, fold, unfold and click; `key return|delete|escape|TEXT` types into
the field being typed in.

TEXT `=Send` is the whole label only; `#id` is an accessibility identifier. Add `--first` to
act on the first match rather than the innermost. Everything happens in the window's own
process: no window server, no AX server, no focus and no HID, so a locked screen does not
stop it and nothing reaches the person's own window.

The socket is in the walk's folder in the window's container; ROOT/walk.sock is a link to
it, made here, because a socket's path may hold 104 bytes and the container's is longer.
"""
import base64
import json
import os
import socket
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))


def locked():
    """The screen is locked: the window server will not capture the window."""
    out = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, text=True).stdout
    return "CGSSessionScreenIsLocked" in out


CONTAINER = os.path.expanduser(
    "~/Library/Containers/com.alexecollins.agents.store/Data/Library/Application Support/Agents/walks")


class Walk:
    def __init__(self, root, timeout=30):
        if root == "remote":
            target, link, where = remote_socket(), "/tmp/agents-walk-remote.sock", "the walk simulator"
        else:
            root = root.rstrip("/")
            name = os.path.basename(root)
            # Only a scratch root: the person's window has no --walk and no socket.
            if not name.startswith("run-") or not root.startswith("/tmp/"):
                raise SystemExit(f"walk.py walks a scratch root (/tmp/run-<slug>) or remote, not {root}")
            target = os.path.join(CONTAINER, name, "walk.sock")
            link = os.path.join(root, "walk.sock")
            where = root
        if os.path.realpath(link) != os.path.realpath(target):
            if os.path.lexists(link):
                os.unlink(link)
            os.symlink(target, link)
        deadline = time.time() + timeout
        while True:
            try:
                self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.sock.connect(link)
                break
            except OSError:
                self.sock.close()
                if time.time() > deadline:
                    raise SystemExit(f"no walk socket at {target}: is it running on {where} (a Debug build)?")
                time.sleep(0.2)
        self.file = self.sock.makefile("rb")

    def call(self, cmd, **args):
        self.sock.sendall((json.dumps({"cmd": cmd, **args}) + "\n").encode())
        line = self.file.readline()
        if not line:
            raise SystemExit("the window closed the walk socket")
        return json.loads(line)

    def shot(self, out, **args):
        reply = self.call("shot", **args)
        if reply.get("ok"):
            with open(out, "wb") as f:
                f.write(base64.b64decode(reply.pop("png")))
            reply["path"] = out
        return reply

    def wait(self, text, seconds=20, gone=False, **args):
        deadline = time.time() + seconds
        while True:
            found = self.call("find", text=text, **args).get("ok")
            if found != gone:
                return True
            if time.time() > deadline:
                return False
            time.sleep(0.25)


def remote_socket():
    """The Remote's socket, in its data container in the walk simulator (remote.sh)."""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "remote.sh")
    udid = subprocess.run([script, "udid"], capture_output=True, text=True, check=True).stdout.strip()
    found = subprocess.run(["xcrun", "simctl", "get_app_container", udid, "com.alexecollins.agents.remote", "data"],
                           capture_output=True, text=True)
    if found.returncode != 0:
        raise SystemExit("the Remote is not installed in the walk simulator: remote.sh up APP first")
    return os.path.join(found.stdout.strip(), "tmp", "walk.sock")


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    root, verb, rest = argv[1], argv[2], argv[3:]
    args = {}
    positional = []
    i = 0
    while i < len(rest):
        flag = rest[i]
        if flag in ("--window", "--to", "--x", "--y", "--by", "--view", "--count", "--mods"):
            value = rest[i + 1]
            key = flag[2:]
            if key == "window" and value.isdigit():
                value = int(value)
            elif key in ("x", "y", "by"):
                value = float(value)
            elif key == "count":
                value = int(value)
            elif key == "mods":
                key, value = "modifiers", value.split(",")
            args[key] = value
            i += 2
        elif flag in ("--first", "--render", "--all"):
            args[flag[2:]] = True
            i += 1
        else:
            positional.append(flag)
            i += 1

    walk = Walk(root)
    if verb == "shot":
        # Unlocked, the window server's picture is the true one: a window on screen keeps
        # its layers on the GPU, which the window's own render reads as black. Locked, the
        # window server gives nothing, and the window's own render is right (#1172).
        render = args.pop("render", False)
        if root != "remote" and not render and not locked() and "view" not in args and "window" not in args:
            if subprocess.run([os.path.join(HERE, "shot.sh"), root, positional[0]], capture_output=True).returncode == 0:
                print(positional[0])
                return 0
        reply = walk.shot(positional[0], **args)
        print(reply.get("path") or reply.get("error"))
        return 0 if reply.get("ok") else 1
    if verb == "dock":
        reply = walk.call("dock", **args)
        if reply.get("ok"):
            with open(positional[0], "wb") as f:
                f.write(base64.b64decode(reply.pop("png")))
            print(positional[0] + (f' badge {reply["badge"]}' if reply.get("badge") else ""))
        else:
            print(reply.get("error"))
        return 0 if reply.get("ok") else 1
    if verb in ("wait", "gone"):
        seconds = float(positional[1]) if len(positional) > 1 else 20
        ok = walk.wait(positional[0], seconds, gone=verb == "gone", **args)
        print(("there: " if verb == "wait" else "gone: ") + positional[0] if ok else f"timed out on {positional[0]}")
        return 0 if ok else 1
    if verb in ("tree", "views", "layers") and positional:
        args["depth"] = int(positional[0])
    elif verb == "set":
        args["text"], args["value"] = positional[0], positional[1]
    elif verb == "size":
        args["width"], args["height"] = float(positional[0]), float(positional[1])
    elif verb == "menu":
        args["path"] = positional
    elif verb == "context":
        args["text"], args["path"] = positional[0], positional[1:]
    elif verb == "key":
        args["key"] = positional[0]
    elif positional:
        args["text"] = positional[0]
    reply = walk.call(verb, **args)
    if "text" in reply and verb in ("tree", "views", "layers", "info"):
        print(reply["text"])
    elif "matches" in reply:
        print("\n".join(reply["matches"]) or "nothing matched")
    elif "windows" in reply:
        for w in reply["windows"]:
            f = w["frame"]
            state = "minimised " if w.get("minimised") else ("" if w.get("visible", True) else "hidden ")
            print(f'{w["index"]}\t{f["width"]}x{f["height"]}\t{state}{"sheet " if w["sheet"] else ""}{w["title"]}\t{w.get("identifier", "")}')
    else:
        print(reply.get("did") or reply.get("error") or json.dumps(reply))
    return 0 if reply.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
