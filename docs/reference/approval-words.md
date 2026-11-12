# Approval words

Every approval that a person gives an agent uses the same words (#4263): on the Mac window,
the Remote, the web page, in notifications, and in agentsd's replies to the agent.

| Answer | Word | Wire option id |
|---|---|---|
| This use only | **Approve** | `once` |
| Until the session ends | **Approve for This Session** | `session` |
| From now on (the card states the scope) | **Always Approve** | `always` |
| For a time | **Approve for 1 Hour** | `hour` |
| No | **Deny** | `deny` |

## Where they show

- **A secret's use** and **an account's use** (Needs you rows, their banners and menus):
  Approve, Approve for This Session, Always Approve and Deny. A terminal's
  `agents-secret NAME` has Approve, Approve for 1 Hour and Deny.
- **A file write the app asks about for the agent** (the edit card): Approve or Deny.
- **A deploy** in Review: Approve or Deny.
- **A change to a folder's policy file**: Approve, Keep <old value> or Show Change.
- **A workflow that waits for this machine**: Approve or Deny.
- **A machine that asks for this Mac's git access or sign-in**: Approve or Deny.
- **Join, budget and policy requests** on the web console: Approve or Deny.
- **The permission requests setting** for Cursor, Grok and OpenCode: **Request cards** or
  **Always Approve**.

## The rule

- A new approval card uses only these words.
- The wire's option ids (`once`, `session`, `always`, `hour`, `deny`) and setting values
  (`yes-to-all`) do not change; only the words do.
- A card that is not a permission keeps its own words: **Keep** and **Undo** on a file
  change, **Archive** and **Keep Session** on an archive.
- A runtime's own permission options (such as Claude's) show the words the runtime sends:
  they often state a scope, such as a command, that these words do not.
- A policy value (a connector tool's or custom servers' **Allow**, **Ask**, **Deny**) is a
  setting, not an answer.

`scripts/check-approval-words.py`, one of `scripts/lint.sh`'s text checks, fails on an old
word (Allow Once, Allow for This Session, Allow Always, Allow for 1 Hour, Refuse, Reject,
Yes to all) as a whole string or a button's text in a client's copy or in agentsd.
