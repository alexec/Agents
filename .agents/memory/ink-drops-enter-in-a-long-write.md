---
name: ink-drops-enter-in-a-long-write
description: Claude's Ink prompts take a long write to their terminal as a paste and drop the Enter in it; send Enter in a write of its own (#5202)
metadata:
  type: project
---

`claude setup-token` (2.1.318) is an Ink app. When agentsd wrote a real code and Enter as one write (`code+"\r"`, 93 bytes), Claude showed the code (as stars) and dropped the Enter, so the sign-in waited at its prompt until the server's 15-minute limit. A short wrong code (27 bytes) with Enter in the same write was submitted, so a test with a fake code passed. Found on machine-28 on 2026-11-13 by typing Alex's real code into a recorded run; Enter sent alone then gave the token.

**Why:** this was "Cannot sign in to Claude" on every server (#5202). It looked like a client or network fault, because a fake-code test of the server passed.

**How to apply:** when you type into any Ink TUI through a pty, write the text, wait until it shows, then write `\r` alone. Test with input as long as the real input. A fake TUI in a test must drop an Enter that comes with other text, as `fakeClaudeTool` in `runtimesignin_test.go` does. See [[reach-a-codespace-agentsd-socket]].
