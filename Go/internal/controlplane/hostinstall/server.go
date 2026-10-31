package hostinstall

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// facts is the part of ServerFacts an install reads: what the probe found.
type facts struct {
	system           string
	architecture     string
	home             string
	freeBytes        int64
	installedVersion *string
	installedSHA256  *string
	// False only when sshd_config turns Unix-socket forwarding off.
	streamLocalForwarding bool
	// The 043 lines the toolset installer reads: the C library, curl or wget, and the
	// toolset each runtime's current points at.
	glibc      [2]int
	musl       bool
	downloader string
	toolsets   map[string]string
	// xz: the server can unpack Node's .tar.xz. Without it the control plane does.
	xz bool
}

// binarySuffix is Architecture.binarySuffix: the suffix of the binary built for it, or
// "" for a machine the host is not built for.
func binarySuffix(uname string) string {
	switch uname {
	case "x86_64", "amd64":
		return "x86_64"
	case "aarch64", "arm64":
		return "aarch64"
	}
	return ""
}

// displayArchitecture is Architecture.display: how Settings writes it.
func displayArchitecture(uname string) string {
	switch binarySuffix(uname) {
	case "x86_64":
		return "x86-64"
	case "aarch64":
		return "ARM64"
	}
	return uname
}

// toolsetRuntimes is ServerInstaller.toolsetRuntimes: every runtime the app installs as
// a toolset, by name, whose current the probe reads (046).
const toolsetRuntimes = "antigravity claude codex opencode"

// probeScript is ServerInstaller.probeScript (037, contracts/ssh.md § 5).
const probeScript = `uname -sm; printf '%s\n' "$HOME"; df -Pk "$HOME" | tail -1; ` +
	`tr -d '\n' < "$HOME/.agents-server/install.json" 2>/dev/null; echo; ` +
	`grep -i '^[[:space:]]*AllowStreamLocalForwarding' /etc/ssh/sshd_config 2>/dev/null || echo default; ` +
	`printf 'libc:%s\n' "$(ldd --version 2>&1 | head -1)"; ` +
	`printf 'fetch:%s\n' "$(command -v curl || command -v wget || echo none)"; ` +
	`grep -qsw avx2 /proc/cpuinfo && echo avx2:yes || { [ -r /proc/cpuinfo ] && echo avx2:no || echo avx2:unknown; }; ` +
	`t="$HOME/.agents-server/tools/claude/current"; ` +
	`printf 'toolset:%s\n' "$([ -f "$t/ok" ] && basename "$(readlink "$t")" || echo none)"; ` +
	`for r in ` + toolsetRuntimes + `; do t="$HOME/.agents-server/tools/$r/current"; ` +
	`printf 'toolset.%s:%s\n' "$r" "$([ -f "$t/ok" ] && basename "$(readlink "$t")" || echo none)"; done; ` +
	`${SHELL:-/bin/sh} -lc 'command -v npx >/dev/null 2>&1 && echo npx:yes || echo npx:no; ` +
	`[ -n "$ANTHROPIC_API_KEY$CLAUDE_CODE_OAUTH_TOKEN" ] && echo signin:env || echo signin:none' 2>/dev/null </dev/null; ` +
	`[ -f "$HOME/.claude/.credentials.json" ] && echo signin:file || echo signin:none; ` +
	`[ -f "$HOME/.codex/auth.json" ] && echo signin.codex:file || echo signin.codex:none; ` +
	// Go's own (#1136): whether the server can unpack Node's .tar.xz itself.
	`command -v xz >/dev/null 2>&1 && echo xz:yes || echo xz:no`

// installer is ServerInstaller: what goes on a server, in ~/.agents-server, private to
// the person's account. A binary arrives as a .part and is renamed only once its
// checksum matches, and current moves last.
type installer struct{ ssh sshCommand }

// probe is ServerInstaller.probe. ssh itself failing (255), or nothing at all coming
// back, is said from ssh's own words (#514).
func (i installer) probe(ctx context.Context) (*facts, error) {
	out, err := i.run(ctx, probeScript)
	if err != nil {
		return nil, err
	}
	if out.status == 255 || (out.status != 0 && out.stdout == "") {
		if p := classify(out.status, out.stderr, true); p != nil {
			return nil, p
		}
	}
	return parseProbe(out.stdout)
}

// parseProbe is ServerInstaller.parseProbe: the first five lines by position, then the
// 043 lines the toolset installer reads (libc, fetch, toolsets) by key, as
// readClaudeLines finds them, because a login shell may print a banner of its own.
func parseProbe(text string) (*facts, error) {
	all := strings.Split(text, "\n")
	if len(all) < 5 {
		if text == "" {
			return nil, installFailed("The server sent nothing back.")
		}
		return nil, installFailed(text)
	}
	uname := strings.Split(all[0], " ")
	if len(uname) != 2 || !strings.HasPrefix(all[1], "/") {
		return nil, installFailed(text)
	}
	// POSIX df -P: filesystem, 1024-blocks, used, available, capacity, mounted on.
	df := strings.Fields(all[2])
	var free int64
	if len(df) >= 4 {
		free, _ = strconv.ParseInt(df[3], 10, 64)
	}
	f := &facts{system: uname[0], architecture: uname[1], home: all[1], freeBytes: free * 1024}
	if all[3] != "" {
		var record installRecord
		if json.Unmarshal([]byte(all[3]), &record) == nil && record.complete() {
			f.installedVersion, f.installedSHA256 = &record.Version, &record.SHA256
		}
	}
	forwarding := strings.ToLower(all[4])
	off := strings.Contains(forwarding, "allowstreamlocalforwarding") &&
		(strings.HasSuffix(forwarding, " no") || strings.HasSuffix(forwarding, " local"))
	f.streamLocalForwarding = !off
	f.toolsets = map[string]string{}
	for _, line := range all[5:] {
		key, value, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		value = strings.TrimSpace(value)
		switch {
		case key == "libc":
			parseLibc(value, f)
		case key == "xz":
			f.xz = value == "yes"
		case key == "fetch":
			if value != "none" && value != "" {
				f.downloader = filepath.Base(value)
			}
		case strings.HasPrefix(key, "toolset."):
			if value != "none" && value != "" {
				f.toolsets[strings.TrimPrefix(key, "toolset.")] = value
			}
		}
	}
	return f, nil
}

// installRecord is ServerInstaller.InstallRecord: install.json, the version and checksum
// current points at.
type installRecord struct {
	Version     string `json:"version"`
	SHA256      string `json:"sha256"`
	InstalledAt string `json:"installedAt"`
	InstalledBy string `json:"installedBy"`
}

// complete: Swift's decode wants every field.
func (r installRecord) complete() bool {
	return r.Version != "" && r.SHA256 != "" && r.InstalledAt != "" && r.InstalledBy != ""
}

// binaryName is ServerInstaller.binaryName: agentsd- and the first sixteen characters
// of its SHA-256, its identity.
func binaryName(sha string) string {
	if len(sha) > 16 {
		sha = sha[:16]
	}
	return "agentsd-" + sha
}

// install is ServerInstaller.install: stream binary to bin/agentsd-<sha>. A mismatched
// checksum is an install that failed; on a first install nothing is left, on an update
// the old one is untouched.
func (i installer) install(ctx context.Context, binary, sha string, firstInstall bool) error {
	name := binaryName(sha)
	script := `set -e; umask 077; d="$HOME/.agents-server"; mkdir -p "$d/bin" "$d/root"; ` +
		`chmod 700 "$d" "$d/bin" "$d/root"; ` +
		`f="$d/bin/.` + name + `.part"; cat > "$f"; ` +
		`echo "` + sha + `  $f" | sha256sum -c - >/dev/null; ` +
		`chmod 700 "$f"; mv "$f" "$d/bin/` + name + `"`
	out, err := i.ssh.run(ctx, i.ssh.runArguments(script), binary)
	if err != nil {
		return err
	}
	if out.status == 0 {
		return nil
	}
	if firstInstall {
		i.run(ctx, `rm -rf "$HOME/.agents-server"`)
	} else {
		i.run(ctx, `rm -f "$HOME"/.agents-server/bin/.agentsd-*.part`)
	}
	if strings.Contains(out.stderr, "FAILED") || strings.Contains(out.stderr, "checksum") {
		return installFailed("The copy on the server did not match. Nothing was changed.")
	}
	return orFailed(classify(out.status, out.stderr, true), out.stderr)
}

// installServer is ServerInstaller.installServer: an MCP server Agents ships (#700) at
// bin/<name>, beside agentsd. A copy with this checksum is left as it is.
func (i installer) installServer(ctx context.Context, name, binary, sha string) error {
	target := "$HOME/.agents-server/bin/" + name
	present, err := i.run(ctx, `sha256sum "`+target+`" 2>/dev/null | cut -d' ' -f1`)
	if err != nil {
		return err
	}
	if present.status == 0 && strings.TrimSpace(present.stdout) == sha {
		return nil
	}
	script := `set -e; umask 077; d="$HOME/.agents-server/bin"; mkdir -p "$d"; ` +
		`f="$d/.` + name + `.part"; cat > "$f"; ` +
		`echo "` + sha + `  $f" | sha256sum -c - >/dev/null || { rm -f "$f"; exit 1; }; ` +
		`chmod 700 "$f"; mv "$f" "$d/` + name + `"`
	out, err := i.ssh.run(ctx, i.ssh.runArguments(script), binary)
	if err != nil {
		return err
	}
	if out.status != 0 {
		return orFailed(classify(out.status, out.stderr, true), name+" did not copy: "+out.stderr)
	}
	return nil
}

// swapCurrent is ServerInstaller.swapCurrent: point current at an installed binary and
// record which it is. Last, so a failure before it leaves the old one running.
func (i installer) swapCurrent(ctx context.Context, sha, version, installedBy string) error {
	record := installRecord{Version: version, SHA256: sha, InstalledAt: time.Now().UTC().Format("2006-01-02T15:04:05Z"),
		InstalledBy: installedBy}
	data, err := json.Marshal(record)
	if err != nil {
		return err
	}
	return i.check(ctx, `set -e; d="$HOME/.agents-server"; ln -sfn `+quote(binaryName(sha))+` "$d/bin/current"; `+
		`printf '%s\n' `+quote(string(data))+` > "$d/install.json.part"; mv "$d/install.json.part" "$d/install.json"`)
}

// leaveJoinCode is ServerInstaller.leaveJoinCode: a one-time host code where the daemon
// reads it on its next start, never on its command line, where ps would show it. A
// host already running there stops; the one started next takes the code.
//
// The lock's pid is stopped only when it is an agentsd of .agents-server (#1701): a
// workspace whose container is made again at each start keeps the lock in its home, and
// in the new container that pid can be another process, such as the sshd of this very
// connection.
func (i installer) leaveJoinCode(ctx context.Context, code string) error {
	return i.check(ctx, `umask 077; d="$HOME/.agents-server/root"; mkdir -p "$d"; `+stopScript+
		`rm -f "$d/control-host.json"; printf %s `+quote(code)+` > "$d/control-join-code"`)
}

// stopScript stops the host running in $d, the root, when there is one: by the lock's
// pid, and only when that pid is an agentsd of .agents-server.
const stopScript = `if [ -f "$d/daemon.lock" ]; then p=$(cat "$d/daemon.lock" 2>/dev/null || true); ` +
	`case "$p" in ''|*[!0-9]*) p="" ;; esac; ` +
	`if [ -n "$p" ] && { if [ -r "/proc/$p/cmdline" ]; then tr '\000' ' ' < "/proc/$p/cmdline"; ` +
	`else ps -o args= -p "$p" 2>/dev/null; fi; } | grep -q '\.agents-server/'; then ` +
	`kill "$p" 2>/dev/null && sleep 1; fi; fi; `

// stopRunning stops the host running on the server, for an update (#1766): its root and
// membership stay, so the one started next is the same host.
func (i installer) stopRunning(ctx context.Context) error {
	return i.check(ctx, `d="$HOME/.agents-server/root"; `+stopScript+`true`)
}

// isHost is whether the server's root holds this host's membership (#1766): an update
// goes to no other server.
func (i installer) isHost(ctx context.Context, host, name string) error {
	out, err := i.run(ctx, `cat "$HOME/.agents-server/root/control-host.json" 2>/dev/null || true`)
	if err != nil {
		return err
	}
	var member struct {
		Host string `json:"host"`
	}
	if json.Unmarshal([]byte(out.stdout), &member) != nil || member.Host == "" {
		return &Failure{Code: NotAllowed, Message: "That server has no host of this control plane, so it is not " + name + ". Check the server and try again."}
	}
	if member.Host != host {
		return &Failure{Code: NotAllowed, Message: "That server is another host of this control plane, not " + name + ". Check the server and try again."}
	}
	return nil
}

// startDaemon is ServerInstaller.startDaemon: the server's daemon, in the background.
func (i installer) startDaemon(ctx context.Context, extra ...string) error {
	tail := ""
	for _, e := range extra {
		tail += " " + quote(e)
	}
	return i.check(ctx, `"$HOME/.agents-server/bin/current" --root "$HOME/.agents-server/root" --serve --detach`+tail)
}

func (i installer) run(ctx context.Context, script string) (output, error) {
	return i.ssh.run(ctx, i.ssh.runArguments(script), "")
}

func (i installer) check(ctx context.Context, script string) error {
	out, err := i.run(ctx, script)
	if err != nil {
		return err
	}
	if out.status != 0 {
		return orFailed(classify(out.status, out.stderr, true), out.stderr)
	}
	return nil
}

func orFailed(p *Problem, words string) *Problem {
	if p != nil {
		return p
	}
	return installFailed(words)
}

// quote is ServerInstaller.quote: one argument to the server's shell, whatever it
// holds. A Mac's name can have an apostrophe in it.
func quote(text string) string {
	return "'" + strings.ReplaceAll(text, "'", `'\''`) + "'"
}

// shippedServers is ServerFiles.shippedServers: the MCP servers Agents ships (#700).
var shippedServers = []string{"github-mcp", "linear-mcp", "gitlab-mcp", "email-mcp"}

// serverFileNames is ServerFiles.names: the only files read from the server folder.
var serverFileNames = func() map[string]bool {
	names := map[string]bool{"VERSION": true}
	for _, arch := range []string{"x86_64", "aarch64"} {
		for _, program := range append([]string{"agentsd"}, shippedServers...) {
			names[program+"-linux-"+arch] = true
			names[program+"-linux-"+arch+".sha256"] = true
		}
	}
	return names
}()

// readServerFile is ServerFiles.read: a file by name, from the folder, never a path
// the request made up.
func readServerFile(name, folder string) (string, bool) {
	if !serverFileNames[name] || folder == "" {
		return "", false
	}
	data, err := os.ReadFile(filepath.Join(folder, name))
	return string(data), err == nil
}

// serverBinary is ServerFiles.binary: the host for arch, with its checksum and the
// version beside them.
type serverBinary struct{ file, sha256, version string }

func binaryFor(arch, folder string) (serverBinary, bool) {
	sha, ok := readServerFile("agentsd-linux-"+arch+".sha256", folder)
	if !ok {
		return serverBinary{}, false
	}
	version, ok := readServerFile("VERSION", folder)
	if !ok {
		version = "0"
	}
	return serverBinary{filepath.Join(folder, "agentsd-linux-"+arch), strings.TrimSpace(sha), strings.TrimSpace(version)}, true
}

// shippedFor is ServerFiles.shippedServers(for:in:): the shipped servers the folder has
// for arch, each with its checksum.
func shippedFor(arch, folder string) []struct{ name, file, sha256 string } {
	var all []struct{ name, file, sha256 string }
	for _, name := range shippedServers {
		if sha, ok := readServerFile(name+"-linux-"+arch+".sha256", folder); ok {
			all = append(all, struct{ name, file, sha256 string }{name, filepath.Join(folder, name+"-linux-"+arch), strings.TrimSpace(sha)})
		}
	}
	return all
}

// fetchHostKey is HostKeyCheck.fetch: connect only far enough to be shown the key, into
// a file in folder, and read its SHA-256 fingerprint. The connection fails at
// authentication; what matters is that the key was written down first.
func fetchHostKey(ctx context.Context, ssh sshCommand, folder string) (file, fingerprint string, err error) {
	f, err := os.CreateTemp(folder, "hostkey-")
	if err != nil {
		return "", "", err
	}
	f.Close()
	file = f.Name()
	out, err := ssh.run(ctx, ssh.keyFetchArguments(file), "")
	if err != nil {
		os.Remove(file)
		return "", "", err
	}
	written, _ := os.ReadFile(file)
	if strings.TrimSpace(string(written)) == "" {
		os.Remove(file)
		status := out.status
		if status == 0 {
			status = 255
		}
		return "", "", orFailed(classify(status, out.stderr, agentHasKeys(ctx, ssh.env)), out.stderr)
	}
	fingerprint, ok := knownHostsFingerprint(string(written))
	if !ok {
		os.Remove(file)
		return "", "", installFailed("The server’s host key could not be read.")
	}
	return file, fingerprint, nil
}

// knownHostsFingerprint is what `ssh-keygen -lf <known_hosts> -E sha256` says of the
// first key: "SHA256:" and the unpadded base64 of the key's SHA-256.
func knownHostsFingerprint(text string) (string, bool) {
	for _, line := range lines(text) {
		fields := strings.Fields(line)
		if len(fields) == 0 || strings.HasPrefix(fields[0], "#") {
			continue
		}
		// [marker] hosts keytype key [comment]
		if strings.HasPrefix(fields[0], "@") {
			fields = fields[1:]
		}
		if len(fields) < 3 {
			continue
		}
		blob, err := base64.StdEncoding.DecodeString(fields[2])
		if err != nil {
			continue
		}
		sum := sha256.Sum256(blob)
		return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:]), true
	}
	return "", false
}
