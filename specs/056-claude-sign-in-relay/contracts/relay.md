# Contract: the relay, per runtime

## relay/offer (window → server daemon), unchanged in shape

```json
{ "runtime": "claude", "socketPath": "~/.agents-server/relay-claude.sock",
  "caCertificate": "-----BEGIN CERTIFICATE-----…", "standIn": "sk-ant-oat01-agents-relay-standin" }
```

- A window sends one offer per runtime it can relay, on every connect. Before 056 it sent
  only Codex's.
- It sends none to a server marked "own sign-in only".
- A second offer for the same connection and runtime replaces the first. Offers for other
  runtimes are kept.

## Claude's launch environment on a server (relayed)

| Variable | Value |
|---|---|
| `ANTHROPIC_BASE_URL` | `https://127.0.0.1:<gate port>` |
| `CLAUDE_CODE_OAUTH_TOKEN` | the offer's `standIn` |
| `NODE_EXTRA_CA_CERTS` | `<root>/runtimes/claude-relay-ca.pem` (the offer's certificate, 0600) |
| `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` | removed |

## Failure: signInWanted (`-32070`)

Raised by a server's daemon on `agents/start` or `agents/send` before anything starts, when
Claude has no relay offer, the server is not "own sign-in only", and the server has no
Claude sign-in of its own.

```json
{ "code": -32070,
  "message": "Claude on this Mac isn't signed in with a Claude account.",
  "data": { "runtime": "claude", "reason": "notSignedIn" } }
```

`reason` is one of:
- `notSignedIn`: no item, or no inference scope;
- `unreadable`: the item exists but couldn't be read or parsed.

The window chooses the sentence and the sheet from `reason`. `credentialWanted` (`-32036`)
stays for Gemini only.

## What the Mac's relay sends upstream

- It keeps the method, path, query, body and every header except `Authorization`,
  `x-api-key` and hop-by-hop headers.
- It sets `Authorization: Bearer <Mac access token>`, plus the policy's `upstreamHeaders`.
- On a 401 it renews once (data-model, ClaudeKeychainSignIn) and asks again. The runtime
  sees only the second answer.
- If the renewal is refused, the runtime sees the 401. The server's daemon turns the
  resulting `authentication_failed` into the ending "Claude on this Mac needs signing in
  again" (FR-013).

## Log lines (`<root>/hosts/relay.log`)

`relay: <METHOD> <path> -> <status>`, `relay: … renewing this Mac's sign-in`, and
`relay: refused <reason>` from the gate. Never a header, a body, a query string or a token.
