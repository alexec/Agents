# Contract: what the person sees

## Settings ▸ Servers ▸ Runtime credentials

- Claude has no row. Gemini's row is unchanged.
- The footer becomes: "Claude and Codex on a server use this Mac’s own sign-ins, through
  this Mac; nothing of them is written on a server. Gemini’s key is used by Gemini agents
  here and on servers, kept in this Mac’s Keychain."

## The runtime line for a server (Settings ▸ Servers, runtime menu)

Claude uses the same `toolsetLine` as Codex:

| State | Line |
|---|---|
| installed, relay available | `Claude: ready (installed by Agents) · signs in through this Mac` |
| installed, own sign-in only | `Claude: ready (installed by Agents) · its own sign-in` |
| installed, Mac not signed in, server has none | `Claude: ready (installed by Agents) · needs this Mac signed in to it` |
| not installed, relay available | `Claude: installed when <server> next connects` |
| not installed, Mac not signed in | `Claude: installed when this Mac is signed in to it` |

## The signInWanted ending

The agent's row ends with:
- `notSignedIn`: "Claude on this Mac isn't signed in with a Claude account.", with
  **Sign in** (053's runtime sign-in sheet for Claude on the Mac) and **Use <server>'s own
  sign-in** (opens Settings ▸ Servers at that server).
- `unreadable`: "Agents couldn't read Claude's sign-in on this Mac.", with the same two
  buttons.

A refused renewal ends with "Claude on this Mac needs signing in again." and **Sign in**.

## Gone

- The "Claude on <server> needs a token" sheet.
- "Claude refused the token in Settings. Replace it in Settings ▸ Servers."
- Every mention of `claude setup-token`.
