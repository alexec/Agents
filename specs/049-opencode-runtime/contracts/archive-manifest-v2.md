# Contract: archive manifest, version 2

`App/Resources/toolsets/<runtime>/manifest.json`, `kind: "archive"`. Version 1 manifests
(Antigravity's) stay valid unchanged.

```json
{
  "kind": "archive",
  "runtimeID": "opencode",
  "version": "1.18.33",
  "source": "github:anomalyco/opencode@v1.18.33",
  "minFreeBytes": 500000000,
  "platforms": {
    "darwin-aarch64":             {"url": ".../opencode-darwin-arm64.zip",   "sha256": "24b1…", "size": 46317276, "command": "opencode", "arguments": []},
    "darwin-x86_64":              {"url": ".../opencode-darwin-x64.zip", "...": "..."},
    "darwin-x86_64-baseline":     {"url": ".../opencode-darwin-x64-baseline.zip", "...": "..."},
    "linux-x86_64":               {"url": ".../opencode-linux-x64.tar.gz", "...": "..."},
    "linux-x86_64-baseline":      {"...": "..."},
    "linux-x86_64-musl":          {"...": "..."},
    "linux-x86_64-baseline-musl": {"...": "..."},
    "linux-aarch64":              {"url": ".../opencode-linux-arm64.tar.gz", "...": "..."},
    "linux-aarch64-musl":         {"...": "..."}
  }
}
```

## Rules

- **Format** comes from the URL: `.zip` is unpacked with `ditto -x -k` on the Mac and `unzip` on
  a server; `.tar.gz` with `tar -xzf`. Any other suffix is refused when the manifest loads.
- **Choice**: for a host with the facts `{os, arch, avx2, musl}`, try
  `os-arch[-baseline if !avx2][-musl if musl]`, then drop `-baseline`, then drop `-musl`. Never
  choose a musl build for glibc, or the reverse, when both exist.
- **Checks**: `size` equals the downloaded bytes, `sha256` equals the digest, `command` is
  executable after unpacking. Then `ok` is written last.
- **Sources** accepted by `scripts/update-toolset.sh`: `https://dl.google.com/` (existing) and
  `https://github.com/<owner>/<repo>/releases/download/` (new). The digest is GitHub's `digest`
  field, never computed from a fresh download alone.
