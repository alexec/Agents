# Contract: Daemon API additions (034)

JSON-RPC 2.0, one object per line, on `daemon.sock`, and through the bridge unchanged. Names
go in `DaemonAPI.Method` and `DaemonAPI.Notification`. Types go in `DaemonAPI`, `Codable`
and `Sendable`. `Data` is base64, as it already is for `shell/output`.

Every `files/*` request is refused in the same way when the path is out of scope:

```json
{"code": -32602, "message": "<FolderScope.refusal(for: path)>"}
```

That is the same sentence `show_file` and `artifact/write` give. A path is resolved (standardised,
with symlinks resolved) before the check, and what is read is the resolved path.

New failure codes. These are the next free codes on `main` at planning time. Take the next
free ones at merge if another lane has used them.

| Name | Code | Meaning |
|---|---|---|
| `fileGone` | -32032 | The folder or file is not there (any more). |
| `fileNotReadable` | -32033 | It is there, and it cannot be opened. |

`noSuchAgent` (-32005) as today.

---

## `files/list`

One level of a folder, folders first, by name (`DirectoryReader.read`).

**Params**

```json
{"agentID": "UUID", "folder": "/abs/path"}
```

**Result**: `DirectoryListing`

```json
{
  "url": "file:///abs/path/",
  "entries": [
    {"url": "file:///abs/path/src/", "name": "src", "isDirectory": true,
     "size": null, "modifiedAt": "2026-09-24T10:00:00Z"}
  ],
  "omitted": 0
}
```

- At most `DirectoryReader.entryLimit` (5,000) entries. `omitted` counts the rest.
- `touchedByAgent` is not sent. The client marks from its transcript (research §5).
- Errors: scope refusal, `fileGone`, `fileNotReadable`, and `-32602 "That is a file."` for a
  file.

## `files/read`

A file's current contents, or what it is (`FileProbe.read`).

**Params**

```json
{"agentID": "UUID", "path": "/abs/file", "knownStamp": {"size": 812, "modifiedAt": "…"}}
```

`knownStamp` is optional. When the file's stamp still equals it, the answer is `unchanged`.

**Result**: `FileReading`, tagged by `kind`

```json
{"kind": "text", "text": "…", "isTruncated": false, "size": 812,
 "stamp": {"size": 812, "modifiedAt": "…"}}
{"kind": "image", "bytes": "<base64>", "describedAs": "SVG image",
 "stamp": {…}}
{"kind": "other", "describedAs": "SQLite database", "size": 2202009,
 "stamp": {…}}
{"kind": "unchanged", "stamp": {…}}
```

- Text is at most `FileProbe.prefixLimit` (128 KB). `isTruncated` says it was cut.
- An image is sent when at most 4 MB (`FileReading.imageLimit`). A larger one is `other`.
- Errors: scope refusal, `fileGone`, `fileNotReadable`, and `-32602 "That is a folder."`

## `files/watch`

Hear about changes under an agent's folder, on this connection only.

**Params**

```json
{"agentID": "UUID", "folder": "/abs/path"}
```

**Result**: `{}`

- Idempotent per `(connection, agentID, root)`, where `root` is the scope folder holding
  `folder`.
- One `FolderWatch` per root across all connections.
- The interest ends on `files/unwatch` or when the connection closes.
- Errors: scope refusal, `fileGone`.

## `files/unwatch`

**Params**: as `files/watch`. **Result**: `{}`. Unknown interests are ignored.

## Notification `files/changed`

Sent **only** to connections holding an interest in that agent and root (`DaemonServer.notify(_:_:to:)`).

```json
{"agentID": "UUID", "folders": ["/abs/path/src", "/abs/path"]}
```

- These are directories, as FSEvents reports them, coalesced at 0.2 s and de-duplicated
  (`FolderWatch`).
- The client re-lists a shown folder that is named, and re-reads an open file whose parent
  is named (with `knownStamp`).
- A root that disappears is named itself. The client's next `files/list` answers `fileGone`.

---

## `shell/input` (changed)

**Params**

```json
{"agentID": "UUID", "bytes": "<base64>", "rows": 40, "cols": 60}
```

- `rows` and `cols` are optional and new. When both are present, positive and different from
  the session's size, the PTY is resized, then written. This is how "the size of whichever
  device typed last" holds (US4 scenario 5).
- An older daemon ignores the extra keys. An older client sends none, and behaves as before.

## Shell notifications to devices (routing change)

`shell/output` and `shell/stateChanged` are unchanged in shape. They go to:
- every connection whose surface is `.mac` (windows, the bridge's mailbox carrier), as today
- a connection whose surface is `.device` only while it has attached that agent's shell
  (`shell/attach` or `shell/restart`) and not since detached or disconnected

## Unchanged, now also called by devices

| Method | Use on the phone |
|---|---|
| `artifact/write` | The page's save. The person's note for the agent's next turn is recorded once per write, whichever device wrote (edge case "two phones and a Mac"). |
| `shell/attach`, `shell/detach`, `shell/resize`, `shell/restart`, `shell/signal` | The terminal pane, as the Mac's. |
| `agents/transcript` | Also used once from the start when Files opens, to fold `TouchedPaths` over the whole conversation. |

## Older Mac

A daemon without these answers `-32601` (`methodNotFound`). The phone treats the first one
from any `files/*` method as "this Mac has no panes" for the life of the connection
(research §12).

## Tests that hold this contract

`Integration/FilesRequestTests.swift`:
- scope refusal text equals `show_file`'s
- a symlink out of scope is refused
- list order and cap
- read: text, truncated text, image, oversize image, binary, unchanged, gone, and folder
- watch: `files/changed` reaches the watching connection and not another
- unwatch and disconnect stop the `FolderWatch`

`Integration/ShellSizeTests.swift`:
- input with a size resizes before writing
- input without a size does not resize
- a device hears only shells it attached
- a window hears all
- detach stops a device hearing
