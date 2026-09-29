# Contract: Each Runtime's State

What the app knows about each runtime's allowance, where it is shown, and the one place it is
read before a chat starts. It is never enforced.

## The row

One row per runtime the app locates. In
**Settings ▸ Agent Runtimes** on the Mac it sits on the runtime's card. On the iPhone and iPad
it is a row in **Spending ▸ Runtimes**.

| Line | Words | When |
|---|---|---|
| State | **Available** | No state yet, or it came back |
| | **Rate limited · trying again at ‹time›** | A chat on it was rate limited and is waiting to retry |
| | **Out · reset ‹time› · checking after ‹time›** | Out, and the provider gave a time |
| | **Out · checking after ‹time›** | Out, with no time from the provider |
| | **Failed · checking after ‹time›** | A crash or unrecognised failure |
| | **Credit used up · checking after ‹time›** | The provider said the key's credit is used up |
| Plan left | **28% left this week · resets Sun 20:39 · as of 14:02** | Only when the runtime reported one (Grok when asked, Claude during a turn) |
| Action | **Mark available** | Only when it is out |

The words are `PoolWords`' existing sentences, less any that name the pool.

## Checks

Unchanged from 47153fa7, for every runtime rather than only a pool's:

- A check is due at `since + 4h`, and four hours after each failed check.
- It is a new conversation in the daemon's own folder, in a read-only mode (plan, ask or
  read-only), on the smallest model the runtime lists, asked to reply "OK". A runtime with a
  mode option but no read-only mode is not checked, and fails.
- A pass marks it available and raises `cost.allowance_back` with `how: check`.
- A provider's reset time is shown. It never marks a runtime available by itself.

## The prompt bar

A new chat, before its first message, on a runtime that is out:

> ‹Runtime› is out. Its provider says it resets at ‹time›; the app checks before using it again.

or, with no provider time:

> ‹Runtime› is out. The app checks it again at ‹time›.

The send button stays enabled. There is no offer of another runtime. A chat that has already
sent a message shows nothing.

## Events

| Name | Details | Sentence |
|---|---|---|
| `cost.allowance_out` | `runtime`, `reason`, `until` (provider time only), `retry_after` | `‹Runtime›'s allowance ran out.` / `‹Runtime› failed. The app checks it again at ‹time›.` |
| `cost.allowance_back` | `runtime`, `how` (`worked`, `check`, `person`, `time`, `another host`) | `‹Runtime›'s allowance came back.` / `‹Runtime› is working again.` |

## Daemon methods

| Method | Params | Result | Who |
|---|---|---|---|
| `runtimes/allowances` | none | `RuntimeAllowances` (rows as above) | Mac and paired devices |
| `runtimes/markAvailable` | `credentialKey` | `RuntimeAllowances` | Mac and paired devices |
| `pool/applyAllowances` | `[AllowanceState]` | changed: Bool | daemon to daemon, unchanged |
| notification `runtimes/allowancesChanged` | `RuntimeAllowances` | | at most once a second |

`pool/state`, `pool/set`, `pool/markAvailable`, `pool/stopWaiting`, `pool/models` and
`agents/continueWith` are removed.
