# Contract: the agent's Dashboard tools

All three are answered by the app; the person is not asked. The project is the caller's
`projectFolder`, whichever checkout it works in.

## `set_tile`

Arguments: `id`, `title`, `type`, `section?`, `source?`, `stale_after_hours?`, `take_over?`, and
by type:

| type | arguments |
|---|---|
| number | `value` (number), `unit?`, `good?` (`up`/`down`) |
| status | `level` (`ok`/`warn`/`bad`/`unknown`), `line`, `since?` |
| table | `columns` (strings), `rows` (arrays of strings or `{text,url}`) |
| note | `markdown` |
| link | `link_title?`, one of `url`, `session`, `file`, `workflow` |

Answer (text): the tile as stored (its file's JSON), then any of:
- "The person has hidden this tile; it is kept up to date out of sight."
- "The person removed this tile on 2 Oct at 17:20 (on the Mac); posting has put it back."
- "Recorded a point (12 kept)." for a number.
- "Unchanged; its age is refreshed." when the file was not rewritten.

Refusals (`isError`, nothing written), each one sentence:
- a bad id, type or field, naming the field and the rule;
- "kept by <keeper>; ask it, or take it over with take_over once it is archived";
- over a limit: 60 tiles, 8 KB file, table size, note size, 8 MB history, 120 sets an hour;
- the project folder is missing (#119), naming it.

## `remove_tile`

Arguments: `id`. Removes a tile the caller keeps: its file and its points. Refused, in words, for
another keeper's tile or an unknown id.

## `read_dashboard`

No arguments. Every tile in the project, hidden ones included: id, title, type, section, value,
keeper (name and whether it is you), age, stale, hidden, changed outside, and the last 10 points
of a number. Plain text, one block per tile.
