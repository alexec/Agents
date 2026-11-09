package agentsd

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// #4178: a session reads a secret that does not ask with agents-secret NAME, through agentsd.
// Its environment holds a grant and no value; the value comes back exactly, and the read is
// recorded with the session and the name. A flagged secret, a name that is not set and a dropped
// grant get words and no value; a call with no grant asks a person (secretterminal_test.go).
func TestAgentsSecretReadsASecretThatDoesNotAsk(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	const plain, flagged, session = "plain-4178-not-real", "flagged-4178-not-real", "session-4178-not-real"
	if err := d.saveSecret("PLAIN_KEY", plain, false); err != nil {
		t.Fatal(err)
	}
	if err := d.saveSecret("FLAGGED_KEY", flagged, true); err != nil {
		t.Fatal(err)
	}
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	if err := d.setSessionSecret(a.ID, "SESSION_KEY", session, "", false); err != nil {
		t.Fatal(err)
	}

	stub := filepath.Join(t.TempDir(), "agentsd")
	os.WriteFile(stub, []byte("#!/bin/sh\necho \"agentsd $*\"\n"), 0o700)
	d.credentialSelf = stub
	env := d.withSecretCommand([]string{"PATH=/usr/bin:/bin"}, a.ID)
	joined := strings.Join(env, "\n")
	if strings.Contains(joined, plain) || strings.Contains(joined, flagged) || lastEnv(env, secretGrantEnv) == "" {
		t.Fatalf("the environment:\n%s", joined)
	}
	bin := filepath.Join(d.Store.Loc.Root, "runtimes", "secret")
	if !strings.HasPrefix(lastEnv(env, "PATH"), bin+":") {
		t.Fatalf("agents-secret is not first on PATH: %s", lastEnv(env, "PATH"))
	}
	cmd := exec.Command(filepath.Join(bin, "agents-secret"), "PLAIN_KEY")
	cmd.Env = env
	if out, err := cmd.CombinedOutput(); err != nil || strings.TrimSpace(string(out)) != "agentsd secret PLAIN_KEY" {
		t.Fatalf("the command on PATH: %v %s", err, out)
	}

	ask := func(name string, getenv func(string) string) (int, string, string) {
		var out, errOut bytes.Buffer
		code := SecretCommand([]string{name}, getenv, "", &out, &errOut)
		return code, out.String(), errOut.String()
	}
	fromSession := func(k string) string { return lastEnv(env, k) }
	if code, out, _ := ask("PLAIN_KEY", fromSession); code != 0 || out != plain {
		t.Fatalf("PLAIN_KEY: %d %q", code, out)
	}
	if code, out, _ := ask("SESSION_KEY", fromSession); code != 0 || out != session {
		t.Fatalf("SESSION_KEY: %d %q", code, out)
	}
	if code, out, said := ask("FLAGGED_KEY", fromSession); code != 1 || out != "" || strings.Contains(said, flagged) ||
		!strings.Contains(said, "Ask before use") || !strings.Contains(said, "fill_secret") || !strings.Contains(said, "set_ci_secret") {
		t.Fatalf("FLAGGED_KEY: %d %q %q", code, out, said)
	}
	if code, out, said := ask("MISSING_KEY", fromSession); code != 1 || out != "" || !strings.Contains(said, "not set") {
		t.Fatalf("MISSING_KEY: %d %q %q", code, out, said)
	}

	var reads []string
	for _, e := range secretEvents(d, "secret.read") {
		if e.Details["use"] == string(wire.SecretOperationUseCommand) {
			reads = append(reads, e.Details["name"]+" "+e.Details["place"]+" "+e.Details["agent"])
		}
	}
	if strings.Join(reads, ", ") != "PLAIN_KEY agents-secret "+string(a.ID)+", SESSION_KEY agents-secret "+string(a.ID) {
		t.Fatalf("the reads: %v", reads)
	}

	// The runtime ended: its grant asks nothing.
	d.dropCredentialGrants(a.ID)
	if code, out, said := ask("PLAIN_KEY", fromSession); code != 1 || out != "" || !strings.Contains(said, "grant") {
		t.Fatalf("a dropped grant: %d %q %q", code, out, said)
	}
	var out, errOut bytes.Buffer
	if code := SecretCommand(nil, fromSession, "", &out, &errOut); code != 2 || !strings.Contains(errOut.String(), "usage") {
		t.Fatalf("no name: %d %q", code, errOut.String())
	}
}
