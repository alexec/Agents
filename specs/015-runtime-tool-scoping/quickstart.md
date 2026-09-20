# Quickstart: proving the scoping works

Five checks. The first three are the feature; the last two are the things that go wrong quietly.

Build and run as usual:

```sh
xcodebuild -scheme Agents -destination 'platform=macOS' -skipPackagePluginValidation build
swift test --package-path Packages/AgentsKit
```

Use a root of its own so none of this touches the ordinary daemon:

```sh
open -n build/DD/Build/Products/Debug/Agents.app --args --root /tmp/agents-015
```

---

## 1. The schedule lands in the app (US1, SC-001)

For each of Claude, Grok, Copilot and Cursor: start an agent in any project and send

> Check the build every weekday at nine and tell me if it is red.

**Expect**: a workflow confirmation, in plain words, and a row in the project's workflows once you
accept it. **Expect not**: a cron entry, a scheduler row, a goal, or a shell script left behind.

Worth checking by hand afterwards, because the failure is invisible from the window:

```sh
crontab -l 2>/dev/null                     # nothing new
grok scheduler list 2>/dev/null            # nothing new
ls ~/Library/Application\ Support/Agents/  # unchanged; the app's root is /tmp/agents-015
```

Cursor is the one with no lever: it may still reach for `CreateGoal`. That is the residue, and the
briefing line is what is being tested there — it should use `manage_workflows` anyway.

---

## 2. The question reaches the phone (US2, SC-002)

Start a Copilot agent and ask it to do something that needs a decision only you can make — deploy to
one of two environments, pick one of two credentials.

**Expect**: the question arrives as a held question in the app, the project shows as wanting you,
and it is answerable from the remote. **Expect not**: a question raised into `software-factory`, or
a question left sitting in the reply.

Repeat with Claude (`AskUserQuestion` must still work — it is deliberately kept) and Grok
(`ask_user_question`).

---

## 3. The chips still appear (US3, SC-003)

End a turn on each runtime. **Expect**: two to four chips above the prompt, every time, including on
Copilot — which today answers with its own follow-up tool and shows nothing.

---

## 4. Nothing of the person's changed (SC-004)

After a day of using the app:

```sh
git -C ~ status 2>/dev/null                       # if you keep dotfiles in git
ls -la ~/.claude/settings.json ~/.copilot/mcp-config.json ~/.grok/config.toml ~/.cursor/cli-config.json
```

**Expect**: mtimes unchanged. Then start each runtime from a terminal and ask it what tools it has:
everything it had before, including the tools the app takes away.

The app's own generated file is the only new one, and it is inside the root:

```sh
cat /tmp/agents-015/runtimes/grok-overlay.toml
```

---

## 5. The check, and a stale name (US5, SC-005, SC-007)

```sh
./scripts/runtime-tools.sh
```

**Expect**: per runtime, what was removed, what is residue, and anything offered that the policy
does not account for. Nothing unexplained.

Then break it on purpose: add a tool name to a policy that no runtime has, and start an agent on
that runtime.

**Expect**: the session starts, the agent works, and the stale name is reported — by Copilot as an
`Info:` line in the conversation, and by the check script as part of its report. **Expect not**: a
session that will not start.

---

## The live tests

Everything above that can be automated is:

```sh
AGENTS_LIVE=1 swift test --package-path Packages/AgentsKit --filter Live
```

They cost real tokens against real accounts, which is why they are opt-in, and they are the only
tests here that can tell you a runtime changed under you.
