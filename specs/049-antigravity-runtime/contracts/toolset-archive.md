# Contract: The archive toolset

## Manifest (`App/Resources/toolsets/antigravity/manifest.json`)

```json
{
  "runtimeID": "antigravity",
  "kind": "archive",
  "version": "1.2.1",
  "source": "acp-registry:antigravity-acp",
  "minFreeBytes": 1000000000,
  "platforms": {
    "darwin-aarch64": {"url": "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-1.2.1-darwin-arm64.zip",
                       "sha256": "0fab9938812e6b32b3b543e65e4f3a0025ceef755413db13542d9a9b81ea803c",
                       "size": 111725488, "command": "agy_acp_server.par", "arguments": []},
    "darwin-x86_64":  {"url": "…darwin-x86_64.zip", "sha256": "…", "size": 0, "command": "agy_acp_server.par", "arguments": []},
    "linux-x86_64":   {"url": "…linux-x86_64.zip", "sha256": "…", "size": 333590110, "command": "agy_acp_server.par", "arguments": ["--uid="]},
    "linux-aarch64":  {"url": "…linux-arm64.zip", "sha256": "…", "size": 321280184, "command": "agy_acp_server.par", "arguments": ["--uid="],
                       "knownBroken": "Google's build crashes at start on ARM Linux (TCMalloc)."}
  }
}
```

Written only by `scripts/update-toolset.sh --archive antigravity-acp`, which reads the
registry's `agent.json`, refuses any URL not on `dl.google.com`, downloads each archive, and
records its size and SHA-256. `minFreeBytes` is set from the measured unpacked size plus margin.

## Install on a server (T006: a bare Debian has no `unzip` or `python3`)

The Mac runs steps 1–5 below into a staging folder of its own, then sends the result as
`tar -cz` over the existing ssh channel into `~/.agents-server/tools/antigravity/<id>.partial/`.
The server unpacks it with `tar -xz`, writes the shim and `ok`, renames it, and points `current`
at it. Free space is checked on the server against `minFreeBytes` before anything is sent.

## Install on the Mac

1. Refuse if free space < `minFreeBytes` ("Not enough room: Antigravity needs about N GB.").
2. Refuse if the platform is absent ("Google publishes no Antigravity for <platform>.") or
   `knownBroken` (its reason).
3. Download `url` to `<id>.partial/archive.zip`, reporting bytes of `size`.
4. SHA-256 must equal `sha256`, else remove `<id>.partial` ("The download from Google did not
   match what this app expects.").
5. Unzip into `<id>.partial/`, delete the zip, write `bin/agy_acp_server` (shim), `chmod +x`.
6. Rename `<id>.partial` → `<id>`, write `ok`, point `current` at `<id>`.
7. Remove other `<id>` folders not in use by a running agent (047).

A folder without `ok` is never used; a leftover `.partial` is removed at the next install.
