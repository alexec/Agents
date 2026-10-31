package hostinstall

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// A stand-in for /usr/bin/ssh, as AgentsKit's Tests/Fixtures/ssh/ssh is: not the
// protocol, but the "remote" command run here under a fake home, which is all an install
// asks ssh to do.
//
//	FAKE_SSH_DIR           this folder: host_key.pub, stderr/, bin/
//	FAKE_SSH_HOME          the server's $HOME
//	FAKE_SSH_FAIL          a file in stderr/ to print, then exit 255, for every call
//	FAKE_SSH_UNAME         what `uname -sm` says on the server (default "Linux aarch64")
//	FAKE_SSH_PROXYJUMP     what `ssh -G` says as proxyjump (default none)
//	FAKE_SSH_KNOWN_HOSTS   what `ssh -G` says as userknownhostsfile
//	FAKE_SSH_PERSON_KNOWS  the person's known_hosts has the server's key
//	FAKE_SSH_LOG           each call's agent and argv, one line each
const fakeSSH = `#!/bin/sh
[ -n "$FAKE_SSH_LOG" ] && printf 'agent=%s %s\n' "${SSH_AUTH_SOCK:-}" "$*" >> "$FAKE_SSH_LOG"
resolve=0; knownhosts=""; auth=""; strict=""
while [ $# -gt 0 ]; do
    case "$1" in
        -G) resolve=1 ;;
        -i|-F|-S|-O|-L|-R|-J|-p|-l) shift ;;
        -o) shift
            case "$1" in
                UserKnownHostsFile=*) [ -z "$knownhosts" ] && knownhosts="${1#UserKnownHostsFile=}" ;;
                PreferredAuthentications=*) auth="${1#PreferredAuthentications=}" ;;
                StrictHostKeyChecking=*) [ -z "$strict" ] && strict="${1#StrictHostKeyChecking=}" ;;
            esac ;;
        --) shift; break ;;
        -*) ;;
        *) break ;;
    esac
    shift
done
name="$1"; [ $# -gt 0 ] && shift

if [ -n "$FAKE_SSH_FAIL" ]; then
    cat "$FAKE_SSH_DIR/stderr/$FAKE_SSH_FAIL.txt" >&2
    exit 255
fi
if [ $resolve = 1 ]; then
    printf 'user agents\nhostname %s\nport 22\n' "$name"
    printf 'userknownhostsfile %s\nproxyjump %s\n' "${FAKE_SSH_KNOWN_HOSTS:-~/.ssh/known_hosts ~/.ssh/known_hosts2}" "${FAKE_SSH_PROXYJUMP:-none}"
    exit 0
fi
key=$(cat "$FAKE_SSH_DIR/host_key.pub")
# Learning the host key: write it down, offer no credentials, fail.
if [ "$auth" = none ] && [ -n "$knownhosts" ]; then
    printf '%s %s\n' "$name" "$key" > "$knownhosts"
    echo "$name: Permission denied (publickey)." >&2
    exit 255
fi
if [ "$strict" = yes ]; then
    if [ -f "$knownhosts" ] && grep -qF "$key" "$knownhosts"; then :
    elif [ -n "$FAKE_SSH_PERSON_KNOWS" ]; then :
    else
        echo "No ED25519 host key is known for $name and you have requested strict checking." >&2
        echo "Host key verification failed." >&2
        exit 255
    fi
fi
cd "$FAKE_SSH_HOME" || exit 255
HOME="$FAKE_SSH_HOME" PATH="$FAKE_SSH_DIR/bin:$PATH" exec /bin/sh -c "$*"
`

// hostKey is AgentsKit's Fixtures/ssh/host_key.pub, and its fingerprint as ssh-keygen
// prints it.
const (
	hostKey            = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOk02NMrVRXm1v6S2+afM99ykoReWOycAgdu4X/BwVdc"
	hostKeyFingerprint = "SHA256:fJud2RPDYaER7lxf0N2a1Es35w42PSP32KO1+BhMPCs"
)

// stderrFixtures are AgentsKit's Fixtures/ssh/stderr: what ssh says for each failure.
var stderrFixtures = map[string]string{
	"unknownHost":    "ssh: Could not resolve hostname nosuchhost.invalid: nodename nor servname provided, or not known\n",
	"timedOut":       "ssh: connect to host devbox port 22: Operation timed out\n",
	"refused":        "ssh: connect to host 127.0.0.1 port 9: Connection refused\n",
	"loginRefused":   "alex@devbox: Permission denied (publickey).\n",
	"hostKeyUnknown": "No ED25519 host key is known for [127.0.0.1]:2222 and you have requested strict checking.\nHost key verification failed.\n",
	"hostKeyChanged": "@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" +
		"@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n" +
		"@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@\n" +
		"Host key for devbox has changed and you have requested strict checking.\nHost key verification failed.\n",
	"noStreamLocalForwarding": "channel 2: open failed: administratively prohibited: open failed\n",
	"diskFull":                "cat: write error: No space left on device\n",
}

// fake is one fake ssh and its server, with a server folder to install from.
type fake struct {
	t       *testing.T
	dir     string
	home    string
	servers string
	log     string
	env     map[string]string
	sha     string
}

func newFake(t *testing.T) *fake {
	t.Helper()
	dir := t.TempDir()
	f := &fake{t: t, dir: dir, home: filepath.Join(dir, "home"), servers: filepath.Join(dir, "servers"),
		log: filepath.Join(dir, "ssh.log"), env: map[string]string{}}
	f.write("ssh", fakeSSH, 0o755)
	f.write("host_key.pub", hostKey+"\n", 0o644)
	for name, text := range stderrFixtures {
		f.write("stderr/"+name+".txt", text, 0o644)
	}
	f.write("bin/uname", "#!/bin/sh\necho \"${FAKE_SSH_UNAME:-Linux aarch64}\"\n", 0o755)
	if err := os.MkdirAll(f.home, 0o755); err != nil {
		t.Fatal(err)
	}
	// The host is a script that says how it was started.
	agentsd := "#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$HOME/started-args\"\n"
	f.write("servers/VERSION", "1.2.3\n", 0o644)
	f.write("servers/agentsd-linux-aarch64", agentsd, 0o755)
	f.sha = sum(agentsd)
	f.write("servers/agentsd-linux-aarch64.sha256", f.sha+"\n", 0o644)
	f.write("servers/github-mcp-linux-aarch64", "#!/bin/sh\n", 0o755)
	f.write("servers/github-mcp-linux-aarch64.sha256", sum("#!/bin/sh\n")+"\n", 0o644)
	// Install folders are made here, so a test can see that none is left.
	t.Setenv("TMPDIR", filepath.Join(dir, "tmp"))
	if err := os.MkdirAll(filepath.Join(dir, "tmp"), 0o700); err != nil {
		t.Fatal(err)
	}
	return f
}

func sum(text string) string {
	s := sha256.Sum256([]byte(text))
	return hex.EncodeToString(s[:])
}

func (f *fake) write(name, text string, mode os.FileMode) {
	f.t.Helper()
	p := filepath.Join(f.dir, name)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		f.t.Fatal(err)
	}
	if err := os.WriteFile(p, []byte(text), mode); err != nil {
		f.t.Fatal(err)
	}
}

func (f *fake) environ() []string {
	env := append(os.Environ(), "FAKE_SSH_DIR="+f.dir, "FAKE_SSH_HOME="+f.home, "FAKE_SSH_LOG="+f.log,
		"SSH_AUTH_SOCK=/tmp/agent.sock")
	for k, v := range f.env {
		env = append(env, k+"="+v)
	}
	return env
}

func (f *fake) logged() string {
	data, _ := os.ReadFile(f.log)
	return string(data)
}

func (f *fake) server(path string) string { return filepath.Join(f.home, ".agents-server", path) }

func (f *fake) leftInstallFolders() []string {
	entries, _ := os.ReadDir(filepath.Join(f.dir, "tmp"))
	var left []string
	for _, e := range entries {
		left = append(left, e.Name())
	}
	return left
}

// fakeCodes is a CodeIssuer that says what it was asked.
type fakeCodes struct {
	mu   sync.Mutex
	urls []string
}

func (c *fakeCodes) HostCode(ctx context.Context, url string) (string, string, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.urls = append(c.urls, url)
	return "agents-control:2:h:-:key:secret:" + url + ":-:test", "code-id", nil
}

// fakeTunnels is a Tunnels that keeps what it was given, and calls onAdd at each Add.
type fakeTunnels struct {
	added []TunnelRecord
	letGo []string
	onAdd func()
}

func (t *fakeTunnels) Port() int { return 8443 }

func (t *fakeTunnels) LetGo(ctx context.Context, destination, name string) {
	t.letGo = append(t.letGo, destination)
}

func (t *fakeTunnels) Add(ctx context.Context, record TunnelRecord) error {
	if t.onAdd != nil {
		t.onAdd()
	}
	t.added = append(t.added, record)
	return nil
}

// installer is an Installer on the fake, which records its progress steps.
func (f *fake) installer(codes *fakeCodes, steps *[]string) *Installer {
	return &Installer{Codes: codes, ServerFolder: f.servers, SSH: filepath.Join(f.dir, "ssh"),
		ConfigFile: filepath.Join(f.dir, "no-config"), Env: f.environ(),
		Progress: func(name, step string) { *steps = append(*steps, name+":"+step) }}
}

func contains(all []string, s string) bool {
	for _, a := range all {
		if a == s {
			return true
		}
	}
	return false
}
