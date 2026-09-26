# Quickstart: proving 054 works

Everything here runs on a scratch home. The real home is never laid out by these steps.

## 1. Unit and integration tests

```sh
cd Packages/AgentsKit && swift test --filter 'PersonalDotAgents|PersonalLayout'
```

Expected: every acceptance scenario in [spec.md](spec.md) US1–US4 passes against a temporary
home. `PersonalLayoutTests` also proves a scratch root with no `AGENTS_PERSONAL_HOME` changes
nothing in `$HOME` (SC-006) and that a reconcile over 100 skills takes under 50 ms (SC-005).

## 2. The runtimes see it: rerun the probe against the app's own layout

```sh
specs/054-user-dotagents/probe/run.sh setup
# lay out the scratch home with the built code, not by hand:
AGENTS_PERSONAL_HOME=/tmp/dotagents-probe/home <built agentsd> --root /tmp/054-root --lay-out-home-and-exit
for r in claude codex grok cursor copilot; do specs/054-user-dotagents/probe/run.sh $r; done
specs/054-user-dotagents/probe/run.sh clean
```

(`--lay-out-home-and-exit` is a test hook the tasks add. If it is not wanted, start the scratch
daemon and let it reconcile at start.)

Expected, as in research R1 pass 3: HERON-7 x1 for all five; OSPREY-3 x1 for all but Cursor.
`clean` removes the borrowed sign-ins.

## 3. Through the app itself (ACP, not the CLIs)

With the run-app skill, launch a scratch copy with `AGENTS_PERSONAL_HOME` set to the probe home
(and the probe's sign-in borrowing in the daemon's environment). Start one agent per installed
runtime in a scratch project and send the probe prompt from `probe/ask.txt`. Expected: the same
answers as step 2. This is what confirms the Claude ACP adapter loads user settings (R1 Limits).

## 4. Adoption and clashes

On the probe home, before laying out:

```sh
H=/tmp/dotagents-probe/home
mkdir -p $H/.claude/skills/mine $H/.claude/skills/heron-probe $H/.claude/skills/synced
echo x > $H/.claude/skills/mine/SKILL.md; echo y > $H/.claude/skills/heron-probe/SKILL.md
touch $H/.claude/skills/synced/.bucket-test
```

Lay out. Expected: `mine` moved to `~/.agents/skills/mine` and linked back; `heron-probe` (a
clash) left as a real folder in both places; `synced` untouched. Delete the `mine` link and lay
out again: it is not put back. Remove `~/.agents/skills/mine`: the record entry is dropped.

## 5. Settings ▸ Agents

On the scratch copy from step 3, open Settings ▸ Agents and screenshot it. Expected: "Your
skills" matches the approved wireframe. `heron-probe` is listed with its runtimes and the clash
named, and Reveal in Finder opens the skill's folder. On a scratch root without
`AGENTS_PERSONAL_HOME`, the section says the layout is off for this copy.
