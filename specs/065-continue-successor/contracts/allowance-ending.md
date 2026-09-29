# Contract: A Spent Allowance Ends That Chat

The person sees none of this as a tool. It is what the daemon does when `LimitRecognition`
classifies the turn that just ended, and what is no longer on screen.

## The chat that was refused

| What the runtime did | Note in the transcript | Status line | What happens next |
|---|---|---|---|
| Allowance spent | `‹Runtime›'s allowance ran out.` or `‹Runtime›'s allowance ran out, until ‹time›.` when the runtime gave a time | Its allowance ran out | The chat stays on that runtime, stopped. Nothing is started. |
| Credit used up | `‹Runtime›'s credit is used up.` | Its allowance ran out | The same. |
| Paid extra usage began | `‹Runtime› started using paid extra usage, so it is treated as out.` | Its allowance ran out, unless the turn itself completed | The same. No further turn is started on a key. |
| Rate limited, and a retry is still allowed | `‹Runtime› is rate limited. Trying again at ‹time›.` | Rate limited, while it waits | The same prompt is sent again on that runtime, at that time, unless the chat was stopped, archived, or given another prompt. |
| Rate limited three times within ten minutes, on this chat | `‹Runtime› stayed rate limited.` | Rate limited, and still limited after retrying | The chat stays on that runtime. It is not moved. |

`‹Runtime›` is `PoolWords.runtimeName`. `‹time›` is `PoolWords.time`. These sentences already
exist; this feature stops appending anything after them about another runtime.

The list heading for "Its allowance ran out" is **Paused**. It is not **Waiting** and not
**Needs you**.

## What the runtime records

The same refusal marks the runtime out, for every chat to see and none to obey. See
[runtime-state.md](runtime-state.md).

## What another chat sees

No ran-out note and no wait. A chat already on that runtime is prompted as usual; if its turn
works, the runtime is back. A new chat about to start on it shows the prompt bar's notice
(runtime-state.md), and sends when the person sends.

## What is gone from the Mac, iPhone and iPad

- A Pool page, a Pool row in the sidebar with its dot, and Option-Command-P
- Settings ▸ Pool, including Add a runtime and the pool's order (Add credit on an API key
  moves to Agent Runtimes)
- Continue with, on the chat and on the runtime control
- Matching models
- Waiting for an allowance, Stop waiting, and "Carry on when ‹runtime› runs out"
- Recent switches

**Carry on** on a chat that is blocked on a person, an agent or a time stays. That is the
blocked-chat action, not a runtime switch.

## What is gone from the event catalogue

- `agent.runtime_switched`. It is not raised. A workflow trigger that names it does not fire.

`cost.allowance_out` and `cost.allowance_back` stay (runtime-state.md).

## What an old chat still shows

A transcript that already contains a switch note, a handoff, or a settings-changed line still
draws it. The record is not rewritten.
