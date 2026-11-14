package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// heldReply is one app tool's answer.
type heldReply struct {
	text  string
	isErr bool
}

// toolAsync is an app tool's call on its own goroutine, as an agent's held call.
func toolAsync(m *mcpClient, id int, name string, args map[string]any) chan heldReply {
	done := make(chan heldReply, 1)
	go func() {
		text, isErr := m.tool(id, name, args)
		done <- heldReply{text, isErr}
	}()
	return done
}

func heldReplyOf(t *testing.T, done chan heldReply) heldReply {
	t.Helper()
	select {
	case r := <-done:
		return r
	case <-time.After(30 * time.Second):
		t.Fatal("the held call never answered")
	}
	return heldReply{}
}

// #4538: a workflow that is the person's to turn on (its file says enabled: false) is asked
// for by a Needs you card. Approve turns it on, as the person's own switch does; Deny leaves
// it off and says so.
func TestAnAgentAsksThePersonToTurnOnAWorkflow(t *testing.T) {
	fakeRuntimes(t)
	formHolds(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	url := store.FolderURL(dir)
	os.MkdirAll(workflowsFolder(dir), 0o755)
	for _, id := range []string{"codes", "other"} {
		os.WriteFile(filepath.Join(workflowsFolder(dir), id+".md"), []byte("---\non: manual\nenabled: false\n---\nx\n"), 0o644)
	}
	approveAll(t, c, url)
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	done := toolAsync(m, 2, "manage_workflows", map[string]any{"action": "enable", "id": "codes"})
	r := openSecretUse(t, d)
	s := r.Detail.SecretUse
	if r.Kind != wire.RequestKindApprove || s.Use != wire.SecretUseWorkflow || s.Name != "codes" || s.Place != filepath.Base(dir) ||
		r.Title != "Turn on the workflow codes in "+filepath.Base(dir) || r.AskedBy == nil || *r.AskedBy != a.ID {
		t.Fatalf("%+v %+v", r, s)
	}
	if on, _ := d.oneWorkflow(dir, "codes"); on.IsEnabled {
		t.Fatal("turned on before the person answered")
	}
	if _, err := d.answerSecretUse(r, &wire.RequestSecretUseAnswer{Action: secretUseSession}, nil); err == nil {
		t.Fatal("a workflow's request took Approve for This Session")
	}
	answerUse(t, d, r, secretUseOnce)
	if got := heldReplyOf(t, done); got.isErr || !strings.HasPrefix(got.text, "The person approved it: codes is on") {
		t.Fatalf("%+v", got)
	}
	if on, _ := d.oneWorkflow(dir, "codes"); !on.IsEnabled {
		t.Fatal("Approve did not turn it on")
	}

	done = toolAsync(m, 3, "manage_workflows", map[string]any{"action": "enable", "id": "other"})
	answerUse(t, d, openSecretUse(t, d), secretUseDeny)
	if got := heldReplyOf(t, done); !got.isErr || !strings.HasPrefix(got.text, "The person did not turn on the workflow other") {
		t.Fatalf("%+v", got)
	}
	if on, _ := d.oneWorkflow(dir, "other"); on.IsEnabled {
		t.Fatal("Deny turned it on")
	}
}

// #4538: a server waiting in the folder's .agents/mcp.json is asked for by a Needs you card.
// Approve approves the entry the agent asked for; one changed since is not approved.
func TestAnAgentAsksThePersonToApproveAConnector(t *testing.T) {
	fakeRuntimes(t)
	_, left := formHolds(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	dir := folder(t, c, 1)
	path := filepath.Join(dir, ".agents", "mcp.json")
	os.MkdirAll(filepath.Dir(path), 0o755)
	os.WriteFile(path, []byte(`{"mcpServers": {"weather": {"command": "weather-mcp"}, "mail": {"command": "mail-mcp"}}}`), 0o644)
	a := seeded(t, d, dir, nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)

	if text, _ := m.tool(2, "manage_connectors", map[string]any{"action": "list"}); !strings.Contains(text, "- weather: ") ||
		!strings.Contains(text, "[waiting for the person's approval]") {
		t.Fatal(text)
	}
	done := toolAsync(m, 3, "manage_connectors", map[string]any{"action": "approve", "name": "weather"})
	r := openSecretUse(t, d)
	s := r.Detail.SecretUse
	if s.Use != wire.SecretUseConnector || s.Name != "weather" || s.Digest == nil || *s.Digest == "" ||
		r.Title != "Approve the connector weather in "+filepath.Base(dir) {
		t.Fatalf("%+v %+v", r, s)
	}
	answerUse(t, d, r, secretUseOnce)
	if got := heldReplyOf(t, done); got.isErr || !strings.HasPrefix(got.text, "The person approved weather.") {
		t.Fatalf("%+v", got)
	}
	var list wire.MCPListAnswer
	json.Unmarshal(c.call(t, 4, "mcp/list", map[string]any{"destination": map[string]any{"kind": "folder", "folder": dir}}), &list)
	for _, srv := range list.Servers {
		if waiting := srv.Approval.Waiting != nil; waiting != (srv.Name == "mail") {
			t.Fatalf("%s waiting %v", srv.Name, waiting)
		}
	}
	if text, _ := m.tool(5, "manage_connectors", map[string]any{"action": "approve", "name": "weather"}); text != "weather is approved already." {
		t.Fatal(text)
	}

	// The entry changes after the agent asked: Approve approves nothing.
	left()
	if text, isErr := m.tool(6, "manage_connectors", map[string]any{"action": "approve", "name": "mail"}); isErr || !strings.HasPrefix(text, "Nothing was changed yet: approving the connector mail") {
		t.Fatal(text)
	}
	r = openSecretUse(t, d)
	os.WriteFile(path, []byte(`{"mcpServers": {"weather": {"command": "weather-mcp"}, "mail": {"command": "other-mcp"}}}`), 0o644)
	answerUse(t, d, r, secretUseOnce)
	if row, _ := d.folderServer(wire.SkillDestination{Kind: wire.SkillDestinationKindFolder, Folder: &dir}, "mail"); row.Approval.Waiting == nil {
		t.Fatal("a changed entry was approved")
	}
	if after := d.request(r.ID); after == nil || after.State != wire.RequestStateAnswered {
		t.Fatalf("%+v", after)
	}
}
