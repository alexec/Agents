#!/usr/bin/env python3
"""Put the scratch window where the person can tell it from their own window.

    place.py ROOT APP_PID [WHERE]
    place.py --selftest

WHERE is a quarter of the screen the window is on (top-left, top-right, bottom-left,
bottom-right), or X,Y,W,H in points from the main screen's top left, or `none` to leave
the window where it opened. With no WHERE, $AGENTS_SCRATCH_PLACE, else bottom-right.

The window is never smaller than 70% of the laptop's own screen (the built-in display,
or a 1512x945 one when none is connected), so on the laptop a quarter grows to a usable
size. It is never larger than the screen, and it stays on that screen.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CORNERS = ("top-left", "top-right", "bottom-left", "bottom-right")
DEFAULT = "bottom-right"
LAPTOP = (1512, 945)   # a 14-inch MacBook Pro's visible frame, for when no built-in display is on
SMALLEST = 0.7


def frame(screens, where):
    """(x, y, w, h) for WHERE on screens: (x, y, w, h, builtin, holds_window) each."""
    if not screens:
        raise ValueError("no screens")
    builtin = next((s for s in screens if s[4]), None)
    laptop = (builtin[2], builtin[3]) if builtin else LAPTOP
    min_w, min_h = laptop[0] * SMALLEST, laptop[1] * SMALLEST

    if where in CORNERS:
        screen = next((s for s in screens if s[5]), screens[0])
        sx, sy, sw, sh = screen[:4]
        w, h = sw / 2, sh / 2
        x, y = None, None
    else:
        try:
            x, y, w, h = (float(v) for v in where.split(","))
        except ValueError:
            raise ValueError(f"WHERE is one of {', '.join(CORNERS)}, X,Y,W,H or none, not {where!r}") from None
        # The screen that holds the asked top left, else the window's own.
        screen = next((s for s in screens if s[0] <= x < s[0] + s[2] and s[1] <= y < s[1] + s[3]), None) \
            or next((s for s in screens if s[5]), screens[0])
        sx, sy, sw, sh = screen[:4]

    w = round(min(max(w, min_w), sw))
    h = round(min(max(h, min_h), sh))
    if x is None:
        x = sx if where.endswith("left") else sx + sw - w
        y = sy if where.startswith("top") else sy + sh - h
    x = min(max(x, sx), sx + sw - w)
    y = min(max(y, sy), sy + sh - h)
    return round(x), round(y), round(w), round(h)


def screens_of(root, pid):
    ui = os.path.join(root, ".ui")
    command = [ui] if os.access(ui, os.X_OK) else ["swift", os.path.join(HERE, "ui.swift")]
    out = subprocess.run(command + ["screens", str(pid)], capture_output=True, text=True, check=True).stdout
    return [tuple(int(v) for v in line.split()) for line in out.splitlines() if line.strip()]


def selftest():
    big = (0, 30, 2560, 1410, 0, 1)
    laptop = (2560, 30, 1512, 945, 1, 0)
    on_laptop = (laptop[:5] + (1,), big[:5] + (0,))
    cases = [
        # The big screen alone: a quarter is larger than 70% of a laptop.
        (([big], "bottom-right"), (1280, 735, 1280, 705)),
        (([big], "top-left"), (0, 30, 1280, 705)),
        # The window on the laptop: 70% of it, still in the corner.
        ((on_laptop, "bottom-right"), (2560 + 1512 - 1058, 30 + 945 - 662, 1058, 662)),
        ((on_laptop, "top-left"), (2560, 30, 1058, 662)),
        # The laptop is there but the window is on the big screen: the big screen's quarter.
        (([big, laptop], "bottom-right"), (1280, 735, 1280, 705)),
        # X,Y,W,H: too small grows, off the edge comes back, too big shrinks.
        (([big], "100,100,200,200"), (100, 100, 1058, 662)),
        (([big], "2500,1400,1200,800"), (1360, 640, 1200, 800)),
        (([big], "-50,0,9000,9000"), (0, 30, 2560, 1410)),
        # A top left on the laptop places it on the laptop, even with the window elsewhere.
        (([big, laptop], "3000,100,1200,800"), (2872, 100, 1200, 800)),
    ]
    failed = 0
    for (screens, where), want in cases:
        got = frame(screens, where)
        if got != want:
            print(f"selftest: {where} on {screens}: got {got}, want {want}", file=sys.stderr)
            failed += 1
    for bad in ("middle", "1,2,3"):
        try:
            frame([big], bad)
            print(f"selftest: {bad!r} was taken", file=sys.stderr)
            failed += 1
        except ValueError:
            pass
    print("selftest: ok" if not failed else f"selftest: {failed} failed")
    return 1 if failed else 0


def main(argv):
    if len(argv) == 2 and argv[1] == "--selftest":
        return selftest()
    if len(argv) not in (3, 4):
        print(__doc__)
        return 2
    root, pid = argv[1], argv[2]
    where = (argv[3] if len(argv) == 4 else os.environ.get("AGENTS_SCRATCH_PLACE") or DEFAULT).strip().lower()
    if where == "none":
        return 0
    try:
        x, y, w, h = frame(screens_of(root, pid), where)
    except ValueError as error:
        print(f"place.py: {error}", file=sys.stderr)
        return 2
    sys.path.insert(0, HERE)
    from walk import Walk   # noqa: E402 - only now: --selftest needs no window
    reply = Walk(root, timeout=10).call("size", width=w, height=h, x=x, y=y)
    if not reply.get("ok"):
        print(f"place.py: {reply.get('error') or reply}", file=sys.stderr)
        return 1
    print(f"placed {where} at {x},{y} {w}x{h}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
