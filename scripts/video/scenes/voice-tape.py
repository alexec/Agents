"""Voice mode's tape (#4854): not a docs video, but the take that proves the sound. Voice mode
turns on, a prompt is heard (faked by the walk), and the reply is spoken; the MP4's track has
the spoken reply and voice mode's sounds at their places, from the walk's tape. No narration.
The sound test (#4855) checks this take."""
GROUP = "usage"
LAYOUT = "mac"
TITLE = "Voice mode's tape"

LINES = {}

PROMPT = "Reply with exactly: Ready when you are."
HEARD = "Say hello in one short sentence, and nothing else."


def voice(v, **args):
    reply = v.walk.call("voice", **args)
    if not reply.get("ok"):
        raise RuntimeError(f"voice: {reply.get('error')}")
    return reply


def setup(v):
    folder = v.add_folder("hello", {"README.md": "# Hello\n"})
    agent = v.start(folder, PROMPT)
    v.wait_state(agent, states=("finished", "idle", "done"), timeout=300)
    v.tidy()
    v.unfold("hello")
    v.select_agent(agent)
    voice(v, enable=True, walk=True)
    v.sleep(1.0)


def run(v):
    v.tape()
    v.sleep(1.0)
    v.press("Voice mode")
    v.wait_until(lambda: voice(v)["phase"] == "listening", timeout=60, what="voice mode to listen")
    v.sleep(1.5)
    voice(v, heard=HEARD)
    v.wait_until(lambda: voice(v)["said"], timeout=240, what="the reply to be said")
    v.wait_until(lambda: voice(v)["phase"] == "listening", timeout=60, what="the reply to end")
    v.sleep(2.0)
    v.press("Voice mode")
    v.sleep(1.5)
