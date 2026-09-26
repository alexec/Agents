# Contract: Screens

The look was approved on [look/away-mock.png](../look/away-mock.png). Words are exact.

## The line under the title (the `StaleBanner` slot)

One line, on every screen, in this order of precedence:

| State | Icon | Words |
|---|---|---|
| Neither link answers | `wifi.slash` | "Last heard from your Mac {relative}" (as today), or "Not connected to your Mac yet" |
| Not paired for the relay, and away | `wifi.slash` | "Not connected to your Mac yet" (as today); the page body shows the never-paired card |
| No iCloud / iCloud full | `icloud.slash` | "The relay needs iCloud on your iPhone and your Mac" / "iCloud is full, so the relay can't carry messages" |
| Relayed, slowed down | `icloud` | "**Away** — slower than usual" |
| Relayed | `icloud` | "**Away** — slower, through iCloud" |
| Direct | — | nothing (as today) |

"Away" is in the primary colour and semibold; the rest is secondary. (The mock drew it in the accent colour; colour here means only attention, failure or vouched, so it is weight instead.) There is one accessibility element
per row (see the stacked-labels memory).

## Never-paired card (look C)

Shown as the project list's empty state when away with no `macKey`:

> ⌂ **Open Agents once on your Mac's Wi-Fi**
> After that, your phone reaches your Mac from anywhere, through your iCloud.

On iPad it says "your iPad" instead.

## Files, Terminal, Page while away (look B)

The segmented switch stays. The pane body is:

> ⌂ **Needs the same network as your Mac**
> The terminal, the live page and files open here when your phone is on your Mac's Wi-Fi.
> Chat, questions and starting agents work from anywhere.

Nothing spins. When the link becomes direct, the pane opens by itself (keyed on `model.link`).

## Prompt bar while away (look A)

The paperclip is disabled and dimmed. Tapping it does nothing, and VoiceOver reads it as "Attach,
needs the same network as your Mac". Voice and Send are unchanged. The start-agent sheet's
attachments row is disabled in the same way.

## Mac: Settings ▸ Devices

Each row gains **Forget…**, which asks: "Forget {name}? It will stop reaching this Mac from away
until it is next on the same network." with the buttons Forget and Cancel.
