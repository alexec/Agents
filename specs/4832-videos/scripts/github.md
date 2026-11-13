# The GitHub video: agents do Sam's GitHub work (#5075)

Status: draft for Alex to approve, 2026-11-12. Epic #4832. No take is made until Alex
approves this text (Alex: videos cost much in review and rework).

Alex, 2026-11-12: "The one I want to do 1st would be. Using GitHub to do work. I think we
would need a narrative behind that."

## The story

Sam has a small Swift package, `weather`, on GitHub, with open issues. Sam gives one issue
to the agents with a label. Then Sam only watches, in Agents: an agent opens a pull
request, a check fails and another agent fixes it, Sam and CodeRabbit leave review comments
and a third agent answers them. Sam merges, and the pull request says what the work cost.
Sam's own steps are three: a label, a comment, a merge.

It is a story, not a tour: each line is one step of the work, and the window shows only
what that step needs.

- **Scene:** `github` (`scripts/video/scenes/github.py`), group `marketing`, layout `mac`,
  window 1360 × 820, title **"Agents do your GitHub work"**.
- **Length:** about 80 s after the time cuts, with the title card and the end card.
- **Voice:** Kokoro **Heart**, the directed form of #4964 (`voice.py`). `style="warm"` for
  the first and last lines, `calm` for the rest, `bright` for the two short "it worked"
  beats.
- **Scratch data only:** person Sam, the demo repository and account (see *What the take
  needs*), the scratch machine "Sam's Mac".

Decided: group **marketing**, because this is a story of what only Agents does (agents that
start on their own, on events) and it goes on www and *Why Agents*, not on one docs page.
A usage cut for `docs/how-to/use-github.md` can come later from the same scene. Alex can
overrule.

## The script

Each line starts at its marker. `fast(n)` is a span cut to `n` seconds. *What is said* is the
directed line, as it goes into `LINES` in the scene; the words alone are what Whisper checks.

| # | Marker | What is shown | What is said | Time |
|---|---|---|---|---|
| — | — | Title card: the logo, **Agents do your GitHub work**, "Loops". Fades into the window. | — | 3 s |
| 1 | `intro` | The window. Sidebar: the folder `weather`, its **Work** rows. **Work ▸ Issues** lists three open issues; #4 **Show the low in Celsius too** is first. | `<speak style="warm">Sam has work on GitHub.<break time="450ms"/>Today,<break time="150ms"/>agents do it,<break time="200ms"/>and Sam just watches.</speak>` | 6 s |
| 2 | `label` | Sam opens #4. In its **Labels** side section, the picker; Sam picks `agent`. The label shows on the issue in its GitHub colour. | `<speak style="calm">To hand an issue to an agent,<break time="200ms"/>Sam gives it the <emphasis>agent</emphasis> label.<break time="450ms"/>That's all Sam does.</speak>` | 6 s |
| 3 | `start` | `fast(2)` over the event's wait (up to 30 s). A new session **#4** appears under `weather` in the sidebar, **Working**, started by the workflow **Work an issue**. | `<speak style="calm">The <emphasis>Work an issue</emphasis> workflow sees the label,<break time="200ms"/>and starts an agent on a branch of its own.</speak>` | 6 s |
| 4 | `pr` | `fast(4)`: the session's steps fill in: it reads the issue, edits `Forecast.swift`, runs `swift test` (passes), pushes, opens the pull request. **Work ▸ Pull requests**: #5 **Show the low in Celsius too**, checks running. | `<speak style="calm">It reads the issue,<break time="150ms"/>makes the change,<break time="150ms"/>runs the tests,<break time="300ms"/>and opens a pull request.</speak>` | 7 s |
| 5 | `fail` | `fast(2)` over CI. The pull request's page, its checks: `test` green, `format` red. | `<speak style="calm">On GitHub,<break time="150ms"/>one check fails.<break time="450ms"/><prosody rate="94%">Sam doesn't need to step in.</prosody></speak>` | 5 s |
| 6 | `fix` | `fast(3)`: a second session starts, from **Fix failed checks**: it reads the failed job's log, runs the formatter, pushes. `fast(2)` over CI: `format` goes green. | `<speak style="calm"><emphasis>Fix failed checks</emphasis> starts another agent.<break time="300ms"/>It reads the log,<break time="150ms"/>fixes the cause,<break time="150ms"/>and pushes.</speak><speak style="bright">Green.</speak>` | 8 s |
| 7 | `review` | The pull request's **Review comments** tab: Sam's comment on a line, *Round the low to one decimal, please.* `fast(2)` over CodeRabbit's review: its block on **Conversation** says it reviewed the last commit, with one comment of its own. | `<speak style="calm">Sam leaves a review comment.<break time="350ms"/>When CodeRabbit finishes its review,<break time="150ms"/><emphasis>Address review comments</emphasis> picks up both.</speak>` | 8 s |
| 8 | `answer` | `fast(3)`: a third session fixes both comments and pushes. Each thread shows the agent's answer. Checks green. | `<speak style="calm">It fixes each one,<break time="150ms"/>answers in the thread,<break time="200ms"/>and pushes again.</speak>` | 6 s |
| 9 | `merge` | Sam presses **Merge** on the pull request's page; the app asks again; **Merge**. The page says **Merged**. | `<speak style="warm">Sam decides what merges.<break time="400ms"/>One click.</speak>` | 5 s |
| 10 | `cost` | The **Conversation** tab: the comment **What this cost**: sessions 3, tokens, agent time, wait time, failed CI rounds 1. On the pull request's **Work** page the same: the cost and **3 sessions**, each a link. | `<speak style="calm">And the pull request says what the work took:<break time="200ms"/>three agents,<break time="150ms"/>their tokens,<break time="150ms"/>and their time.</speak>` | 7 s |
| 11 | `end` | The folder's **Workflows** page: **Work an issue**, **Fix failed checks** and **Address review comments**, each **Enabled**. | `<speak style="warm"><prosody rate="90%">Label an issue.<break time="250ms"/>Review.<break time="250ms"/>Merge.<break time="450ms"/>Agents do the rest.</prosody></speak>` | 6 s |
| — | — | End card: the logo, **Loops**, "docs.agentloops.dev/how-to/use-github/". | — | 3 s |

About 131 words over about 70 s of lines, near 150 a minute with the pauses: the calm pace
Alex chose for U1.

## Is it true today?

Each claim checked against `docs/reference/feature-matrix.md` (Agents: ● for Pull requests,
CI checks, Starts agents from issues, Scheduled or triggered runs, Workflows as files),
`docs/reference/integrations.md` and `docs/how-to/use-github.md`, on 2026-11-12.

| Line | Claim | True today? |
|---|---|---|
| 2 | Sam labels the issue in Agents. | Yes. The Work page's Labels picker (`forge/label`) is tested on a real account (integrations, "The forge writes", alexec/agents-walk, 2026-11-04). |
| 3 | The label starts **Work an issue** "at once". | Yes, with a wait: tested on agents-walk #9 (2026-10-19). The host polls the github server's events every 30 s by default (`mcpPollDefault`; 10 s at the least), so the script says "sees the label", not "at once", and cuts the wait. |
| 4 | The agent opens the pull request. | Yes: `create_pull_request` opened agents-walk #10. **But the pull request's author is Sam's GitHub account, not the agent's.** The agents' bot (#3858) is built and tested only with a fake GitHub. The words say "opens a pull request", never "its own account". |
| 5–6 | **Fix failed checks** fixes a failed check. | Yes: tested on agents-walk #7 (the job log read, the fix pushed, the check green). |
| 7 | Sam's comment starts **Address review comments**. | **Not as said in the issue.** The workflow starts on `review.posted`, when **CodeRabbit** finishes a review, not on a person's comment. It then fixes "each open review comment, a person's or CodeRabbit's" (tested on agents-walk #8, 2026-10-19). So the script makes CodeRabbit's review the start, and Sam's comment one of the two it answers. The repository needs the CodeRabbit GitHub App. |
| 8 | It answers in each thread. | Yes for both (`coderabbit_reply`, a reply in Sam's thread), #8. On #8 the person's thread stayed open, as it should: the script does not say it resolves Sam's thread. |
| 9 | Sam merges from the page. | Yes: **Merge** on the pull request's page acts as the person, asks again, and agents cannot press it (`use-github.md`). |
| 10 | The pull request says what the work cost. | **Only when turned on, and not all of it is proved.** The cost comment is off unless the folder's `.agents/folder.json` says `prCostComment` (`tokens` or `cost`), and it is posted with the person's own `gh`. Tested on agents-walk #21 (2026-11-04); Alex's look at it as a person reads it is still open (#3412). On a Claude subscription the cost can be $0 (U1's window said $0), so the words say "tokens and time", and the take uses `cost` mode only when the figure is not $0. That the comment counts all three sessions (two started by workflows on events) is not proved: the take checks it, and if it says 1, line 10 shows the Work page's sessions instead and an issue is filed. |
| 11 | The three workflows are on the Workflows page. | Yes, off by default; the take turns them on in its set-up (`use-github.md`, "Let agents work the dev loop"). |
| all | Everything is shown in the Agents window. | Yes, by design: the recorder takes only the window (walk socket), so github.com is never in the picture. The Mac's diff sheet is not walked (a walk can't press inside it), so the script shows no diff on the Mac; line 4's edit is in the session's steps. |

## What the take needs

1. **A demo GitHub account and repository (Alex decides).** Every issue, pull request,
   label and comment shows the GitHub login of the person who is signed in, and the merge
   too. On alexec/agents-walk that is **alexec** in the frames, which the take's
   private-words check fails, and which a public video must not show. Recommended: a GitHub
   account of the agents' own, made with agentloops@fastmail.com (as the Loops Google
   account, #4837), named for Sam (for example `loops-sam`), with a public repository
   `weather`. It is a new outside account, so it is Alex's to approve (the sign-up skill
   does it). Free: a public repository, Actions minutes and CodeRabbit cost nothing.
2. **The repository's content**, made by the scene's set-up and pushed once:
   - the `weather` package of U1, with a second issue-sized change to make (#4: show the
     low in Celsius too) and two other open issues for the list;
   - a CI workflow with two jobs, `test` (`swift test`) and `format`
     (`swift format lint --strict`), so the agent's `swift test` passes and only CI finds
     the format. The demo folder's rules say nothing of formatting, so the first push fails
     `format` (the risk: the agent formats anyway; then the take makes the failing check
     with a file the agent does not touch, and an issue says so);
   - the labels `agent`, and CodeRabbit installed on the repository.
   - Before each take, the set-up closes the last take's pull request, deletes its branch,
     reopens #4 and takes `agent` off it.
3. **The GitHub sign-in on the scratch host:** the device flow of the `agents-loops` App,
   as the demo account. The take's set-up opens github.com/login/device in the agents' own
   Chrome profile; the first time, the demo account's password and its two-factor code
   (`scripts/totp.sh`, seed in `~/.agents/secrets/`) go in by `fill_secret`. The demo
   account installs `agents-loops` on `weather`. No step needs Alex's hands unless GitHub
   asks for a CAPTCHA at sign-up.
4. **The cost comment's `gh`:** the host posts it with the person's own `gh`. The scratch
   host's `gh` must be signed in as the demo account (`GH_CONFIG_DIR` in the scratch root),
   never Alex's.
5. **Sam's review comment:** posted by the scene through the API as the demo account, at
   the `review` marker, so the take does not wait on a person.
6. **Time cuts** (`v.fast`): the event poll (up to 30 s, three times), each CI run (about
   1 to 2 min on a macOS runner for `swift test`; the scene uses `ubuntu-latest` with the
   Swift image, about 1 min), CodeRabbit's review (about 2 to 5 min), and each agent's work
   (about 1 to 2 min). The wall time of one take is about 15 to 20 min, against U1's 2 min.
7. **Nothing that only Alex can do,** once the account is approved: no code from Alex's
   phone, no sign-in of Alex's.

## Its size

From U1's retro (`specs/4832-videos/spec.md`, section 2.4):

| Part | U1 took | This one, by estimate | Why |
|---|---|---|---|
| The demo account and repository | — | 1 h of a lane, 5 min of Alex's (the form) | a sign-up, a repository, CI, CodeRabbit, the reset script |
| The scene (`github.py`) and its first take | 1 h | 3 to 4 h of a lane | a new scene, three workflow sessions to wait on, the API comment, the cost check |
| Each take | 2 min, about 1 min recorded | 15 to 20 min, about 80 s recorded | real CI, CodeRabbit and three agents |
| The money of a take | a few cents (one Claude turn) | about $0.20 to $1 on the subscription (three agents on a small repository), $0 on GitHub and CodeRabbit | |
| Three takes (two fail on the checks, as U1's did) | about 1 h | about 1 h | |
| The upload | 45 min (the first; the tool is done now) | 10 min | `make.sh github --upload` is one step |
| Alex's review | about 10 min (a watch, a form) | about 10 min | |
| One rework (words, cadence, a cut) | about 2 h (with the voice samples) | about 1 to 1.5 h | the voice is chosen; a rework is the lines and one take |

**In all:** about 7 to 9 h of a lane, about 20 min of Alex's (the account's form, the watch,
one more watch after the rework), and under $5 of model use.

## Open questions

1. **The demo account (Alex):** a GitHub account of the agents' own for Sam (recommended), or
   alexec/agents-walk with alexec in the frames (private only, and the private-words check
   is told to let `alexec` through)?
2. **The cost line:** if the comment counts only one session, show the Work page's sessions
   instead (recommended), or wait for the fix?
