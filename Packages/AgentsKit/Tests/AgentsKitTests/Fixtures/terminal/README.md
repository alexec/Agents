# Terminal fixtures

Raw bytes exactly as a program wrote them to a pty. Captured on 2026-09-18 on macOS 27
with `script -q`, `TERM=xterm-256color`, 80 columns by 24 rows.

These exist for one test: feeding a stream one byte at a time must give the same screen
as feeding it in one chunk. A pty splits its output wherever it likes, so that property
is what makes `shell.attach` replay correct. See `ReplayTests.swift`.

| File | Program | What it covers |
|---|---|---|
| `vim.raw` | `vim -u NONE -c 'normal ihello world' -c 'q!'` | The alternate screen buffer entered and left (`ESC[?1049h` / `ESC[?1049l`), a scroll region, erase-in-display |
| `less.raw` | `less` over 200 numbered lines, paged forward then quit | The alternate screen held across a real session, paging, the status line |
| `top.raw` | `top -l 2 -n 5` | Bulk text with carriage returns and redraw, the closest of these to build output |
| `colours.raw` | A `bash` one-liner | SGR colour, absolute cursor addressing (`ESC[5;20H`), erase-to-end-of-line, `tput cup` |

Every capture begins with a few bytes of `script`'s own doing (the terminating keystrokes
it echoes). That is left in on purpose. The test compares one feeding against another, so
any bytes serve, and trimming them would make the fixture less like what a pty really
hands over.

**Do not regenerate these to make a test pass.** They are a record of what these programs
emitted on this machine on that day. A replay test failing means our handling changed, not
that the capture is stale. If a capture genuinely has to be replaced, say here which
program and which terminal size produced it, so a later failure can be read.
