package agentsd

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
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
	d.newSetupReader = func(string) setupReader { return &fakeSetupGitHub{} }
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
	if lastEnv(env, "GIT_CONFIG_COUNT") != "4" || lastEnv(env, "GIT_CONFIG_KEY_0") != "core.autocrlf" ||
		lastEnv(env, "GIT_CONFIG_KEY_1") != "credential.https://github.com.helper" || lastEnv(env, "GIT_CONFIG_VALUE_1") != "" ||
		lastEnv(env, "GIT_CONFIG_VALUE_2") != "!'"+stub+"' credential" || lastEnv(env, "GIT_CONFIG_VALUE_3") != "true" {
		t.Fatalf("git's helper:\n%s", joined)
	}
	shim := filepath.Join(d.Store.Loc.Root, "runtimes", "github")
	if !strings.HasPrefix(lastEnv(env, "PATH"), shim+":") {
		t.Fatalf("the gh shim is not first on PATH: %s", lastEnv(env, "PATH"))
	}
	cmd := exec.Command(filepath.Join(shim, "gh"), "pr", "create")
	cmd.Env = env
	if out, err := cmd.CombinedOutput(); err != nil || strings.TrimSpace(string(out)) != "token=ghu_from_host args=pr create" {
		t.Fatalf("gh through the shim: %v %s", err, out)
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
	// Another host's request is not answered.
	out.Reset()
	CredentialCommand([]string{"get"}, func(k string) string { return lastEnv(env, k) }, strings.NewReader("protocol=https\nhost=gitlab.com\n"), &out)
	if out.Len() != 0 {
		t.Fatalf("gitlab.com got %q", out.String())
	}

	// The runtime ended: its grant asks nothing.
	d.dropGitHubCredential(agent)
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
