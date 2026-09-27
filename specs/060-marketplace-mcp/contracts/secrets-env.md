# Contract: `secrets.env`

Path: `<personalHome>/.agents/secrets.env`. Mode **0600**. Created on first write. Never
committed; never copied to a project.

## Format

```
# optional comment lines and blanks kept as written
GITHUB_TOKEN=ghp_example_not_real
CONTEXT7_API_KEY=key=with=equals
```

- One assignment per line: first `=` separates name from value. The value is the rest of the
  line, including further `=` and quotes, with no unescaping.
- Name: `[A-Za-z_][A-Za-z0-9_]*`.
- Lines the app did not write (comments, blanks, unknown names) are preserved on update.
- Writing one name replaces that name's line or appends it; other lines stay in order.

## Read model

Anything sent to the app or logged about secrets is **names only**: `{ name, set: true }`.
The value appears only:

- on the `mcp/set-secret` and `mcp/add` **request** from the Mac window;
- inside the daemon while filling a session's servers;
- on disk in `secrets.env`.

It must not appear in `personal/shared`, events, transcripts, phone envelopes, or daemon log
lines.

## Fill rules

When preparing session servers, each string in `env`, `args` and `headers` is scanned for
`${NAME}`. Replacement is literal. Nested or partial forms are not expanded. If a name is
missing from `secrets.env`, that whole server is omitted from the session and the missing
name is listed on Shared / the project row (frames A, D, E).
