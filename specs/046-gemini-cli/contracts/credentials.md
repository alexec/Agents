# Contract: Gemini API key (servers only)

## Recognising it

A pasted string, trimmed, that starts `AIza` and is longer than 8 characters is a
`geminiAPIKey`. Anything else in the Gemini row is refused at paste with: "That isn't a
Gemini API key. They start with AIza; get one at aistudio.google.com/apikey."

## Checking it on save

```http
GET https://generativelanguage.googleapis.com/v1beta/models?pageSize=1
x-goog-api-key: <key>
```

| Response | Shown |
|---|---|
| 200 | **Works** (and `lastWorked` set) |
| 400 with `API_KEY_INVALID`, or 403 | **Google refused this key** |
| anything else, or no network | **Could not check it just now**; kept anyway |

The key goes in a header, never the URL, so it cannot land in a proxy log.

## Keeping it

Keychain item beside Claude's (043), account = `gemini`. Shown masked as `AIza…` + last 4.

## Lending it

Unchanged from 043's `credentials/offer` / `credentials/lend`, with `runtime: "gemini"`,
`kind: "geminiAPIKey"`. The daemon accepts a lend only when the kind's runtime equals
`runtime` (today's check `secret.kind == lend.kind` extends to that). A lent Gemini key is
never handed to a Claude start, and the other way round.
