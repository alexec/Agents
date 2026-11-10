# Plan: full autonomy, with no new bugs and an easy app

2026-11-09. Alex approved it the same day. The epic is #3905; its lead is the "Epic 3905: full autonomy" session.

## 1. The goal and how we measure it

**Goal.** An agent does every step that does not need Alex's judgement. Alex decides; Alex does not type codes, click permission pages or pay by hand.

**Measures** (a lead reads them each week):

| Measure | Now | Target |
|---|---|---|
| Open `alex-todo` issues | 22 | only decisions and real-account tests |
| Open bugs with no milestone | 15 | under 10, no `priority:high` older than 2 days |
| Flaky tests that fail CI | 3 (#4125, #3965, #3930) | 0 |
| Open PRs that wait on Alex (`needs-approval`) | 0 | each one answered in a day |

## 2. Where we are

Done: the AGENTS.md rule (#3913), the SMS and CAPTCHA spikes (#3906, #3907), the accounts registry (#3909, #3967), `generate_secret`, `make_secret`, `capture_secret` (#4000, #4007, #4028), the honest browser user agent (#4060), self-pairing with the web page (#4214), ruleset changes with no sudo (#4239), and the email MCP server (PR #1784).

Alex decided: money stays a form per charge (#3910). SMS codes stay Alex's step; TOTP only (#3914).

## 3. What still blocks autonomy

Most of the open items wait on **three roots**. Fix a root and several issues move.

| Root | Issues it blocks | The fix |
|---|---|---|
| **A. GitHub App permissions** | #4291 (Workflows), #4079 (Actions, Contents) | Alex sets the permissions once. Then an agent checks the token before a lane starts (#4079), and the bot's manifest asks for them (#3858 follow-up). |
| **B. Bot checks on the agents' browser** | #4272, #3908 (Microsoft), #3911 (Cloudflare), #4135 (live Paddle), #3415 | A headed Chromium in an off-screen window (#4272 step 2). No CAPTCHA services. |
| **C. Sign-up mail** | #3912, #1780, every sign-up code (#4135, #3908) | Read `agentloops@fastmail.com` by the email MCP server, Junk too. The server is merged, so #3912 can start now. |

Other open items:

- #4284: an App ID capability and its profiles by the App Store Connect API. No blocker.
- #4085: a software passkey in the browser tools. Waits for #3908.
- #4261 (bug): `make_machine` and `delete_machine` lose a yes that comes after the 45 s form hold. An agent that waits for Alex then fails. This is an autonomy bug.

## 4. The work, in steps

Each line is one lane, one PR. A step starts when its blockers close.

**Step 1: now (no blockers)**

1. **#3912** sign-up mail by the email MCP server. Then remove the Mail rule (ask Alex first: it is Alex's Mail).
2. **#4272 step 2** headed Chromium for the sites that check.
3. **#4284** `scripts/apple-capability.sh`. Alex approves each run (it changes the Apple Developer account).
4. **#4079** the app checks a token can push before it gives it to a session, and says which permission is missing.
5. **#4261** keep the late yes for `make_machine` and `delete_machine`.

**Step 2: after step 1**

6. **#3908** Microsoft account with TOTP (after #4272 and #3912).
7. **#3911** Cloudflare token: the agent makes it on the page (after #4272). The GCP and Apple parts go by API.
8. **#4135** one live Paddle checkout (after #4272); the charge is a form, as #3910 says.
9. **#1780** payment of the Fastmail plan before 2026-12-07: an agent does it after #4272, on a form for the charge.

**Step 3: after step 2**

10. **#4085** software passkey for sites with no TOTP.
11. **New story: agents own their test accounts.** The real-account tests (#3410, #3412, #3413, #3416, #3494, #3495, #3739, #3782) wait for Alex because the accounts are Alex's. With mail, TOTP and the headed browser, an agent can make a test account for each one and walk it. Alex then tests only how it feels (#1782). I file it when step 2 is done, so that it starts from what worked.
12. **Rewrite the `## What Alex does` lists** again, so they hold only decisions and real-account checks. Close #3905 when its acceptance list is true.

## 5. Keep it free of bugs

- **Start the bug lane's lead (#4207).** No session runs it now. It takes the 15 open bugs in order.
- **Fix the flaky tests first** (#4125, #3965, #3930). Each re-run of CI costs a lane time and a place. This is autonomy work too: a lane that waits on a flaky check waits for nothing.
- **#4221**: the bot PR check after an approval. #3860 replaced `agent-bots` with a GitHub rule; the lane must check if the bug is still true, and close it or fix it.
- **Keep the rules that hold now:** `scripts/go-changed.sh` before a Go push, check `go-darwin` before auto-merge, walk what you ship, and a lane verifies only what it touched.

## 6. Keep it easy to use

- **UI changes go early**, as AGENTS.md says. The Secrets lanes (#4159, #4161) and the one Mac app (#4224) are UI; they keep their places.
- **A new screen, control or layout waits for Alex** (#3474). Autonomy does not change this: it is Alex's judgement, not a manual step.
- **The polish and competitor lane (#4208)** has 3 open issues. Give it one lane when a place is free.
- **Needs you** (#3861) is the one place for every request to Alex. Each human step this plan removes leaves one less item there.

## 7. Places

The folder has 7 lanes and 6 open PRs. Proposed use:

| Lanes | Work |
|---|---|
| 2 | autonomy (#3905): step 1, items 1 to 5 |
| 1 | bug lane (#4207): flaky tests first |
| 3 | the running UI epics: Secrets (#4155), one Mac app (#4224) |
| 1 | polish and competitor (#4208), when free |

## 8. What only Alex can do (about 15 minutes)

These are one-time steps. They unblock root A and the Fastmail trial.

- [ ] GitHub App `agents-loops`: set **Actions**, **Contents** and **Pull requests** to Read and write (#4079).
- [ ] GitHub App `alexec-agents`: set **Workflows** to Read and write, and accept it (#4291).
- [ ] Decide: may an agent pay the Fastmail plan ($6 a month) by a form, once #4272 works (#1780)? Otherwise Alex pays it before 2026-12-07.

Decided: this plan lives in `specs/3905-full-autonomy/plan.md`, because the epic's plan is its sub-issues and this file only says the order and why. Alex can overrule.

mac: docs only, remote: docs only, web: docs only.
