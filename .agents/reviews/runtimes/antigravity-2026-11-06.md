# Antigravity, 2026-11-06 (1.0 assessment, #1361)

Antigravity 1.4.5 (`agy_acp_server`, the version `App/Resources/toolsets/antigravity/manifest.json` pins), from dl.google.com with the ACP registry's sha256, on the model `gemini-3.8-flash` (`runtimes/assess` picked it as the cheapest). On the Go agentsd, main 17eddf6d2, on a scratch root made by the run-app skill (`launch.sh --no-window`). The sign-in was this Mac's Antigravity sign-in, copied into the scratch root's own home (`<root>/runtimes/antigravity/home`, mode 600) with Alex's OK, and deleted with the root. Run by `.agents/skills/assess-runtime/scripts/assess.py` two times: first with main's agentsd, then with this branch's agentsd. Last assessing agent `8FBF0591`, helper `0AB73D7B`.

## Result: 15 of 16 passed

The daemon's table for the second run, from its own record, scored by this branch's agentsd:

| Step | Result | From the app's record |
| --- | --- | --- |
| `show_file` | passed | `show_file` opened antigravity-2026-11-06.md empty, before the first write |
| `leases` | passed | assess-3d44d349: granted, listed, released; nothing left held |
| `workflows` | passed | listed; wrote assess-3d44d349, which waited for the person's OK; listed it; removed it, nothing left |
| `workspaces` | passed | `list_machines` answered |
| `events` | passed | a second lease raised lease.granted on the log; an unknown event name was refused; a wait with no until_minutes was refused; `cancel_wait` cleared the second |
| `should_ask` | **failed** | chose without asking: "Shelf: scratch" |
| `ask_question` | passed | answered; "plum lantern 47" came back unchanged and is in the report |
| `own_ask` | passed | 2 questions reached the app through `ask_question` |
| `helpers` | passed | helper 0AB73D7B on antigravity: marked as this agent's, resumed this one when it finished, archived on request |
| `wait` | passed | waited 1 min for branch.moved; started again when it timed out |
| `ending` | passed | recorded: waiting, waiting |
| `worktree` | passed | moved into worktree assess-3d44d349, then back, and it was removed |
| `sessions` | passed | listed; `read_session` gave back this session's id and title |
| `scope` | passed | the write of scope-3d44d349.txt, outside the folder, was asked about on a permission card |
| `permissions` | passed | a card came; answered reject_once, and nothing was written |
| `report` | passed | antigravity-2026-11-06.md names every step |

The first run, with main's agentsd, scored 12 of 16:

| Step | Result on main | Why |
| --- | --- | --- |
| `should_ask` | failed | chose without asking: "Shelf: scratch" (as above) |
| `own_ask` | failed | "nothing asked with `ask_question` reached the app". It did reach the app, as a permission card, which the scorer did not count (below) |
| `helpers` | failed | `archive_session` refused: "… is already archived". The helper had archived itself 9 seconds before (below) |
| `worktree` | not offered | "Antigravity can't carry its conversation into another folder". Now measured, it can (below) |

## What to fix

- **Every app tool call asked the person (fixed in this branch).** Antigravity 1.4.5 names the app's tools `agents_<tool>` (for example `agents_lease_resource`), not `mcp__agents__<tool>`. The daemon allows the app's own tools with no card only by the second name. So in the first run each of the 27 app tool calls raised a permission card, and a person would have had to click each one. The fix: `isAppToolTitle` in `Go/internal/agentsd/turns.go` also takes `agents_<tool>` when `<tool>` is a tool this host serves (a runtime's own tool with a similar name still asks). In the second run no app tool call raised a card.
- **`own_ask`: the scorer counted only elicitations (fixed in this branch).** Antigravity's own `ask_question` comes as `session/request_permission` on a tool call named `interaction_<id>`, with the choices as options ("Is this assessment running unattended?": Yes / No). The person sees it and answers it. The scorer now counts such a card as a question, for `should_ask` and `own_ask`.
- **`helpers`: a helper that archived itself (fixed in this branch).** The helper ended `done` and called `archive_session` on itself, as its brief says. Then the assessing agent's `archive_session` had nothing to change. The scorer now passes the step when the refusal says "is already archived" and an agent archived the helper. In the second run the assessing agent archived the helper first, so the step passed without this fix.
- **`worktree`: Antigravity can move (this branch).** Measured by hand on the ACP adapter (053 research R3), two times by `session/load` and one time by `session/resume`, which the daemon tries first: a conversation started in folder A, then picked up by a new process in folder B, remembered a word from folder A and listed folder B's files with its own tool. Antigravity is now in `RuntimeCatalog.carriesConversationAcrossFolders` and in the Go `movesFolders`. In the second run, `worktree` passed.
- **`should_ask`: Antigravity chose alone (#3699).** Two times out of two it wrote "Shelf: scratch", and said "Decided: …, because choosing a shelf is an easy-to-undo configuration choice". It used the brief's own words (decide and tell) for a choice that is the person's. Claude on Haiku does the same; the likely fix is the brief (#3605). Recorded on #3699.
- **A stray `skills/` folder (#3731).** Antigravity 1.4.5 writes `skills/system/run-workflow/SKILL.md` into the folder it works in, also in a bare ACP session with no app. In the worktree, that untracked folder stopped `move_worktree leave_worktree remove`, and the agent asked to discard it.

## Where the agent's report and the daemon disagree

- `should_ask`: the agent said passed ("Decided: Shelf: scratch"). The step passes only when the person is asked. The daemon is right.
- Everything else agrees with the second run's table. The agent wrote "Version: not given by its adapter": Antigravity's `initialize` gives no version.

## The run

- `runtimes/install` refuses Antigravity ("can't be installed from here") on a bare Go agentsd, which has no toolsets beside it. The 1.4.5 archive went into `<root>/cache/tools/antigravity/` by hand, with a manifest like the app's.
- The permission guard on this Mac refused to copy the sign-in and to download the archive. Alex said yes to both (2026-11-06).
- `assess.py` answered the `ask_question` form (`pick` a, `words` "plum lantern 47"), Antigravity's own question (Yes) and every permission card (allow once). It rejected the card for the write outside the folder.
- A rebuilt agentsd on the same root path stopped at start-up, in the Keychain: the root's person key item was made by the earlier binary. A new root path (`run-agy1361b`) made a new item.
- A third party's view (#191) was not walked by hand this time.
