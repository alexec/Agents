package agentsd

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/connections"
	"github.com/agentloops-dev/agents/Go/wire"
)

// lastEnv is name's value in env, the last one as exec takes it.
func lastEnv(env []string, name string) string {
	v := ""
	for _, kv := range env {
		if s, ok := strings.CutPrefix(kv, name+"="); ok {
			v = s
		}
	}
	return v
}

// An agent's gh and git ask the host for the App's token at each call (#3926): the agent's
// environment holds a grant and no token, each ask gets the token the host has now (a renewal
// is seen at once, as an 8-hour session needs), and the grant is dead once the runtime ends.
func TestAnAgentsGitAndGhAskForTheAppsToken(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	gh := &fakeSetupGitHub{}
	d.newSetupReader = func(string) setupReader { return gh }
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_one",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})

	// A stand-in agentsd for the gh that Agents writes, and a gh that says its token.
	tools := t.TempDir()
	stub := filepath.Join(tools, "agentsd")
	os.WriteFile(stub, []byte("#!/bin/sh\necho ghu_from_host\n"), 0o700)
	os.WriteFile(filepath.Join(tools, "gh"), []byte("#!/bin/sh\necho \"token=$GH_TOKEN args=$*\"\n"), 0o700)
	d.credentialSelf = stub
	agent := wire.UUID("agent-1")
	base := []string{"PATH=" + tools + ":/usr/bin:/bin", "GH_TOKEN=ghp_persons", "GIT_CONFIG_COUNT=1",
		"GIT_CONFIG_KEY_0=core.autocrlf", "GIT_CONFIG_VALUE_0=false"}

	// A folder the App is not installed on keeps the person's own gh and git.
	if env := d.withGitHubCredential(base, agent, gitFolder(t, "https://github.com/alexec/elsewhere.git")); len(env) != len(base) {
		t.Fatalf("the App does not reach this folder, yet: %v", env)
	}

	env := d.withGitHubCredential(base, agent, gitFolder(t, "https://github.com/alexec/agents-walk.git"))
	joined := strings.Join(env, "\n")
	if strings.Contains(joined, "ghu_one") || strings.Contains(joined, "ghp_persons") {
		t.Fatalf("a token is in the agent's environment:\n%s", joined)
	}
	if lastEnv(env, "GIT_CONFIG_COUNT") != "5" || lastEnv(env, "GIT_CONFIG_KEY_0") != "core.autocrlf" ||
		lastEnv(env, "GIT_CONFIG_KEY_1") != "credential.https://github.com.helper" || lastEnv(env, "GIT_CONFIG_VALUE_1") != "" ||
		lastEnv(env, "GIT_CONFIG_VALUE_2") != "!'"+stub+"' credential" ||
		lastEnv(env, "GIT_CONFIG_VALUE_3") != "!'"+filepath.Join(tools, "gh")+"' auth git-credential" ||
		lastEnv(env, "GIT_CONFIG_VALUE_4") != "true" {
		t.Fatalf("git's helper:\n%s", joined)
	}
	shim := filepath.Join(d.Store.Loc.Root, "runtimes", "github")
	if !strings.HasPrefix(lastEnv(env, "PATH"), shim+":") {
		t.Fatalf("the gh shim is not first on PATH: %s", lastEnv(env, "PATH"))
	}
	// The shim runs `agentsd credential gh <the real gh>`; with no agentsd it runs gh as the person.
	cmd := exec.Command(filepath.Join(shim, "gh"), "pr", "create")
	cmd.Env = env
	if out, err := cmd.CombinedOutput(); err != nil || strings.TrimSpace(string(out)) != "ghu_from_host" {
		t.Fatalf("gh through the shim: %v %s", err, out)
	}
	os.Remove(stub)
	cmd = exec.Command(filepath.Join(shim, "gh"), "pr", "create")
	cmd.Env = env
	if out, err := cmd.CombinedOutput(); err != nil || strings.TrimSpace(string(out)) != "token= args=pr create" {
		t.Fatalf("gh through the shim with no agentsd: %v %s", err, out)
	}

	// git's helper, as git runs it, asks the host and gets the token it has now.
	ask := func() string {
		var out bytes.Buffer
		in := strings.NewReader("protocol=https\nhost=github.com\npath=alexec/agents-walk.git\n\n")
		if code := CredentialCommand([]string{"get"}, func(k string) string { return lastEnv(env, k) }, in, &out); code != 0 {
			t.Fatalf("credential get: %d", code)
		}
		return out.String()
	}
	if got := ask(); got != "username=x-access-token\npassword=ghu_one\n" {
		t.Fatalf("first ask: %q", got)
	}
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_two",
		AccessExpiresAt: time.Now().Add(8 * time.Hour), ConnectedAt: time.Now()})
	if got := ask(); got != "username=x-access-token\npassword=ghu_two\n" {
		t.Fatalf("after the host renewed the token: %q", got)
	}
	var out bytes.Buffer
	if code := CredentialCommand([]string{"token"}, func(k string) string { return lastEnv(env, k) }, nil, &out); code != 0 || out.String() != "ghu_two\n" {
		t.Fatalf("credential token: %d %q", code, out.String())
	}
	// An install of the App that may not write code: git's ask gets nothing, so git asks the
	// person's own gh next (#4077); gh's ask still gets the App's token.
	gh.mu.Lock()
	gh.readOnly = true
	gh.mu.Unlock()
	d.credMu.Lock()
	d.appPush = nil
	d.credMu.Unlock()
	if got := ask(); got != "" {
		t.Fatalf("git got a token the App cannot push with: %q", got)
	}
	out.Reset()
	if code := CredentialCommand([]string{"token"}, func(k string) string { return lastEnv(env, k) }, nil, &out); code != 0 || out.String() != "ghu_two\n" {
		t.Fatalf("credential token on a read-only install: %d %q", code, out.String())
	}
	// Another host's request is not answered.
	out.Reset()
	CredentialCommand([]string{"get"}, func(k string) string { return lastEnv(env, k) }, strings.NewReader("protocol=https\nhost=gitlab.com\n"), &out)
	if out.Len() != 0 {
		t.Fatalf("gitlab.com got %q", out.String())
	}

	// The runtime ended: its grant asks nothing.
	d.dropCredentialGrants(agent)
	if got := ask(); got != "" {
		t.Fatalf("a dropped grant got %q", got)
	}
}

func TestGitConfigFromTheEnvironmentCountsOnFromWhatIsThere(t *testing.T) {
	env := withGitConfig([]string{"A=1"}, "x.y", "1", "x.z", "")
	if strings.Join(env, " ") != "A=1 GIT_CONFIG_KEY_0=x.y GIT_CONFIG_VALUE_0=1 GIT_CONFIG_KEY_1=x.z GIT_CONFIG_VALUE_1= GIT_CONFIG_COUNT=2" {
		t.Fatalf("%v", env)
	}
}

// When GitHub refuses the App a thing the person may do (a job's rerun, #4077), the agent's gh
// runs it once more with the person's own login; not when it made something, read stdin, or
// failed for another reason.
func TestAnAgentsGhRunsAgainAsThePersonWhenGitHubRefusesTheApp(t *testing.T) {
	host := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "ghu_app")
	}))
	defer host.Close()
	getenv := func(k string) string {
		return map[string]string{credentialURLEnv: host.URL, credentialGrantEnv: "grant"}[k]
	}
	// A gh that GitHub refuses with the App's token, and that says how it ran.
	gh := filepath.Join(t.TempDir(), "gh")
	os.WriteFile(gh, []byte(`#!/bin/sh
echo "ran token=$GH_TOKEN" >>"$(dirname "$0")/log"
if [ -n "$GH_TOKEN" ]; then
	case "$1" in
	made) echo https://github.com/alexec/Agents/pull/1 ;;
	other) echo "HTTP 404: Not Found" >&2; exit 1 ;;
	esac
	echo "HTTP 403: Resource not accessible by integration" >&2
	exit 1
fi
echo "done as the person"
`), 0o700)
	for _, c := range []struct {
		args  []string
		code  int
		runs  string
		saysT string
	}{
		{[]string{"run", "rerun", "1", "--failed"}, 0, "ran token=ghu_app\nran token=\n", "done as the person"},
		{[]string{"made"}, 1, "ran token=ghu_app\n", "pull/1"},
		{[]string{"other"}, 1, "ran token=ghu_app\n", ""},
		{[]string{"pr", "comment", "1", "--body-file", "-"}, 1, "ran token=ghu_app\n", ""},
	} {
		os.Remove(filepath.Join(filepath.Dir(gh), "log"))
		var stdout, stderr bytes.Buffer
		code := runGH(gh, c.args, getenv, strings.NewReader(""), &stdout, &stderr)
		runs, _ := os.ReadFile(filepath.Join(filepath.Dir(gh), "log"))
		if code != c.code || string(runs) != c.runs || !strings.Contains(stdout.String(), c.saysT) {
			t.Fatalf("gh %v: %d, runs %q, stdout %q, stderr %q", c.args, code, runs, stdout.String(), stderr.String())
		}
	}
}
