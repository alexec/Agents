package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// secretEvents is the events of one name, oldest first.
func secretEvents(d *Daemon, name string) []wire.Event {
	d.eventMu.Lock()
	defer d.eventMu.Unlock()
	var out []wire.Event
	for _, e := range d.eventList {
		if e.Name == name {
			out = append(out, e)
		}
	}
	return out
}

// toldSecretOps hears each machine/secretOps call the daemon makes.
func toldSecretOps(d *Daemon) func() []wire.SecretOperation {
	var mu sync.Mutex
	var told []wire.SecretOperation
	d.SetControlAsk(func(_ context.Context, method string, params any) (json.RawMessage, error) {
		if call, ok := params.(wire.MachineSecretOpsCall); ok && method == wire.CallMachineSecretOps.Name {
			mu.Lock()
			told = append(told, call.Ops...)
			mu.Unlock()
		}
		return json.RawMessage(`{}`), nil
	})
	return func() []wire.SecretOperation {
		mu.Lock()
		defer mu.Unlock()
		return slices.Clone(told)
	}
}

// Each read and change of a secret is recorded (#4156): an event on the machine's stream, an
// operation for the control plane's audit (the reads a minute's batch, with a count), and the
// secret's last operation, removed with the secret. Neither the value nor its last four
// characters is in any of them.
func TestEachUseOfASecretIsRecorded(t *testing.T) {
	was := secretOpsBatch
	secretOpsBatch = 100 * time.Millisecond
	defer func() { secretOpsBatch = was }()
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	os.MkdirAll(filepath.Join(home, ".agents"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers":{
		"notes":{"url":"https://notes.example.com/${API_TOKEN}"},
		"docs":{"url":"https://docs.example.com/mcp","headers":{"Authorization":"Bearer ${DOCS_KEY}"}}}}`), 0o600)
	d, _ := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	told := toldSecretOps(d)
	values := []string{"flagged-4156-QX7Z", "docs-first-4156-WV3K", "docs-second-4156-JM8P", "session-4156-RB5T"}

	if err := d.saveSecret("API_TOKEN", values[0], true); err != nil {
		t.Fatal(err)
	}
	if err := d.saveSecret("DOCS_KEY", values[1], false); err != nil {
		t.Fatal(err)
	}
	if err := d.saveSecret("DOCS_KEY", values[2], false); err != nil {
		t.Fatal(err)
	}
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	if err := d.setSessionSecret(a.ID, "SESSION_KEY", values[3], "", false); err != nil {
		t.Fatal(err)
	}
	changed := secretEvents(d, "secret.changed")
	var changes []string
	for _, e := range changed {
		changes = append(changes, e.Details["name"]+" "+e.Details["change"])
	}
	if strings.Join(changes, ", ") != "API_TOKEN added, DOCS_KEY added, DOCS_KEY replaced, SESSION_KEY added" ||
		changed[3].Details["agent"] != string(a.ID) || changed[3].Details["machine"] == "" {
		t.Fatalf("%v %+v", changes, changed)
	}

	// The start gives the session its own secret and the docs server's header; the flagged
	// one waits for agentsd to fill it on each request.
	d.mcpServersFor(a.ID)
	reads := func() map[string]string {
		out := map[string]string{}
		for _, e := range secretEvents(d, "secret.read") {
			out[e.Details["name"]] = e.Details["use"] + " " + e.Details["place"] + " " + e.Details["agent"]
		}
		return out
	}
	if got := reads(); len(got) != 2 || got["SESSION_KEY"] != "env session "+string(a.ID) || got["DOCS_KEY"] != "env docs "+string(a.ID) {
		t.Fatal(got)
	}
	var p *secretProxy
	d.secretProxyMu.Lock()
	for _, x := range d.secretProxies {
		p = x
	}
	d.secretProxyMu.Unlock()
	if _, words := d.secretProxyValues(p); words == "" {
		t.Fatal("not asked")
	}
	answerUse(t, d, openSecretUse(t, d), secretUseSession)
	for range 3 {
		if _, words := d.secretProxyValues(p); words != "" {
			t.Fatal(words)
		}
	}
	if got := reads()["API_TOKEN"]; got != "mcp notes "+string(a.ID) {
		t.Fatal(got)
	}
	// A deny is recorded too.
	go d.askSecretUse(a.ID, "API_TOKEN", wire.SecretUseFill, "Example.com", time.Second)
	answerUse(t, d, openSecretUse(t, d), secretUseDeny)
	if denied := secretEvents(d, "secret.denied"); len(denied) != 1 || denied[0].Details["place"] != "example.com" || denied[0].Details["use"] != "fill" {
		t.Fatalf("%+v", denied)
	}

	// The audit: the changes and the deny at once, the reads in one batch, the MCP server's
	// three as one with a count.
	var ops []wire.SecretOperation
	waitFor(t, "the reads' batch", func() bool {
		ops = told()
		return len(ops) == 8
	})
	var mcp *wire.SecretOperation
	for i, op := range ops {
		if op.What == wire.SecretOperationWhatRead && op.Use != nil && *op.Use == wire.SecretOperationUseMCP {
			mcp = &ops[i]
		}
	}
	if mcp == nil || mcp.Count == nil || *mcp.Count != 3 || *mcp.Place != "notes" || *mcp.Agent != a.ID {
		t.Fatalf("%+v", ops)
	}

	// The last operation of each, kept on disk.
	if op, ok := d.secretLastOp("DOCS_KEY"); !ok || op.What != wire.SecretOperationWhatRead || *op.Use != wire.SecretOperationUseEnv || *op.Place != "docs" {
		t.Fatalf("%+v", op)
	}
	if err := d.removeSessionSecret(a.ID, "SESSION_KEY"); err != nil {
		t.Fatal(err)
	}
	if _, ok := d.secretLastOp("SESSION_KEY"); ok {
		t.Fatal("a removed secret kept its last operation")
	}
	raw, err := os.ReadFile(filepath.Join(d.Store.Loc.Root, "secret-ops.json"))
	if err != nil || !strings.Contains(string(raw), "DOCS_KEY") || strings.Contains(string(raw), "SESSION_KEY") {
		t.Fatal(string(raw), err)
	}

	// Never a value, never its hint.
	d.eventMu.Lock()
	events, _ := json.Marshal(d.eventList)
	d.eventMu.Unlock()
	sent, _ := json.Marshal(told())
	for _, v := range values {
		hint := v[len(v)-4:]
		for what, b := range map[string][]byte{"the events": events, "the audit": sent, "the record": raw} {
			if strings.Contains(string(b), hint) {
				t.Fatalf("%s have %s", what, hint)
			}
		}
	}
}

// set_ci_secret's read names the repo it went to.
func TestACISecretsReadIsRecorded(t *testing.T) {
	d, _, _, _ := forgeDaemon(t)
	a := seeded(t, d, gitFolder(t, "git@github.com:alexec/newapp.git"), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	if err := d.saveSecret("SENTRY_TOKEN", "sntrys_4156-not-real", false); err != nil {
		t.Fatal(err)
	}
	if _, err := d.setCISecret(a.ID, ciArgs("name", "SENTRY_AUTH_TOKEN", "secret", "SENTRY_TOKEN")); err != nil {
		t.Fatal(err)
	}
	read := secretEvents(d, "secret.read")
	if len(read) != 1 || read[0].Details["name"] != "SENTRY_TOKEN" || read[0].Details["use"] != "ci" || read[0].Details["place"] != "alexec/newapp" {
		t.Fatalf("%+v", read)
	}
}

// A sync of the person's secrets says what it added, replaced and removed here.
func TestUserSecretChanges(t *testing.T) {
	before := userSettingsSyncState{Secrets: []string{"A", "B", "C"}, Versions: map[string]int64{"A": 1, "B": 2, "C": 1}}
	after := userSettingsSyncState{Secrets: []string{"A", "B", "D"}, Versions: map[string]int64{"A": 1, "B": 3, "D": 1}}
	var got []string
	for _, c := range userSecretChanges(before, after) {
		got = append(got, c.name+" "+string(c.what))
	}
	if strings.Join(got, ", ") != "B replaced, D added, C removed" {
		t.Fatal(got)
	}
}
