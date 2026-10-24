package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// Ports PersonalSnapshotTests: personal/shared reads the person's ~/.agents (no params) or a
// folder's .agents (folder, #754), says which runtime gets each thing, and never returns a
// value from mcp.json.

func sharedHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	put := func(rel, text string) {
		p := filepath.Join(home, rel)
		os.MkdirAll(filepath.Dir(p), 0o755)
		os.WriteFile(p, []byte(text), 0o644)
	}
	put(".agents/AGENTS.md", "# Personal instructions\n")
	put(".agents/skills/review/SKILL.md", "---\nname: review\ndescription: \"Reviews a change.\"\n---\n")
	put(".agents/skills/linked/SKILL.md", "---\nname: linked\n---\n")
	put(".agents/skills/clashing/SKILL.md", "---\nname: clashing\n---\n")
	put(".claude/skills/clashing/SKILL.md", "theirs\n")
	os.Symlink("../../.agents/skills/linked", filepath.Join(home, ".claude/skills/linked"))
	os.Symlink("../.agents/AGENTS.md", filepath.Join(home, ".claude/CLAUDE.md"))
	put(".codex/AGENTS.md", "codex's own\n")
	put(".agents/mcp.json", `{"mcpServers": {
		"github": {"command": "npx", "args": ["-y", "server", "--token=abc123", "fourth"], "env": {"GITHUB_TOKEN": "${GITHUB_TOKEN}"}},
		"docs": {"url": "https://user:pw@docs.example.com/mcp?key=hunter2#x", "headers": {"X-Key": "hunter2"}},
		"old": {"type": "sse", "url": "https://old.example.com/sse"}
	}}`)
	put(".codex/config.toml", "[mcp_servers.docs]\ncommand = \"x\"\n[mcp_servers.own]\n[mcp_servers.own.env]\n")
	put(".agents/plugins/tools/.claude-plugin/plugin.json", `{"name": "tools", "version": "1.0.0", "description": "Some tools."}`)
	put(".agents/plugins/tools/skills/fmt/SKILL.md", "---\ndescription: Formats.\n---\n")
	put(".agents/plugins/tools/commands/go.md", "go\n")
	put(".agents/plugins/tools/.mcp.json", `{"mcpServers": {"b": {"command": "b"}, "a": {"url": "https://a"}, "bad": {}}}`)
	put(".agents/personas/critic.md", "critic\n")
	put(".agents/.skill-lock.json", "{}")
	put(".agents/notes.txt", "mine\n")
	return home
}

func rulesFor(ids ...string) []sharedRule {
	var out []sharedRule
	for _, r := range sharedRules {
		for _, id := range ids {
			if r.id == id {
				out = append(out, r)
			}
		}
	}
	return out
}

func reachText(t *testing.T, r wire.SharedReach) string {
	t.Helper()
	return string(r)
}

func TestSharedSnapshotSaysWhoGetsWhat(t *testing.T) {
	home := sharedHome(t)
	present := rulesFor("claude", "codex", "copilot")
	s := personalSnapshot(home, present, layoutRecord{Home: home}, nil, map[string]string{})
	if !s.LaidOut || s.Home != filepath.Join(home, ".agents") || len(s.Runtimes) != 3 || s.Runtimes[0].Name != "Claude" ||
		s.Runtimes[1].Name != "Codex" || s.Runtimes[2].Name != "Copilot" {
		t.Fatalf("runtimes: %+v", s)
	}
	in := s.Instructions
	if !in.Exists || reachText(t, in.Reach["claude"]) != `{"gets":"~/.claude/CLAUDE.md → link"}` ||
		reachText(t, in.Reach["codex"]) != `{"ownCopy":"`+filepath.Join(home, ".codex/AGENTS.md")+`"}` ||
		reachText(t, in.Reach["copilot"]) != `{"gets":"~/.copilot/copilot-instructions.md, linked before its next agent starts"}` {
		t.Fatalf("instructions: %+v", in.Reach)
	}

	skills := map[string]wire.SharedSkill{}
	for _, k := range s.Skills {
		skills[k.Name] = k
	}
	if len(s.Skills) != 4 || *skills["review"].Description != "Reviews a change." || string(skills["review"].Source) != `"personal"` ||
		reachText(t, skills["linked"].Reach["claude"]) != `{"gets":"through a link in ~/.claude/skills"}` ||
		reachText(t, skills["review"].Reach["claude"]) != `{"gets":"linked in ~/.claude/skills before its next agent starts"}` ||
		reachText(t, skills["review"].Reach["codex"]) != `{"gets":"reads ~/.agents/skills"}` ||
		skills["clashing"].Clash == nil || string(skills["fmt"].Source) != `{"plugin":"tools"}` {
		t.Fatalf("skills: %+v", s.Skills)
	}

	m := s.MCP
	if len(m.App) != 1 || reachText(t, m.App[0].Reach["copilot"]) != `{"gets":"through the bridge"}` || len(m.Servers) != 3 {
		t.Fatalf("mcp: %+v", m)
	}
	github, docs, old := m.Servers[0], m.Servers[1], m.Servers[2]
	if github.Summary != "npx -y server ••••" || strings.Join(github.EnvNames, ",") != "GITHUB_TOKEN" ||
		reachText(t, github.Reach["claude"]) != `{"leftOut":"GITHUB_TOKEN isn't set"}` {
		t.Fatalf("github: %+v", github)
	}
	if docs.Summary != "https://docs.example.com/mcp" || strings.Join(docs.HeaderNames, ",") != "X-Key" ||
		docs.Clash["codex"] != filepath.Join(home, ".codex/config.toml") ||
		reachText(t, docs.Reach["codex"]) != `{"ownCopy":"`+filepath.Join(home, ".codex/config.toml")+`"}` ||
		reachText(t, docs.Reach["claude"]) != `{"gets":"sent at start"}` {
		t.Fatalf("docs: %+v", docs)
	}
	if old.Transport != "sse" || reachText(t, old.Reach["codex"]) != `{"leftOut":"Codex takes no sse servers"}` {
		t.Fatalf("old: %+v", old)
	}
	if len(m.RuntimeOnly) != 1 || m.RuntimeOnly[0].Name != "own" || m.RuntimeOnly[0].RuntimeID != "codex" {
		t.Fatalf("runtime only: %+v", m.RuntimeOnly)
	}

	if len(s.Plugins) != 1 {
		t.Fatalf("plugins: %+v", s.Plugins)
	}
	p := s.Plugins[0]
	if p.Name != "tools" || *p.Version != "1.0.0" || p.Contents.Skills != 1 || p.Contents.Commands != 1 || p.Contents.McpServers != 2 ||
		strings.Join(p.ServerNames, ",") != "b,a" || reachText(t, p.Reach["claude"]) != `{"gets":"handed at start"}` ||
		reachText(t, p.Reach["codex"]) != `{"leftOut":"not added to Codex yet: the next Codex agent adds it"}` ||
		reachText(t, p.Reach["copilot"]) != `{"noWay":"not in agents the app starts (its own CLI has it)"}` {
		t.Fatalf("plugin: %+v", p)
	}

	var other []string
	for _, f := range s.OtherFiles {
		other = append(other, f.Path+":"+string(f.Kind))
	}
	if strings.Join(other, " ") != ".skill-lock.json:managed notes.txt:unused personas/critic.md:persona" {
		t.Fatalf("other files: %v", other)
	}

	var looks []string
	for _, l := range s.NeedsALook {
		looks = append(looks, string(l.Kind)+"/"+string(l.Page)+"/"+l.Item)
	}
	want := "clash/skills/clashing leftOut/mcp/github clash/mcp/docs leftOut/mcp/Codex noWay/plugins/Copilot"
	if strings.Join(looks, " ") != want {
		t.Fatalf("looks: %v", looks)
	}

	// No value from mcp.json is anywhere in what goes out (FR-023).
	b, _ := json.Marshal(s)
	for _, secret := range []string{"abc123", "hunter2", "user:pw"} {
		if strings.Contains(string(b), secret) {
			t.Fatalf("%s went out: %s", secret, b)
		}
	}
}

func TestSharedSnapshotAnsweredOverTheSocket(t *testing.T) {
	home := sharedHome(t)
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()

	// No params: the person's ~/.agents.
	var s wire.SharedSnapshot
	if err := json.Unmarshal(c.call(t, 1, "personal/shared", nil), &s); err != nil {
		t.Fatal(err)
	}
	if !s.LaidOut || s.Home != filepath.Join(home, ".agents") || len(s.Skills) != 4+len(readyMadeIDs()) || len(s.MCP.Servers) != 3 {
		t.Fatalf("%+v", s)
	}

	// A folder's .agents, with no reach, and only a folder's.
	folder := t.TempDir()
	c.call(t, 2, "folders/add", map[string]any{"folder": "file://" + folder})
	os.MkdirAll(filepath.Join(folder, ".agents", "skills", "build"), 0o755)
	os.WriteFile(filepath.Join(folder, ".agents", "folder.json"), []byte("{}"), 0o644)
	os.WriteFile(filepath.Join(folder, ".agents", "mcp.json"), []byte("{not json"), 0o644)
	s = wire.SharedSnapshot{}
	json.Unmarshal(c.call(t, 3, "personal/shared", map[string]any{"folder": folder}), &s)
	if s.Home != filepath.Join(folder, ".agents") || s.Instructions == nil || s.Instructions.Exists ||
		s.Instructions.Path != filepath.Join(folder, "AGENTS.md") || len(s.Skills) != 1 || len(s.Skills[0].Reach) != 0 ||
		s.MCP.Problem == nil || len(s.OtherFiles) != 1 || s.OtherFiles[0].Kind != wire.SharedOtherFileKindApp ||
		len(s.NeedsALook) != 1 || s.NeedsALook[0].Kind != wire.SharedLookKindProblem {
		t.Fatalf("%+v", s)
	}
	if e := c.callError(t, 4, "personal/shared", map[string]any{"folder": t.TempDir()}); e.Code != -32602 {
		t.Fatalf("%+v", e)
	}
}

func TestSharedSnapshotWithNoPersonalHome(t *testing.T) {
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	d.PersonalHome = ""
	t.Setenv("AGENTS_PERSONAL_HOME", "")
	raw := c.call(t, 1, "personal/shared", nil)
	var s wire.SharedSnapshot
	json.Unmarshal(raw, &s)
	if s.LaidOut || s.Home != "" || !strings.Contains(string(raw), `"skills":[]`) {
		t.Fatalf("%s", raw)
	}
}
