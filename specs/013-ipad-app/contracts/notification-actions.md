# Contract: the answerable notification

What arrives on a locked iPad when an agent is blocked, what its buttons mean, and what
happens when one is pressed. This is the only contract 013 adds; the transport underneath it
is 005's (`specs/005-mobile-remotes/contracts/mailbox.md`).

## The shape

```text
   ┌─────────────────────────────────────────────┐
   │  Agents                               now   │
   │  api · rename-refactor                      │   h1 · h2   assembled on the device
   │  Wants to run  git push --force             │   h3
   │                                             │
   │   [ Allow once ]  [ Always ]  [ Deny ]      │   the category's actions
   └─────────────────────────────────────────────┘
```

Three lines of ciphertext ride the push; the words are assembled on the iPad by the service
extension. The buttons are not in the push at all — they come from the `categoryIdentifier`,
which names a set of actions registered at launch.

## Why the buttons cannot come from the request

A `UNNotificationAction` is fixed at registration: a title, an identifier, a set of options,
inside a `UNNotificationCategory` handed to `setNotificationCategories(_:)` before anything
arrives. A `PermissionOption` is not fixed: its `optionID` is invented by the runtime per
request and its `name` is arbitrary text.

The bridge between them is `PermissionOption.Kind`, which is closed and small, and which every
runtime already maps into.

## The categories

Registered once, at app launch, on the iPad. Titles are ours, in the Mac's words.

| Category | When the request offers | Actions, in order |
|---|---|---|
| `perm.allowDeny` | allowOnce + rejectOnce | **Allow once** · **Deny** |
| `perm.allowAlwaysDeny` | allowOnce + allowAlways + rejectOnce | **Allow once** · **Always allow** · **Deny** |
| `perm.full` | all four kinds | **Allow once** · **Always allow** · **Deny** · **Never allow** |
| `perm.openOnly` | anything containing `.unknown`, or a form | *(no actions — opening is the only move)* |
| `agent.done` | an agent finished, or stopped on an error | *(no actions)* |

**`perm.openOnly` is the important row.** A request carrying an option this app cannot classify
gets no one-tap answer. The banner says there is something to look at and opening it shows the
question with the runtime's own wording (FR-010, FR-011). An option we do not understand is
skipped, not guessed — the rule this codebase already holds to, applied where guessing would
grant a permission.

## Action options

| Action | `authenticationRequired` | `destructive` | `foreground` |
|---|---|---|---|
| Allow once | **no** | no | no |
| Always allow | **yes** | no | no |
| Deny | no | yes | no |
| Never allow | **yes** | yes | no |

Allowing once is the one tap that may happen from a locked iPad; it affects exactly one tool
call. Anything that changes what happens to *future* requests requires the device to be
unlocked first — the system handles the unlock and then runs the action. None of them is
`foreground`: the app is launched in the background, which is what makes "answer without
opening the app" true rather than a figure of speech. See research §4 for how this sits with
005's FR-012.

## The option map, and where it lives

The action handler knows a kind was tapped. It needs the `optionID` for that kind, and the
`permissionID` to answer. Neither fits in the push (`desiredKeys` is three fields of about a
hundred characters, spent on the headline).

The service extension already runs before the banner is shown and already holds the device
key. So it writes what the handler will need into a **shared app group container**, keyed by
the notification's request identifier:

```json
{
  "permissionID": "…UUID…",
  "agentID": "…UUID…",
  "projectFolder": "/Users/…/api",
  "options": { "allow_once": "opt-1", "allow_always": "opt-2", "reject_once": "opt-3" },
  "askedAt": "2026-09-19T16:20:11Z",
  "expiresAt": "2026-09-19T17:20:11Z"
}
```

Rules on it:

- **One record per outstanding question.** Deleted when the question is answered, withdrawn, or
  expires. Swept on every app launch and every extension run.
- **It is a cache, not a record.** Nothing in it outlives the question. No transcript, no file
  content, no output — the three headline fields and the ids, which is what the banner already
  showed.
- **Protected at the same level as the device key**: available after first unlock, this device
  only, never synced. A revoked or lost iPad holds nothing readable (FR-031).
- **A missing record is not an error.** If the handler cannot find it — the extension did not
  run, the record was swept — the action falls back to opening the app on that agent, and says
  so. It never guesses an `optionID`.

## What the handler does, and what it must not

On `didReceive` with an action identifier:

1. Read the option map. Missing → open the app on the agent and stop.
2. Map the action to a `kind`, the `kind` to an `optionID`. No match → open the app and stop.
3. Seal one `permissions/answer` call — with `answeredBy` set to this device's name — and write
   it to the mailbox.
4. Delete the option map record.
5. Call the completion handler.

It **must not** connect a `DaemonClient`, open a transcript, fetch state, or do anything the
app would normally do on launch. The budget is short and unpublished (research §3). One sealed
write and stop.

**If the write fails or the budget runs out**: schedule a local notification — "That did not
reach your Mac" — naming the agent, before giving up. FR-013 says the answer is delivered once
or not at all and the person is told which; from a background launch, a local notification is
the only way to tell them.

## Withdrawal

When a question is answered anywhere — the Mac, the app, another device — the daemon broadcasts
the withdrawal with `answeredBy` (005 T040/T041). The bridge forwards it, and the iPad:

- removes the delivered notification for that question, so a settled question does not sit on
  the lock screen inviting an answer;
- deletes the option map record;
- if the app is open on that question, replaces the buttons with what became of it and who
  answered (FR-012).

A tap that races the withdrawal is answered by the daemon with `alreadyAnswered` (**`-32018`** —
005's chosen `-32013` is taken; see research §7), and the handler shows that rather than a
failure.

## Notifications that are not questions

`agent.done` covers finishing and stopping on an error. No actions — there is nothing to
answer. Each kind is independently switchable per device (FR-003), and neither switch affects
the escalation categories.

## What this contract does not cover

The push itself, the three headline fields, their measured byte budget, the subscription, and
the sealing — all 005's, in `contracts/mailbox.md` and research §5. Nothing here changes them
except that `Headline` now also carries the option map into the app group, which is a new
consumer of an existing payload, not a new payload.
