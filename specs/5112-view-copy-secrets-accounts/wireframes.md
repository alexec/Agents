# Wireframes: see and copy secrets and accounts (Mac and web)

Alex, 2026-11-12: "Users need to be able to view and copy both secrets and accounts. Wireframes first."
Epic #5112, this spike #5113. The stories after it: the wire and daemon method (#5114), then Secrets
and Accounts on the Mac and the web page (#5115, #5116). All names and values below are made-up examples.

**Settled (Alex, 2026-11-12):**

- No extra guard. Reveal and Copy work at once for the signed-in person. Each reveal and each copy goes
  in the audit log, with the name, never the value.
- Tier Mac + web: the Mac window and the web page. `remote: tier mac+web`.
- Agents never get a value from these screens or their method.

## 0. Where the value comes from

The control plane cannot open a person's secret: it keeps only copies sealed to each of the person's
machines **and each of their clients** (#3397, decision 1). Each client (the Mac window's key in the
Keychain, the browser's in IndexedDB) can open its own copy. So:

1. The client asks the control plane for **its own sealed copy** of one secret (section 7).
2. The control plane writes the audit entry, then gives back the envelope.
3. The client opens it with its own key, shows or copies the value, and forgets it.

The value never goes through the control plane or a machine in plain text, and no agent has a client
key, so no agent can open a copy.

Decided: the client opens its own copy, not a machine, because the control plane already keeps a copy
for each client and a machine may be offline. Alex can overrule.

## 1. Secrets ▸ a row, hidden (the default)

Today's row, with two new buttons at the end of the name line: **Reveal** (an eye) and **Copy**. The
`(⋯)` menu gets the same two items, for the keyboard and for VoiceOver.

**Mac, Settings ▸ You ▸ Secrets**

```
┌ Secrets ──────────────────────────────────────────────────────────────────────┐
│                                                                               │
│  GITHUB_TOKEN                               ••••ab12   (👁) (⧉)   (⋯)         │
│  GitHub token for alexec, repo and workflow scopes.                           │
│  On 3 machines · Added 27 d ago · Used 2 h ago                                │
│ ───────────────────────────────────────────────────────────────────────────── │
│  NPM_PIN                                    ••••       (👁) (⧉)   (⋯)         │
│  No description.                                                              │
│  On 2 machines · Added 61 d ago · Used 12 d ago                               │
│ ───────────────────────────────────────────────────────────────────────────── │
│  Add a Secret…                                                                │
│  Add a Card…                                                                  │
└───────────────────────────────────────────────────────────────────────────────┘

(⋯) menu:   Reveal
            Copy Value
            ─────────
            Replace…
            Remove…
```

**Web page, Settings ▸ You ▸ Secrets**

```
┌ Secrets ──────────────────────────────────────────────────────────────────────┐
│  GITHUB_TOKEN                                                 ••••ab12        │
│  GitHub token for alexec, repo and workflow scopes.                           │
│  On 3 machines · Added 27 d ago · Used 2 h ago                                │
│  [Reveal] [Copy]   [Replace…] [Remove…]                                       │
│ ───────────────────────────────────────────────────────────────────────────── │
│  NPM_PIN                                                      ••••            │
│  …                                                                            │
└───────────────────────────────────────────────────────────────────────────────┘
```

The web page's row has its buttons in `row-actions`, as the Accounts rows have Edit… and Remove…
today, so Reveal and Copy go first there.

| Control | Mac | Web | Accessibility |
|---|---|---|---|
| Reveal | `eye` icon button, help "Reveal" | text button "Reveal" | "Reveal GITHUB_TOKEN" |
| Copy | `copy` icon button, help "Copy" | text button "Copy" | "Copy GITHUB_TOKEN" |

## 2. Secrets ▸ a row, shown

Reveal puts the value in place of `••••ab12`, on a line of its own under the name, in the code font. A
long value wraps at any character. The eye becomes **Hide** (eye with a slash).

**Mac**

```
│  GITHUB_TOKEN                                          (🚫👁) (⧉)   (⋯)        │
│  ghp_9xT2mQe7LkV0aRz4YpW8cN1sFb3uJd6hab12                                     │
│  GitHub token for alexec, repo and workflow scopes.                           │
│  On 3 machines · Added 27 d ago · Used 2 h ago                                │
│  Shown for 30 s. Your reveal is in the audit log.                             │
```

**Web**

```
│  GITHUB_TOKEN                                                                 │
│  ghp_9xT2mQe7LkV0aRz4YpW8cN1sFb3uJd6hab12                                     │
│  GitHub token for alexec, repo and workflow scopes.                           │
│  On 3 machines · Added 27 d ago · Used 2 h ago                                │
│  Shown for 30 s. Your reveal is in the audit log.                             │
│  [Hide] [Copy]   [Replace…] [Remove…]                                         │
```

Rules:

- The value hides again after **30 seconds**, when the person presses Hide, when the pane or page
  closes, when the window goes to the background (Mac) or the tab is hidden (web), and when the
  secret changes (`control/userSettingsChanged`). Then the client drops the value from memory.
- Only one value is shown at a time: Reveal on a second row hides the first.
- The value is text that a person can not select: Copy is the only way to copy it, so each copy goes
  in the audit log.
- While the copy is fetched, the eye is a small spinner. A failure puts the problem line in the row,
  in the failure tint (section 6).

Decided: 30 seconds, because it is long enough to read and compare a value and short enough that a
value is not left on a screen. Alex can overrule.

## 3. Secrets ▸ a row, copied

Copy does not reveal. It fetches the copy, puts the value on the clipboard, and says so for 2 seconds.

**Mac**

```
│  GITHUB_TOKEN                               ••••ab12   (👁) (✓)    (⋯)        │
│  …                                                                            │
│  Copied. The clipboard clears in 90 s.                                        │
```

**Web**

```
│  GITHUB_TOKEN                                                 ••••ab12        │
│  …                                                                            │
│  Copied. The clipboard clears in 90 s.                                        │
│  [Reveal] [Copied ✓]   [Replace…] [Remove…]                                   │
```

Rules:

- **Mac:** the value goes on the general pasteboard with `org.nspasteboard.ConcealedType` too, so
  clipboard managers that obey it do not keep it. After 90 seconds, the window clears the pasteboard
  if it still holds that value (its `changeCount` is the same).
- **Web:** `navigator.clipboard.writeText`. After 90 seconds the page writes an empty string, if the tab
  is still open and in front (a browser lets a page write only then). When it cannot, the line says
  "Copied." only.
- A failed write says "This browser did not let the page copy." in the failure tint.

Decided: clear after 90 seconds, because that is what password managers do and it keeps a value off
the clipboard. Alex can overrule.

## 4. Secrets ▸ a card

A card (#3531) is one secret with five parts. Reveal shows each part on its own line, each with its own
Copy. The row's Copy (and Copy Value) copies the card number.

**Mac**

```
│  SHOP_CARD   Card                                      (🚫👁) (⧉)   (⋯)        │
│    Card number   4242 4242 4242 4242                    (⧉)                   │
│    Expiry        09/28                                  (⧉)                   │
│    CVC           123                                    (⧉)                   │
│    Name on card  Ada Example                            (⧉)                   │
│    Billing ZIP   94110                                  (⧉)                   │
│  Shop card, spend limit $50, locked to one merchant.                          │
│  On 3 machines · Added 4 d ago · Never used                                   │
│  Shown for 30 s. Your reveal is in the audit log.                             │
```

The web page draws the same, with a `Copy` text button after each part.

## 5. Secrets ▸ Ask before use

Ask before use (#4016) holds an **agent's** use until the person allows it. It is not a guard for the
person. So the row has the same Reveal and Copy, which work at once, and the line stays:

```
│  OPENAI_API_KEY                             ••••Zq9w   (👁) (⧉)   (⋯)         │
│  Key for the evals project.                                                   │
│  On 2 machines · Added 3 h ago · Used 5 min ago                               │
│  ✋ Asks before use                                                           │
```

A reveal or a copy by the person allows nothing for an agent, and makes no grant.

## 6. Secrets ▸ the states where Reveal can not work

| State | Row | Why |
|---|---|---|
| This client has no copy yet (it was paired after the secret was set, and no other client of the person has been online since) | Reveal and Copy disabled. Line: "This app has no copy yet. It gets one when another app of yours is online." | `sealing/work` gives it a copy later (#3397). |
| The control plane can not be reached | Reveal and Copy disabled, as Add a Secret… is today. | |
| The copy does not open (a changed key) | Line: "This app's copy did not open. Replace the secret to seal it again." in the failure tint. | |
| Secrets for one session (Mac, the `extra` section) | No Reveal or Copy. | They are only in that machine's store, and not in this epic. |

## 7. Accounts ▸ a row, and its details

Today a row shows the service, the address and plan, the cost, the last 4 of its secret, and
Made / Edited / Used. A row gets a **Details…** item (and a press on the row opens it), which opens a
sheet (Mac) or a modal (web) with each field and a Copy for each one that has a value.

**Mac, the row**

```
│  gitlab.com                                       $0.00   ••••x9Qe   (⋯)      │
│  agentloops@example.com · Free                                                │
│  Agents' GitLab, for forge tests.                                             │
│  Made 9 d ago · Edited 1 d ago · Used 2 h ago                                 │

(⋯) menu:   Details…
            ─────────
            Edit…
            Remove…
```

**Mac, the details sheet**

```
┌ gitlab.com ───────────────────────────────────────────────────────────────────┐
│                                                                               │
│  Service        gitlab.com                                     (⧉)            │
│  Address        agentloops@example.com                         (⧉)            │
│  User name      agentloops                                     (⧉)            │
│  Description    Agents' GitLab, for forge tests.                              │
│  Plan           Free · $0.00 a month                                          │
│  Two-factor     TOTP                                                          │
│ ───────────────────────────────────────────────────────────────────────────── │
│  Secret         GITLAB_TOKEN   ••••x9Qe                (👁) (⧉)               │
│  Card           —                                                             │
│  Token expires  2027-02-01 (in 81 d)                                          │
│ ───────────────────────────────────────────────────────────────────────────── │
│  Notes          Password is in Secrets as GITLAB_PASSWORD.     (⧉)            │
│  Issue          #4303                                                         │
│  Projects       All                                                           │
│  Made 9 d ago · Edited 1 d ago · Used 2 h ago                                 │
│                                                                               │
│                                                       [Edit…]   [Done]        │
└───────────────────────────────────────────────────────────────────────────────┘
```

**Web page, the details modal** is the same list, with `Copy` and `Reveal` text buttons, and `Edit…` and
`Done` at the foot. The row's `row-actions` get `Details…` before `Edit…`.

### What an account shows, and what it can copy

| Field | Shown | Copy | Audit |
|---|---|---|---|
| Service | yes | yes | no: not a secret |
| Address (the email it signs in with) | yes | yes | no |
| User name (new, optional) | when set | yes | no |
| Description | yes | no | — |
| Plan and monthly cost | yes | no | — |
| Two-factor | yes | no | — |
| Secret: its name and last 4, Reveal and Copy of the value | when it names a secret in Secrets | yes | **yes**, as a secret's, with the account |
| Card: its name, and Reveal of its parts as in section 4 | when it names a card in Secrets | yes, each part | **yes**, with the account |
| Token expires, Issue, Projects, Made / Edited / Used | yes | no | — |
| Notes | when set | yes | no |

Decided: add an optional **User name** field to the account record (`username`), because many sites
sign in with a user name that is not the email, and the epic asks for it. It is plain text, never a
secret, as Address is. Alex can overrule.

Decided: **holder** is the person whose Settings ▸ You it is, so the sheet does not show it again.
A card's holder is its Name on card part (section 4). Alex can overrule.

Decided: a password is a secret in Secrets that the account names (`secret`, or a second name in
Notes as today). The record does not get a password field, because #3967 keeps every value out of the
record. Alex can overrule.

## 8. Accounts ▸ an account with no secret

```
│  Secret         —   No secret. Add one in Secrets, then name it in Edit….     │
│  Card           —                                                             │
```

No Reveal or Copy. When `secret` names something that is not in Secrets (such as "1Password"), the line
is that text and "not in Secrets", as the row's hint says today, with Copy for the text and no Reveal.

## 9. The audit log

Each reveal and each copy of a value is one audit entry, written by the control plane before it gives
back the sealed copy. `method` is `user/sealedSecret`. The actor is the person and the client
(Mac window on *studio*, or the web page). Never the value, never the last 4.

| What | `action` |
|---|---|
| Reveal of a secret | `Revealed secret GITHUB_TOKEN` |
| Copy of a secret | `Copied secret GITHUB_TOKEN` |
| Reveal of a card | `Revealed card SHOP_CARD` |
| Copy of a card's part | `Copied the CVC of card SHOP_CARD` (the card number, the expiry, the CVC, the name on card, the billing ZIP) |
| Reveal from an account | `Revealed secret GITLAB_TOKEN of account gitlab.com (agentloops@example.com)` |
| Copy from an account | `Copied secret GITLAB_TOKEN of account gitlab.com (agentloops@example.com)` |

A copy of a plain field (an address, a user name) is not audited: it is not a secret.

"Used 2 h ago" does not change: it is an agent's or a machine's use. Status ▸ Secrets does not change.

The audit log is a record, not a guard: a client that opens its own copy and does not say so writes
nothing. That is the same today, because `sealing/work` gives a client its own copy to seal again.

## 10. The wire method (for #5114)

On the control plane, `Packages/Wire/control.openrpc.json`, as `orgRoutes/sealed` is for an admin:

```text
user/sealedSecret
  params:
    name:     UserSecretName           the secret
    purpose:  "reveal" | "copy"        for the audit entry
    part?:    "number" | "expiry" | "cvc" | "name" | "zip"
                                       a card's part, for a copy; absent otherwise
    account?: { service: string, address?: string }
                                       the account it was opened from, for the audit entry
  result:
    name:     UserSecretName
    version:  integer
    kind?:    UserSecretKind
    sealed:   string                   this client's envelope (c:<CLIENT UUID>), HPKE as #3397,
                                       info com.alexecollins.agents.usersecret.v1,
                                       associated data usersecret.v1|<person id>|c:<CLIENT UUID>|<name>|<version>
```

Rules:

- Only the person's own paired clients reach it: a client link with a client key, for that person's
  own secret. A machine link (agentsd), an agent's token and an admin asking for another person's
  secret are refused (`unauthorized`).
- `noClientCopy` when the control plane keeps no copy for this client yet (section 6).
- `notFound` when no such secret.
- The control plane writes the audit entry first, and gives back nothing when it can not write it.
- No MCP tool, `agents-secret` or `secrets/*` daemon method gets it. The Mac's own agentsd does not relay
  it.

## Clients

- **mac:** this spec (Settings ▸ You ▸ Secrets and Accounts, the window).
- **web:** this spec (Settings ▸ You ▸ Secrets and Accounts).
- **remote:** tier mac+web. The Remote draws `SecretsPane` and `AccountsPane` from `Shared/UI` too, so
  the new controls are only on the Mac there (`#if os(macOS)`, or a flag the window sets).

## Principles (direction.md)

- **Principle 1 (nothing relies on the Mac):** the web page has the whole feature, from its own
  browser key.
- **Principle 6 (the control plane holds nothing it could misuse):** it gives back only a copy sealed
  to the asking client, and never has the value.
- **Principle 7 (keep nothing that can stay on the customer's systems):** the audit entry keeps the
  secret's name and the account, never the value or its last 4.
