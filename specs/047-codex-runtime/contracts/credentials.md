# Contract: Codex's server credential

## Kind

`openAIAPIKey`: text beginning with `sk-` and not `sk-ant-`, after trimming. It is shown
masked (043's `Secret`), and kept in the Mac's Keychain under runtime id `codex`.

## Checking it on save (FR-017)

```text
GET https://api.openai.com/v1/models
Authorization: Bearer <key>
```

| Response | Settings says |
|---|---|
| 200 | **Works** |
| 401 | **OpenAI refused this key** |
| anything else, or no answer | **Couldn’t check it just now**. The key is kept |

It costs no tokens. The key goes to OpenAI and nowhere else.

## Settings row

> **Codex**: an OpenAI API key, from platform.openai.com/api-keys. Used only by Codex agents
> on your servers; turns there are billed to this key, not to your ChatGPT plan. Codex on
> this Mac keeps its own sign-in.

## Lending (043's `credentials/offer` / `credentials/lend`, unchanged in shape)

- A window's offer lists `codex` when a Codex record exists and the server is not "own
  sign-in only".
- `credentials/lend {runtime:"codex", kind:"openAIAPIKey", secret}` is accepted only for an
  offered runtime whose kind matches.
- At launch, `CODEX_API_KEY` is set to the lent key and `OPENAI_API_KEY` is removed. The
  key is in the Codex process's environment only: it is not in any file, log or transcript.
- If nothing is lent and there is no own sign-in, `credentialWanted {runtime:"codex"}`, and
  the window asks in place.

## Own sign-in on a server

`ServerSignIn.exists("codex")` is true when `~/.codex/auth.json` exists on the server, or
when `CODEX_API_KEY` or `OPENAI_API_KEY` is set in its login environment.

## Never lent

A ChatGPT sign-in (`~/.codex/auth.json` on the Mac) has no kind, no record and no lend
path. On a server, `NO_BROWSER=1` hides `chat-gpt`. `chat-gpt-device-code` stays: it signs
in on the server itself, and is written there by Codex. That is the server's own sign-in,
used only when the person marks the server "own sign-in only".

## Refused

The adapter's shape for a refused key is to be measured in the spike (R9).
`isAuthenticationFailure` gains that shape, and the ending is 043's
`credentialRefused {runtime:"codex", lent:true}`.
