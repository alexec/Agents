package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/acp"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Allow, Ask or Off for each tool of a connector (#4099).

// withGitHubConnector is a daemon whose person has a connector, github, that its last check
// found with three tools: one that reads, one that writes and one that is destructive.
func withGitHubConnector(t *testing.T) *Daemon {
	t.Helper()
	d, _ := start(t, t.TempDir())
	home := t.TempDir()
	d.PersonalHome = home
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	b, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{"github": map[string]any{"command": "/bin/cat"}}})
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), b, 0o644)
	raw := []json.RawMessage{
		json.RawMessage(`{"name":"get_issue","title":"Get an issue","annotations":{"readOnlyHint":true}}`),
		json.RawMessage(`{"name":"create_issue"}`),
		json.RawMessage(`{"name":"delete_repo","annotations":{"readOnlyHint":true,"destructiveHint":true}}`),
	}
	d.healthMu.Lock()
	d.results = map[string]mcpHealthResult{healthID(nil, "github"): {check: wire.MCPCheckStateAnswered, tools: toolInfos(raw)}}
	d.healthMu.Unlock()
	return d
}

var personal = wire.SkillDestination{Kind: wire.SkillDestinationKindPersonal}

func levelOf(v wire.ConnectorToolLevel) *wire.ConnectorToolLevel { return &v }

func rowsByName(a wire.MCPToolsAnswer) map[string]wire.MCPToolRow {
	m := map[string]wire.MCPToolRow{}
	for _, r := range a.Tools {
		m[r.Name] = r
	}
	return m
}

func TestToolInfosReadTheAnnotationsSafely(t *testing.T) {
	got := toolInfos([]json.RawMessage{
		json.RawMessage(`{"name":"r","annotations":{"readOnlyHint":true}}`),
		json.RawMessage(`{"name":"w"}`),
		json.RawMessage(`{"name":"d","annotations":{"readOnlyHint":true,"destructiveHint":true}}`),
		json.RawMessage(`{"name":"w"}`),
		json.RawMessage(`{"title":"no name"}`),
	})
	want := []mcpToolInfo{{name: "r"}, {name: "w", writes: true}, {name: "d", writes: true}}
	if !slices.Equal(got, want) {
		t.Fatalf("%+v", got)
	}
}

func TestAConnectorsToolsHaveTheirDefaultLevels(t *testing.T) {
	d := withGitHubConnector(t)
	a, err := d.mcpTools(personal, "github")
	if err != nil {
		t.Fatal(err)
	}
	rows := rowsByName(a)
	if r := rows["get_issue"]; r.Level != wire.ConnectorToolLevelAllow || r.Writes || r.Title == nil || *r.Title != "Get an issue" || r.Own != nil {
		t.Fatalf("a tool that reads: %+v", r)
	}
	if r := rows["create_issue"]; r.Level != wire.ConnectorToolLevelAsk || !r.Writes {
		t.Fatalf("a tool that writes: %+v", r)
	}
	if r := rows["delete_repo"]; r.Level != wire.ConnectorToolLevelAsk || !r.Writes {
		t.Fatalf("a destructive tool: %+v", r)
	}
	if a, _ := d.mcpTools(personal, "nothing"); a.Problem == nil || len(a.Tools) != 0 {
		t.Fatalf("a connector never checked: %+v", a)
	}
}

func TestSetToolLevelWritesYourLayer(t *testing.T) {
	d := withGitHubConnector(t)
	mac := &Client{Role: RoleControl}
	tool := "delete_repo"
	a, err := d.mcpSetToolLevel(mac, wire.MCPSetToolLevelRequest{Destination: personal, Name: "github", Tool: &tool, Level: levelOf(wire.ConnectorToolLevelOff)})
	if err != nil {
		t.Fatal(err)
	}
	if r := rowsByName(a)["delete_repo"]; r.Level != wire.ConnectorToolLevelOff || r.Own == nil || *r.Own != wire.ConnectorToolLevelOff {
		t.Fatalf("%+v", r)
	}
	a, _ = d.mcpSetToolLevel(mac, wire.MCPSetToolLevelRequest{Destination: personal, Name: "github", Level: levelOf(wire.ConnectorToolLevelAllow)})
	if a.Writes == nil || *a.Writes != wire.ConnectorToolLevelAllow || rowsByName(a)["create_issue"].Level != wire.ConnectorToolLevelAllow {
		t.Fatalf("the switch: %+v", a)
	}
	if r := rowsByName(a)["delete_repo"]; r.Level != wire.ConnectorToolLevelOff {
		t.Fatalf("a tool's own level comes before the switch: %+v", r)
	}
	rules := d.yourPolicyRules().ConnectorTools["github"]
	if rules.Writes == nil || rules.Tools["delete_repo"] != wire.ConnectorToolLevelOff {
		t.Fatalf("your layer: %+v", rules)
	}
	// Cleared, it is the default again, and nothing is left in your layer.
	d.mcpSetToolLevel(mac, wire.MCPSetToolLevelRequest{Destination: personal, Name: "github", Tool: &tool})
	d.mcpSetToolLevel(mac, wire.MCPSetToolLevelRequest{Destination: personal, Name: "github"})
	if got := d.yourPolicyRules().ConnectorTools; got != nil {
		t.Fatalf("left: %+v", got)
	}
	// An agent cannot change its own tools.
	if _, err := d.mcpSetToolLevel(&Client{Role: RoleAgent}, wire.MCPSetToolLevelRequest{Destination: personal, Name: "github"}); err == nil {
		t.Fatal("an agent changed a tool's level")
	}
}

func TestAFoldersLayerOnlyMakesAToolTighter(t *testing.T) {
	d := withGitHubConnector(t)
	mac := &Client{Role: RoleControl}
	folder := repo(t)
	seeded(t, d, folder, nil)
	tool := "get_issue"
	d.mcpSetToolLevel(mac, wire.MCPSetToolLevelRequest{Destination: personal, Name: "github", Tool: &tool, Level: levelOf(wire.ConnectorToolLevelAsk)})
	here := wire.SkillDestination{Kind: wire.SkillDestinationKindFolder, Folder: &folder}
	d.healthMu.Lock()
	d.results[healthID(&folder, "github")] = d.results[healthID(nil, "github")]
	d.healthMu.Unlock()
	a, err := d.mcpSetToolLevel(mac, wire.MCPSetToolLevelRequest{Destination: here, Name: "github", Tool: &tool, Level: levelOf(wire.ConnectorToolLevelAllow)})
	if err != nil {
		t.Fatal(err)
	}
	r := rowsByName(a)["get_issue"]
	if r.Level != wire.ConnectorToolLevelAsk || r.Cap == nil || *r.Cap != wire.ConnectorToolLevelAsk || r.CapLine == nil || *r.CapLine != "Your policy: at most Ask" {
		t.Fatalf("%+v", r)
	}
	if b, _ := os.ReadFile(filepath.Join(folder, folderPolicyFile)); !strings.Contains(string(b), `"get_issue": "allow"`) {
		t.Fatalf("%s", b)
	}
}

func TestAToolsLevelAnswersItsPermissionRequest(t *testing.T) {
	d := withGitHubConnector(t)
	mac := &Client{Role: RoleControl}
	tool := "delete_repo"
	d.mcpSetToolLevel(mac, wire.MCPSetToolLevelRequest{Destination: personal, Name: "github", Tool: &tool, Level: levelOf(wire.ConnectorToolLevelOff)})
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.RuntimeID = "claude" })
	l := &live{d: d, id: a.ID, pending: map[wire.UUID]*pendingPermission{}}
	ask := func(title string) sdk.RequestPermissionRequest {
		return sdk.RequestPermissionRequest{ToolCall: sdk.ToolCallUpdate{Title: &title}, Options: []sdk.PermissionOption{
			{Kind: sdk.PermissionOptionKindAllowOnce, Name: "Yes", OptionId: "yes"},
			{Kind: sdk.PermissionOptionKindRejectOnce, Name: "No", OptionId: "no"},
		}}
	}
	if got := l.Permission(context.Background(), ask("mcp__github__get_issue")); got != "yes" {
		t.Fatalf("a tool that reads is allowed: %q", got)
	}
	if got := l.Permission(context.Background(), ask("mcp__github__delete_repo")); got != "no" {
		t.Fatalf("an Off tool is refused: %q", got)
	}
	entries, _, _ := d.Store.Transcript(a.ID, 0)
	var stop *wire.PolicyRefusal
	for _, e := range entries {
		if e.Kind.PermissionAsked != nil {
			t.Fatalf("a card was asked: %+v", e)
		}
		if e.Kind.PolicyStopped != nil {
			stop = &e.Kind.PolicyStopped.Value
		}
	}
	if stop == nil || stop.Rule == nil || *stop.Rule != "connectorTools" || stop.Layer == nil || stop.Layer.Kind != "you" ||
		!strings.Contains(stop.Words, "delete_repo of github is Off") {
		t.Fatalf("the chat names the rule: %+v", stop)
	}
}

func TestOffToolsGoToEachRuntimeInItsOwnForm(t *testing.T) {
	off := [][2]string{{"github", "delete_repo"}}
	_, meta := withToolLevels(acp.Launch{}, sessionMeta("claude"), "claude", off)
	denied := meta["claudeCode"].(map[string]any)["options"].(map[string]any)["disallowedTools"].([]string)
	if !slices.Contains(denied, "mcp__github__delete_repo") || !slices.Contains(denied, "Workflow") {
		t.Fatalf("claude: %q", denied)
	}
	if l, _ := withToolLevels(acp.Launch{Args: []string{"--acp"}}, nil, "copilot", off); !slices.Equal(l.Args, []string{"--acp", "--deny-tool", "github(delete_repo)"}) {
		t.Fatalf("copilot: %q", l.Args)
	}
	l := withToolPolicy(acp.Launch{}, "opencode")
	l, _ = withToolLevels(l, nil, "opencode", off)
	v, _ := envValue(l.Env, "OPENCODE_CONFIG_CONTENT")
	if !strings.Contains(v, `"tools":{"github_delete_repo":false}`) || !strings.Contains(v, `"bash":"ask"`) {
		t.Fatalf("opencode: %s", v)
	}
	if l, meta := withToolLevels(acp.Launch{Args: []string{"x"}}, nil, "codex", off); len(l.Args) != 1 || meta != nil {
		t.Fatal("codex has no form: it is refused when it asks")
	}
}
