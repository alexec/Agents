package agentsd

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// The person's settings sync into each machine's files, and resources stay local.
func TestUserSettingsGoIntoTheMachinesFiles(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, root)
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	os.MkdirAll(filepath.Join(home, ".agents-secrets"), 0o700)
	os.WriteFile(filepath.Join(home, ".agents-secrets", "secrets.env"), []byte("MINE=kept\n"), 0o600)
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers":{"old":{"command":"x"}},"note":"kept"}`), 0o644)

	instructions := "Use ASD-STE100."
	sent := wire.MachineUserSettings{User: "sam", Settings: wire.UserSettings{
		McpServers:  json.RawMessage(`{"github":{"url":"https://api.githubcopilot.com/mcp/","headers":{"Authorization":"Bearer ${GITHUB_TOKEN}"}}}`),
		AgentConfig: mustJSON(wire.UserAgentConfig{Instructions: &instructions, Personas: map[string]string{"reviewer": "You review."}, Skills: map[string]string{"release": "---\nname: release\n---\n"}}),
		Runtimes:    json.RawMessage(`{"sandbox":{"defaults":{"claude":"on"}}}`),
		CostLimits:  json.RawMessage(`{"dailyTokens":5000}`),
	}, Secrets: []wire.UserSecret{{Name: "GITHUB_TOKEN", Value: "ghp_sams"}}}
	d.Told(wire.NotifyMachineUserSettings.Name, mustJSON(sent))

	read := func(parts ...string) string {
		b, _ := os.ReadFile(filepath.Join(parts...))
		return string(b)
	}
	if mcp := read(home, ".agents", "mcp.json"); !strings.Contains(mcp, "githubcopilot") || strings.Contains(mcp, `"old"`) || !strings.Contains(mcp, `"note"`) {
		t.Fatal(mcp)
	}
	if read(home, ".agents", "AGENTS.md") != instructions || read(home, ".agents", "personas", "reviewer.md") != "You review." ||
		!strings.Contains(read(home, ".agents", "skills", "release", "SKILL.md"), "name: release") {
		t.Fatal("agent configuration not written")
	}
	if !strings.Contains(read(d.SettingsDir, "sandbox.json"), `"claude":"on"`) {
		t.Fatal(read(d.SettingsDir, "sandbox.json"))
	}
	var st wire.CostState
	json.Unmarshal(c.call(t, 1, "cost/state", nil), &st)
	if st.Limits.DailyTokens == nil || *st.Limits.DailyTokens != 5000 {
		t.Fatalf("%+v", st.Limits)
	}
	secrets := read(home, ".agents-secrets", "secrets.env")
	if !strings.Contains(secrets, "GITHUB_TOKEN=ghp_sams") || !strings.Contains(secrets, "MINE=kept") {
		t.Fatal("secrets.env")
	}
	if info, _ := os.Stat(filepath.Join(home, ".agents-secrets", "secrets.env")); info.Mode().Perm() != 0o600 {
		t.Fatal(info.Mode())
	}
	mark := read(root, userSettingsSyncFile)
	if strings.Contains(mark, "ghp_sams") || !strings.Contains(mark, "GITHUB_TOKEN") || strings.Contains(mark, "parts") {
		t.Fatal(mark)
	}
	if _, err := os.Stat(filepath.Join(root, "from-control-plane.json")); !os.IsNotExist(err) {
		t.Fatalf("old scope marker remains: %v", err)
	}
	c.call(t, 2, "cost/setLimits", map[string]any{"dailyTokens": 1})
	c.call(t, 3, "resources/declare", wire.DeclareResourceRequest{Resource: wire.DeclaredResource{
		Name: "build", DisplayName: "Build", Description: "Build jobs", Holders: 3,
	}})

	// A removed persona and secret are taken away; omitted cost limits stay as they are.
	sent.Settings.AgentConfig = mustJSON(wire.UserAgentConfig{Instructions: &instructions})
	sent.Settings.CostLimits = nil
	sent.Secrets = nil
	d.Told(wire.NotifyMachineUserSettings.Name, mustJSON(sent))
	if _, err := os.Stat(filepath.Join(home, ".agents", "personas", "reviewer.md")); !os.IsNotExist(err) {
		t.Fatal("the persona is still there")
	}
	if _, err := os.Stat(filepath.Join(home, ".agents", "skills", "release")); !os.IsNotExist(err) {
		t.Fatal("the skill is still there")
	}
	if secrets := read(home, ".agents-secrets", "secrets.env"); strings.Contains(secrets, "GITHUB_TOKEN") || !strings.Contains(secrets, "MINE=kept") {
		t.Fatal("secrets.env after")
	}
	c.call(t, 4, "cost/setLimits", map[string]any{"dailyTokens": 1})
}

func TestAgentConfigFilesAreAppliedAndMarkedWithoutContents(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, _ := start(t, root)
	defer d.Shutdown()
	contents := base64.StdEncoding.EncodeToString([]byte("Follow the shared rules."))
	d.Told(wire.NotifyMachineUserSettings.Name, mustJSON(wire.MachineUserSettings{
		User: "sam",
		Settings: wire.UserSettings{AgentConfigFiles: &wire.AgentConfigFiles{Files: []wire.AgentConfigFile{{
			Path: "skills/review/SKILL.md", Contents: &contents, Time: 10, Machine: "other", Digest: "abc",
		}}}},
	}))
	written, err := os.ReadFile(filepath.Join(home, ".agents", "skills", "review", "SKILL.md"))
	if err != nil || string(written) != "Follow the shared rules." {
		t.Fatalf("%q %v", written, err)
	}
	var mark userSettingsSyncState
	data, err := os.ReadFile(d.userSettingsSyncPath())
	if err != nil || json.Unmarshal(data, &mark) != nil || len(mark.ConfigFiles) != 1 || mark.ConfigFiles[0].Contents != nil {
		t.Fatalf("mark retained file contents: %+v %v", mark.ConfigFiles, err)
	}
}

func TestAgentConfigNamesStayInTheirFolders(t *testing.T) {
	home := t.TempDir()
	for _, name := range []string{"../evil", "a/b", ".hidden", ""} {
		raw := mustJSON(wire.UserAgentConfig{Personas: map[string]string{name: "x"}})
		if _, err := writeAgentConfig(home, raw, nil); err == nil {
			t.Fatalf("%q was written", name)
		}
	}
	// A mark that names a file outside is never removed.
	outside := filepath.Join(home, "keep.txt")
	os.WriteFile(outside, []byte("x"), 0o644)
	writeAgentConfig(home, mustJSON(wire.UserAgentConfig{}), []string{"../keep.txt", "/etc/hosts"})
	if _, err := os.Stat(outside); err != nil {
		t.Fatal("removed a file outside ~/.agents")
	}
}

func TestAPartIsTakenFromThisMachine(t *testing.T) {
	root, home := t.TempDir(), t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, root)
	defer d.Shutdown()
	d.SettingsDir = t.TempDir()
	os.MkdirAll(filepath.Join(home, ".agents", "skills", "one"), 0o755)
	os.MkdirAll(filepath.Join(home, ".agents", "skills", "many"), 0o755)
	os.WriteFile(filepath.Join(home, ".agents", "skills", "one", "SKILL.md"), []byte("one"), 0o644)
	os.WriteFile(filepath.Join(home, ".agents", "skills", "many", "SKILL.md"), []byte("many"), 0o644)
	os.WriteFile(filepath.Join(home, ".agents", "skills", "many", "run.sh"), []byte("x"), 0o644)
	os.WriteFile(filepath.Join(home, ".agents", "AGENTS.md"), []byte("Be brief."), 0o644)
	var got wire.UserPartHere
	json.Unmarshal(c.call(t, 1, "settings/userPart", wire.UserPartRequest{Part: wire.UserSettingsPartNameAgentConfig}), &got)
	var config wire.UserAgentConfig
	json.Unmarshal(got.Value, &config)
	if config.Instructions == nil || *config.Instructions != "Be brief." || config.Skills["one"] != "one" || len(config.Skills) != 1+len(readyMadeIDs()) ||
		len(got.LeftOut) != 1 || got.LeftOut[0] != "many" {
		t.Fatalf("%+v %+v", got, config)
	}
	for _, id := range readyMadeIDs() {
		if _, ok := config.Skills[id]; !ok {
			t.Fatalf("ready-made skill %q is missing", id)
		}
	}
	// A token in clear is refused, by name only; one in a secret is taken.
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers":{"gh":{"url":"https://x","headers":{"Authorization":"Bearer ghp_clear"}}}}`), 0o644)
	if e := c.callError(t, 2, "settings/userPart", wire.UserPartRequest{Part: wire.UserSettingsPartNameMcpServers}); e == nil ||
		!strings.Contains(e.Message, "gh has Authorization") || strings.Contains(e.Message, "ghp_clear") {
		t.Fatalf("%+v", e)
	}
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), []byte(`{"mcpServers":{"gh":{"url":"https://x","headers":{"Authorization":"Bearer ${GH}"},"env":{"DEBUG":"1"}}}}`), 0o644)
	json.Unmarshal(c.call(t, 3, "settings/userPart", wire.UserPartRequest{Part: wire.UserSettingsPartNameMcpServers}), &got)
	if !strings.Contains(string(got.Value), "${GH}") {
		t.Fatalf("%s", got.Value)
	}
	if err := c.callError(t, 4, "settings/userPart", wire.UserPartRequest{Part: wire.UserSettingsPartName("resources")}); err == nil {
		t.Fatal("resources were returned as a person-scoped setting")
	}
}
