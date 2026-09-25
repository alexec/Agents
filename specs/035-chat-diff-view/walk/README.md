# 035 walk, 2026-09-25

Quickstart §4 run end to end on the build of `074c98e` (the branch with main merged in), on a
scratch root. The agents were real: Claude in a git repository, and Grok in a folder without git.

| Step | What happened | Shot |
|------|---------------|------|
| 1 | The list, grouped by folder. The shared-folder line is above it. `a.txt` is marked "changed since" (the shell's append), `notes.md` is new, and `shell.txt` is "in the folder". | `1-list.png` |
| 2 | `notes.md` Whole file: both lines marked added, with numbers. | `2-whole.png` |
| 3 | With the list open, a second prompt had Claude edit `notes.md` again. The row went to 2 edits and +2 by itself, and the list didn't move. | `3-updated.png` |
| 4 | "Show in Changes" under that edit in the chat opened the pane at `notes.md`, with both edits in order. | `4-from-chat.png` |
| 5 | Open in Files took the Files pane to `notes.md`. | `5-open-in-files.png` |
| 6 | Grok in a folder without git, having changed nothing: "Nothing to show", with both reasons. | `6-no-git-no-reports.png` |
| 7 | 200 files: timed by `ChangesTests.twoHundredFilesAreQuickToList` (see quickstart §4). | — |

**Seen, and not 035's**: the chat draws a Claude edit twice, because Claude sends the diff twice
and the chat's merge keeps both copies. Each copy now carries its own "Show in Changes". Both
links go to the same place.
