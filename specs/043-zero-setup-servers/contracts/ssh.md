# Contract: SSH scripts for the Claude toolset

All run over 037's master with `SSHCommand.runArguments`, like `ServerInstaller`. `$T` is
`$HOME/.agents-server/tools/claude`. `umask 077` throughout (FR-004). Nothing here edits a
profile, rc file or PATH.

## § 1 Probe (added to 037's § 5 probe, same round trip — SC-002)

Five more lines after 037's:

```sh
ldd --version 2>&1 | head -1                     # "ldd (… GLIBC 2.36…) 2.36" | "musl libc …"
command -v curl || command -v wget || echo none  # downloader
t="$HOME/.agents-server/tools/claude/current"; [ -f "$t/ok" ] && readlink "$t" || echo none
$SHELL -lc 'command -v npx' >/dev/null 2>&1 && echo npx || echo none
{ [ -f "$HOME/.claude/.credentials.json" ] || $SHELL -lc '[ -n "$ANTHROPIC_API_KEY$CLAUDE_CODE_OAUTH_TOKEN" ]'; } && echo signed-in || echo none
```

Parsed into `ServerFacts` (data-model.md). The last line prints a word, never a value.

## § 2 Install (only when the probe's toolset id ≠ the app's)

Refused before any download (each a `HostProblem`):
- musl or glibc < 2.28 → `unsupportedLibc`
- no downloader → `noDownloader`
- free space < `minFreeBytes` (800 MB: the toolset is ~484 MB unpacked, plus download and cache) → `diskFullForTools`

Then one script, with `package.json` and `package-lock.json` streamed on stdin as a tar:

```sh
set -e; umask 077
T="$HOME/.agents-server/tools/claude"; P="$T/.part-<id>"
rm -rf "$P"; mkdir -p "$P"; trap 'rm -rf "$P"' EXIT
cd "$P"; mkdir lib; tar -xf - -C lib                      # package.json, package-lock.json (COPYFILE_DISABLE=1 tar --no-xattrs on the Mac)
fetch() { curl -fsSL "$1" || wget -qO- "$1"; }              # whichever the probe found
fetch "$MIRROR/<node-version>/node-<node-version>-linux-<arch>.tar.xz" > node.tar.xz || exit 21
echo "<sha256>  node.tar.xz" | sha256sum -c - >/dev/null      || exit 22
mkdir node; tar -xJf node.tar.xz -C node --strip-components=1; rm node.tar.xz
PATH="$P/node/bin:$PATH" npm ci --prefix "$P/lib" --ignore-scripts --omit=dev \
  --no-audit --no-fund --cache "$P/.npm" >"$P/npm.log" 2>&1  || { tail -5 "$P/npm.log" >&2; exit 23; }
rm -rf "$P/.npm"; : > "$P/ok"
trap - EXIT; mv "$P" "$T/<id>"
```

`$MIRROR` is `https://nodejs.org/dist` unless the fake-ssh fixture sets `AGENTS_TOOLS_MIRROR`
(and an npm registry via `npm_config_registry`) in the fake server's environment. The product
code passes whatever it finds there; it has no test switch of its own.

A toolset directory is only ever used if it has `ok`; a failure at any step leaves only `.part-*`,
which the `trap` removes (FR-006).

## § 3 Swap and tidy

```sh
set -e; T="$HOME/.agents-server/tools/claude"
ln -sfn '<id>' "$T/current"                      # when no Claude agent there is mid-turn
cd "$T" && for d in */; do d=${d%/}; [ "$d" = '<id>' ] || rm -rf -- "$d"; done   # after next good start
```

## § 4 Exit codes and stderr → sentences

| Cause | Sentence (`HostProblem+Words`) |
|---|---|
| exit 21, curl `Could not resolve host` / wget `unable to resolve` | "devbox can't reach the internet to download Claude." |
| exit 21, other | "devbox couldn't download Node.js: <last stderr line>." |
| exit 22 | "The download on devbox didn't match its checksum, so nothing was installed." |
| exit 23 with `EINTEGRITY` | same as exit 22 |
| exit 23, other | "Installing Claude on devbox failed: <last npm line>." |
| `No space left on device` anywhere | "devbox ran out of disk while installing Claude." |
| `unsupportedLibc` | "Claude can't be installed on devbox: it uses musl (Alpine). Install Claude there yourself to use it." |
| `noDownloader` | "devbox has neither curl nor wget to download Claude." |
| `diskFullForTools` | "devbox needs 800 MB free to install Claude, and has 120 MB." |

## § 5 Rebuilt server

On the Mac, not the server: `ssh-keygen -R <sshName>` and, when `ssh -G` resolves a port other
than 22, `ssh-keygen -R '[<host>]:<port>'`, against the person's own `known_hosts`
(`FAKE_SSH_KNOWN_HOSTS` under the fixture). Then 037's `HostKeyCheck.fetch` + `trust`.

## § 6 Purge

Unchanged from 037: `rm -rf "$HOME/.agents-server"`.
