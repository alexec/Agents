package agentsd

import (
	"context"
	"encoding/json"
	"io/fs"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// personal/shared (054, DaemonAPI+Shared.swift): Settings ▸ Agent Configuration's read of
// the person's ~/.agents, and with a folder, Folder Settings' read of that folder's
// .agents (#754). Worked out from disk on every call, as PersonalDotAgents.snapshot does:
// the rule table and what R9 measured, plus the links, the layout record and the names in
// each runtime's own config. Nothing returned is a value from mcp.json: env and headers go
// by name only, and a command or URL is cut short of anything like a secret (FR-023).
// A window's only: an agent's connection is refused it by its role.

func (d *Daemon) registerShared() {
	On(d, wire.CallPersonalShared, func(ctx context.Context, c *Client, r wire.SharedRequest) (wire.SharedSnapshot, error) {
		if r.Folder != nil {
			folder := filepath.Clean(*r.Folder)
			if !d.isFolderPath(folder) {
				return wire.SharedSnapshot{}, Invalid("%s is not a folder here.", *r.Folder)
			}
			return folderSharedSnapshot(folder), nil
		}
		return d.withManagedSkills(d.sharedSnapshot()), nil
	})
}

// sharedRule is PersonalDotAgents.Rule: what one runtime needs from the home layout.
type sharedRule struct {
	id               string
	readsShared      bool   // reads ~/.agents/skills by itself
	skillsFolder     string // where its skill links go, when it does not
	instructionsFile string // "" when it has none
	takesStdio       bool
	handover         string // sessionMeta, sessionMetaWithServers, codexMarketplace, none
	appSkillsFolder  string // inside the home the app gives it (Antigravity)
	noInstructions   string // why it has no instructions file, once measured
}

// sharedRules is PersonalDotAgents.rules, in the same order.
var sharedRules = []sharedRule{
	{id: "claude", skillsFolder: ".claude/skills", instructionsFile: ".claude/CLAUDE.md", takesStdio: true, handover: "sessionMeta"},
	{id: "codex", readsShared: true, instructionsFile: ".codex/AGENTS.md", takesStdio: true, handover: "codexMarketplace"},
	{id: "grok", readsShared: true, instructionsFile: ".grok/AGENTS.md", takesStdio: true, handover: "sessionMetaWithServers"},
	{id: "cursor", readsShared: true, takesStdio: true, handover: "none", noInstructions: "Cursor keeps User Rules in its own settings"},
	{id: "copilot", readsShared: true, instructionsFile: ".copilot/copilot-instructions.md", handover: "none"},
	{id: "antigravity", takesStdio: true, handover: "none", appSkillsFolder: "config/skills",
		noInstructions: "Antigravity reads no personal instructions file when the app starts it"},
	{id: "opencode", readsShared: true, instructionsFile: ".claude/CLAUDE.md", takesStdio: true, handover: "none"},
}

var (
	// keepsOwnServer: runtimes that keep their own server of a name over the app's (R9).
	keepsOwnServer = map[string]bool{"codex": true, "copilot": true}
	// runsBothServers: runtimes that run both copies of a clashing server (R9).
	runsBothServers = map[string]bool{"cursor": true}
	// refusesSSE: runtimes whose handshake leaves sse out (R9).
	refusesSSE = map[string]bool{"codex": true}
	// ownServerConfigs: where each runtime keeps MCP servers of its own, under the home.
	ownServerConfigs = map[string]string{
		"claude":   ".claude.json",
		"codex":    ".codex/config.toml",
		"cursor":   ".cursor/mcp.json",
		"copilot":  ".copilot/mcp-config.json",
		"opencode": ".config/opencode/opencode.json",
	}
	// managedSkillNames: names another tool owns inside a runtime's skills folder (FR-007).
	managedSkillNames = map[string]bool{"synced": true}
	// folderAppFiles: what the app keeps in a folder's .agents.
	folderAppFiles = map[string]bool{"folder.json": true, "pins.json": true, "workflows": true, "worktrees": true,
		"dropbox": true, "attachments": true, "chat": true}
)

// layoutRecord is PersonalDotAgents.Record, <root>/personal-layout.json: what the Swift
// host placed in the home, so a link the person removed reads as removed.
type layoutRecord struct {
	Home         string               `json:"home"`
	Links        map[string]string    `json:"links"`
	CodexPlugins map[string]string    `json:"codexPlugins"`
	CodexAddedAt map[string]wire.Date `json:"codexAddedAt"`
}

func (d *Daemon) layoutRecord(home string) layoutRecord {
	var r layoutRecord
	b, err := os.ReadFile(filepath.Join(d.Store.Loc.Root, "personal-layout.json"))
	if err != nil || json.Unmarshal(b, &r) != nil || r.Home != home {
		return layoutRecord{Home: home}
	}
	return r
}

// installedRuntimeIDs is the runtimes this host can start.
func installedRuntimeIDs() map[string]bool {
	out := map[string]bool{}
	for i := range catalog {
		if path, _, _ := catalog[i].locate(); path != "" {
			out[catalog[i].ID] = true
		}
	}
	return out
}

// appHomes is the homes the app gives runtimes of its own (Antigravity's GEMINI_HOME).
func (d *Daemon) appHomes() map[string]string {
	return map[string]string{"antigravity": filepath.Join(d.Store.Loc.Root, "runtimes", "antigravity", "home")}
}

func emptySnapshot(home string, laidOut bool) wire.SharedSnapshot {
	return wire.SharedSnapshot{Home: home, LaidOut: laidOut, Runtimes: []wire.SharedRuntimeName{}, Skills: []wire.SharedSkill{},
		MCP:     wire.SharedMCP{Servers: []wire.SharedServer{}, App: []wire.SharedServer{}, RuntimeOnly: []wire.SharedRuntimeOnlyServer{}},
		Plugins: []wire.SharedPlugin{}, OtherFiles: []wire.SharedOtherFile{}, NeedsALook: []wire.SharedLook{}}
}

// sharedSnapshot is DaemonCore.sharedSnapshot: the person's ~/.agents, or nothing laid out
// on a scratch root with no personal home.
func (d *Daemon) sharedSnapshot() wire.SharedSnapshot {
	home := d.personalHome()
	if home == "" {
		return emptySnapshot("", false)
	}
	home = filepath.Clean(home)
	installed := installedRuntimeIDs()
	var present []sharedRule
	for _, r := range sharedRules {
		if installed[r.id] {
			present = append(present, r)
		}
	}
	return personalSnapshot(home, present, d.layoutRecord(home), d.appHomes(), d.secrets())
}

// withManagedSkills marks each personal skill a lock says the app or `npx skills` added (059).
func (d *Daemon) withManagedSkills(s wire.SharedSnapshot) wire.SharedSnapshot {
	place, err := d.skillPlace(wire.SkillDestination{Kind: wire.SkillDestinationKindPersonal})
	if err != nil {
		return s
	}
	managed := d.skillInstaller().Managed(place)
	for i := range s.Skills {
		if m, ok := managed[s.Skills[i].Name]; ok && string(s.Skills[i].Source) == `"personal"` {
			s.Skills[i].Managed = &m
		}
	}
	return s
}

func personalSnapshot(home string, present []sharedRule, record layoutRecord, appHomes map[string]string,
	secrets map[string]string) wire.SharedSnapshot {
	shared := filepath.Join(home, ".agents")
	s := emptySnapshot(shared, true)
	for _, r := range present {
		s.Runtimes = append(s.Runtimes, wire.SharedRuntimeName{ID: r.id, Name: runtimeName(r.id)})
	}
	sort.SliceStable(s.Runtimes, func(i, j int) bool {
		a, b := strings.ToLower(s.Runtimes[i].Name), strings.ToLower(s.Runtimes[j].Name)
		if a != b {
			return a < b
		}
		return s.Runtimes[i].ID < s.Runtimes[j].ID
	})
	var looks []wire.SharedLook
	instructions := sharedInstructions(home, present, record, &looks)
	s.Instructions = &instructions
	plugins := pluginFoldersIn(filepath.Join(shared, "plugins"))
	s.Skills = sharedSkills(home, present, plugins, record, appHomes, &looks)
	s.MCP = sharedMCP(home, present, secrets, &looks)
	for _, p := range plugins {
		s.Plugins = append(s.Plugins, sharedPlugin(home, p, present, record))
	}
	if len(plugins) > 0 {
		var none []string
		for _, r := range present {
			if r.handover == "none" {
				none = append(none, r.id)
			}
		}
		if len(none) > 0 {
			who := "None of them takes"
			switch len(none) {
			case 1:
				who = "It takes"
			case 2:
				who = "Neither takes"
			}
			looks = append(looks, wire.SharedLook{Kind: wire.SharedLookKindNoWay, Page: wire.SharedLookPagePlugins, Item: runtimeNames(none),
				Text: who + " a plugin from the app. Their own installs still work in their own sessions."})
		}
	}
	s.OtherFiles = sharedOtherFiles(shared, nil)
	if looks != nil {
		s.NeedsALook = looks
	}
	return s
}

// folderSharedSnapshot is PersonalDotAgents.folderSnapshot: what a folder's .agents
// holds, with no runtimes, so no reach. Its instructions are the folder's own AGENTS.md.
func folderSharedSnapshot(folder string) wire.SharedSnapshot {
	shared := filepath.Join(folder, ".agents")
	s := emptySnapshot(shared, true)
	router := filepath.Join(folder, "AGENTS.md")
	s.Instructions = &wire.SharedInstructions{Path: router, Exists: lexists(router), Reach: map[string]wire.SharedReach{}}
	var looks []wire.SharedLook
	plugins := pluginFoldersIn(filepath.Join(shared, "plugins"))
	record := layoutRecord{Home: folder}
	s.Skills = sharedSkills(folder, nil, plugins, record, nil, &looks)
	file := filepath.Join(shared, "mcp.json")
	s.MCP.File = file
	entries, problem := readMCPFile(file)
	if problem != "" {
		s.MCP.Problem = &wire.SharedProblem{Message: problem}
		looks = append(looks, wire.SharedLook{Kind: wire.SharedLookKindProblem, Page: wire.SharedLookPageMCP, Item: "mcp.json",
			Text: problem + " Agents here start without the folder's servers until it is fixed."})
	}
	for _, e := range entries {
		s.MCP.Servers = append(s.MCP.Servers, serverRow(e, map[string]string{}, map[string]wire.SharedReach{}))
	}
	for _, p := range plugins {
		s.Plugins = append(s.Plugins, sharedPlugin(folder, p, nil, record))
	}
	s.OtherFiles = sharedOtherFiles(shared, folderAppFiles)
	if looks != nil {
		s.NeedsALook = looks
	}
	return s
}

func reachOf(kind, note string) wire.SharedReach {
	b, _ := json.Marshal(map[string]string{kind: note})
	return b
}

func gets(note string) wire.SharedReach    { return reachOf("gets", note) }
func ownCopy(path string) wire.SharedReach { return reachOf("ownCopy", path) }
func leftOut(why string) wire.SharedReach  { return reachOf("leftOut", why) }
func noWay(why string) wire.SharedReach    { return reachOf("noWay", why) }

func unchecked(note string) wire.SharedReach {
	if note == "" {
		return wire.SharedReach(`"unchecked"`)
	}
	return reachOf("unchecked", note)
}

func runtimeNames(ids []string) string {
	names := make([]string, len(ids))
	for i, id := range ids {
		names[i] = runtimeName(id)
	}
	return strings.Join(names, ", ")
}

// tildeIn is a path under the personal home written from ~.
func tildeIn(path, home string) string {
	if strings.HasPrefix(path, home+"/") {
		return "~" + path[len(home):]
	}
	return path
}

// lexists is DotAgents.exists: something there, a link that points nowhere included.
func lexists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func lisDir(path string) bool {
	info, err := os.Lstat(path)
	return err == nil && info.IsDir()
}

// linksTo is whether path is a link that, read from its own folder, is target.
func linksTo(path, target string) bool {
	dest, err := os.Readlink(path)
	if err != nil {
		return false
	}
	if !filepath.IsAbs(dest) {
		dest = filepath.Join(filepath.Dir(path), dest)
	}
	return filepath.Clean(dest) == filepath.Clean(target)
}

// visibleNames is a folder's entries that are not hidden, sorted.
func visibleNames(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if !strings.HasPrefix(e.Name(), ".") {
			out = append(out, e.Name())
		}
	}
	sort.Strings(out)
	return out
}

// pluginFoldersIn is DotAgents.pluginFolders(in:): each folder, or link to one, by name.
func pluginFoldersIn(dir string) []string {
	var out []string
	for _, n := range visibleNames(dir) {
		if p := filepath.Join(dir, n); isDir(p) {
			out = append(out, p)
		}
	}
	return out
}

func sharedInstructions(home string, present []sharedRule, record layoutRecord, looks *[]wire.SharedLook) wire.SharedInstructions {
	router := filepath.Join(home, ".agents", "AGENTS.md")
	reach := map[string]wire.SharedReach{}
	for _, r := range present {
		if r.instructionsFile == "" {
			if r.noInstructions != "" {
				reach[r.id] = noWay(r.noInstructions)
				*looks = append(*looks, wire.SharedLook{Kind: wire.SharedLookKindNoFile, Page: wire.SharedLookPageInstructions,
					Item: runtimeName(r.id), Text: "No personal instructions file. " + r.noInstructions + "."})
			} else {
				reach[r.id] = unchecked("")
			}
			continue
		}
		link := filepath.Join(home, r.instructionsFile)
		switch {
		case linksTo(link, router):
			reach[r.id] = gets("~/" + r.instructionsFile + " → link")
		case lexists(link):
			reach[r.id] = ownCopy(link)
		case record.Links[r.instructionsFile] != "":
			reach[r.id] = leftOut("no ~/" + r.instructionsFile + ": its link was removed")
		default:
			reach[r.id] = gets("~/" + r.instructionsFile + ", linked before its next agent starts")
		}
	}
	return wire.SharedInstructions{Path: router, Exists: lexists(router), Reach: reach}
}

func sharedSkills(home string, present []sharedRule, plugins []string, record layoutRecord, appHomes map[string]string,
	looks *[]wire.SharedLook) []wire.SharedSkill {
	folder := filepath.Join(home, ".agents", "skills")
	list := []wire.SharedSkill{}
	for _, name := range visibleNames(folder) {
		skill := filepath.Join(folder, name)
		if !isDir(skill) {
			continue
		}
		reach := map[string]wire.SharedReach{}
		clash := ""
		for _, r := range present {
			switch {
			case r.skillsFolder != "":
				link := filepath.Join(home, r.skillsFolder, name)
				where := "~/" + r.skillsFolder
				switch {
				case linksTo(link, skill):
					reach[r.id] = gets("through a link in " + where)
				case lexists(link):
					clash = link
					reach[r.id] = ownCopy(link)
				case managedSkillNames[name]:
					reach[r.id] = leftOut("another tool manages that name in " + where)
				case record.Links[r.skillsFolder+"/"+name] != "":
					reach[r.id] = leftOut("its link in " + where + " was removed")
				default:
					reach[r.id] = gets("linked in " + where + " before its next agent starts")
				}
			case r.readsShared:
				reach[r.id] = gets("reads ~/.agents/skills")
			case r.appSkillsFolder != "" && appHomes[r.id] != "":
				link := filepath.Join(appHomes[r.id], r.appSkillsFolder, name)
				dest, _ := os.Readlink(link)
				switch {
				case dest == skill:
					reach[r.id] = gets("through a link in the home the app gives it")
				case lexists(link):
					reach[r.id] = ownCopy(link)
				case record.Links[link] != "":
					reach[r.id] = leftOut("its link in the home the app gives it was removed")
				default:
					reach[r.id] = gets("linked into the home the app gives it before its next agent starts")
				}
			default:
				reach[r.id] = unchecked("")
			}
		}
		row := wire.SharedSkill{Name: name, Path: skill, Description: skillDescription(skill), Source: wire.SharedSkillSource(`"personal"`), Reach: reach}
		if clash != "" {
			who := "It"
			for _, r := range present {
				if r.skillsFolder != "" {
					who = runtimeName(r.id)
					break
				}
			}
			*looks = append(*looks, wire.SharedLook{Kind: wire.SharedLookKindClash, Page: wire.SharedLookPageSkills, Item: name,
				Text: "A skill of that name is also in " + tildeIn(clash, home) + " and was left there. " + who + " gets that one."})
			row.Clash = &clash
		}
		list = append(list, row)
	}
	for _, plugin := range plugins {
		pluginName := pluginDisplayName(plugin)
		reach := pluginReach(home, plugin, present, record)
		source, _ := json.Marshal(map[string]string{"plugin": pluginName})
		dir := filepath.Join(plugin, "skills")
		for _, name := range visibleNames(dir) {
			skill := filepath.Join(dir, name)
			if !lisDir(skill) {
				continue
			}
			list = append(list, wire.SharedSkill{Name: name, Path: skill, Description: skillDescription(skill),
				Source: wire.SharedSkillSource(source), Reach: reach})
		}
	}
	return list
}

// skillDescription is the description: line of a skill's front matter.
func skillDescription(skill string) *string {
	b, err := os.ReadFile(filepath.Join(skill, "SKILL.md"))
	if err != nil || !strings.HasPrefix(string(b), "---") {
		return nil
	}
	lines := strings.Split(string(b), "\n")
	for _, line := range lines[1:] {
		if strings.HasPrefix(line, "---") {
			break
		}
		if v, ok := strings.CutPrefix(line, "description:"); ok {
			v = strings.Trim(strings.TrimSpace(v), `"'`)
			return &v
		}
	}
	return nil
}

func sharedMCP(home string, present []sharedRule, secrets map[string]string, looks *[]wire.SharedLook) wire.SharedMCP {
	file := filepath.Join(home, ".agents", "mcp.json")
	result := wire.SharedMCP{File: file, Servers: []wire.SharedServer{}, RuntimeOnly: []wire.SharedRuntimeOnlyServer{}}
	own := map[string]map[string]bool{}
	for _, r := range present {
		own[r.id] = map[string]bool{}
		for _, n := range ownServerNames(home, r.id) {
			own[r.id][n] = true
		}
	}
	mine, problem := readMCPFile(file)
	if problem != "" {
		mine = nil
		result.Problem = &wire.SharedProblem{Message: problem}
		*looks = append(*looks, wire.SharedLook{Kind: wire.SharedLookKindProblem, Page: wire.SharedLookPageMCP, Item: "mcp.json",
			Text: problem + " Agents start without your servers until it is fixed."})
	}
	const appName = "agents"
	appReach := map[string]wire.SharedReach{}
	for _, r := range present {
		if r.takesStdio {
			appReach[r.id] = gets("sent at start")
		} else {
			appReach[r.id] = gets("through the bridge")
		}
	}
	result.App = []wire.SharedServer{{Name: appName, Transport: "stdio", Summary: "show_file, ask_question and the rest",
		EnvNames: []string{}, HeaderNames: []string{}, Clash: map[string]string{}, Reach: appReach}}
	seen := map[string]bool{appName: true}
	sseLeftOut := map[string][]string{}
	signIns := &mcpcatalog.SignIns{Home: home}
	for _, e := range mine {
		reach := map[string]wire.SharedReach{}
		clash := map[string]string{}
		taken := seen[e.name]
		seen[e.name] = true
		for _, r := range present {
			id := r.id
			ownFile := ""
			if own[id][e.name] {
				ownFile = filepath.Join(home, ownServerConfigs[id])
				clash[id] = ownFile
			}
			switch {
			case taken && e.name == appName:
				reach[id] = leftOut("the app's own agents server has the name")
			case taken:
				reach[id] = leftOut("an earlier server has the name")
			case e.kind == wire.MCPTransportNameSse && refusesSSE[id]:
				reach[id] = leftOut(runtimeName(id) + " takes no sse servers")
				sseLeftOut[id] = append(sseLeftOut[id], e.name)
			case ownFile != "" && keepsOwnServer[id]:
				reach[id] = ownCopy(ownFile)
			case ownFile != "" && runsBothServers[id]:
				reach[id] = gets("sent at start; its own copy runs too")
			case e.kind == wire.MCPTransportNameStdio && !r.takesStdio:
				reach[id] = gets("through the bridge")
			default:
				reach[id] = gets("sent at start")
			}
		}
		for _, id := range sortedKeys(clash) {
			what := runtimeName(id) + " uses the one from mcp.json."
			if keepsOwnServer[id] {
				what = runtimeName(id) + " uses its own copy."
			} else if runsBothServers[id] {
				what = runtimeName(id) + " runs both."
			}
			*looks = append(*looks, wire.SharedLook{Kind: wire.SharedLookKindClash, Page: wire.SharedLookPageMCP, Item: e.name,
				Text: "Also in " + tildeIn(clash[id], home) + ". " + what})
		}
		if missing := unsetSecretNames(e, secrets); len(missing) > 0 {
			verb := "aren't"
			if len(missing) == 1 {
				verb = "isn't"
			}
			why := strings.Join(missing, ", ") + " " + verb + " set"
			for _, r := range present {
				reach[r.id] = leftOut(why)
			}
			*looks = append(*looks, wire.SharedLook{Kind: wire.SharedLookKindLeftOut, Page: wire.SharedLookPageMCP, Item: e.name,
				Text: why + ", so agents start without " + e.name + "."})
		} else if needsSignInFor(e, secrets, signIns) {
			for _, r := range present {
				reach[r.id] = leftOut("needs sign-in")
			}
			*looks = append(*looks, wire.SharedLook{Kind: wire.SharedLookKindLeftOut, Page: wire.SharedLookPageMCP, Item: e.name,
				Text: e.name + " needs sign-in, so agents start without it."})
		}
		result.Servers = append(result.Servers, serverRow(e, clash, reach))
	}
	for _, id := range sortedKeys(sseLeftOut) {
		left := sseLeftOut[id]
		verb := "don't"
		if len(left) == 1 {
			verb = "doesn't"
		}
		*looks = append(*looks, wire.SharedLook{Kind: wire.SharedLookKindLeftOut, Page: wire.SharedLookPageMCP, Item: runtimeName(id),
			Text: "Takes no sse servers from the app: " + strings.Join(left, " and ") + " " + verb + " reach it."})
	}
	personal := map[string]bool{}
	for _, e := range mine {
		personal[e.name] = true
	}
	for _, r := range present {
		f, ok := ownServerConfigs[r.id]
		if !ok {
			continue
		}
		for _, n := range ownServerNames(home, r.id) {
			if !personal[n] {
				result.RuntimeOnly = append(result.RuntimeOnly, wire.SharedRuntimeOnlyServer{Name: n, RuntimeID: r.id, File: filepath.Join(home, f)})
			}
		}
	}
	return result
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for k := range m {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	return keys
}

// unsetSecretNames is each ${NAME} in the entry that secrets.env does not have. Names only.
func unsetSecretNames(e mcpEntry, secrets map[string]string) []string {
	var texts []string
	switch s := e.server; {
	case s.Stdio != nil:
		texts = append(append(texts, s.Stdio.Command), s.Stdio.Args...)
		for _, v := range s.Stdio.Env {
			texts = append(texts, v.Value)
		}
	case s.Http != nil:
		texts = append(texts, s.Http.Url)
		for _, h := range s.Http.Headers {
			texts = append(texts, h.Value)
		}
	case s.Sse != nil:
		texts = append(texts, s.Sse.Url)
		for _, h := range s.Sse.Headers {
			texts = append(texts, h.Value)
		}
	}
	seen := map[string]bool{}
	var out []string
	for _, t := range texts {
		for _, m := range secretRef.FindAllStringSubmatch(t, -1) {
			if _, ok := secrets[m[1]]; !ok && !seen[m[1]] {
				seen[m[1]] = true
				out = append(out, m[1])
			}
		}
	}
	return out
}

// needsSignInFor is an http server that asked for a sign-in and has none (#306).
func needsSignInFor(e mcpEntry, secrets map[string]string, signIns *mcpcatalog.SignIns) bool {
	filled, _ := filledServer(e.server, secrets)
	if filled.Http == nil || bringsOwnAuthorization(filled) {
		return false
	}
	return signIns.State(filled.Http.Url) == "needsSignIn"
}

func serverRow(e mcpEntry, clash map[string]string, reach map[string]wire.SharedReach) wire.SharedServer {
	row := wire.SharedServer{Name: e.name, EnvNames: []string{}, HeaderNames: []string{}, Clash: clash, Reach: reach}
	switch s := e.server; {
	case s.Stdio != nil:
		shown := []string{s.Stdio.Command}
		for i, a := range s.Stdio.Args {
			if i == 3 {
				break
			}
			shown = append(shown, maskedArgument(a))
		}
		row.Transport, row.Summary = "stdio", strings.Join(shown, " ")
		for _, v := range s.Stdio.Env {
			row.EnvNames = append(row.EnvNames, v.Name)
		}
		sort.Strings(row.EnvNames)
	case s.Http != nil:
		row.Transport, row.Summary = "http", bareURL(s.Http.Url)
		for _, h := range s.Http.Headers {
			row.HeaderNames = append(row.HeaderNames, h.Name)
		}
		sort.Strings(row.HeaderNames)
	case s.Sse != nil:
		row.Transport, row.Summary = "sse", bareURL(s.Sse.Url)
		for _, h := range s.Sse.Headers {
			row.HeaderNames = append(row.HeaderNames, h.Name)
		}
		sort.Strings(row.HeaderNames)
	}
	return row
}

// maskedArgument is an argument as it is, unless it looks like it carries a secret.
func maskedArgument(arg string) string {
	lowered := strings.ToLower(arg)
	named := false
	for _, w := range []string{"token", "key", "secret", "password", "auth"} {
		if strings.Contains(lowered, w) {
			named = strings.Contains(arg, "=")
			break
		}
	}
	long := utf8.RuneCountInString(arg) > 40 && !strings.Contains(arg, "/")
	if named || long {
		return "••••"
	}
	return arg
}

// bareURL is a URL without its query, fragment, or anything before an @.
func bareURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return "••••"
	}
	u.RawQuery, u.ForceQuery, u.Fragment, u.RawFragment, u.User = "", false, "", "", nil
	return u.String()
}

// ownServerNames is the names, and only the names, of the servers a runtime keeps in its
// own config.
func ownServerNames(home, runtimeID string) []string {
	f, ok := ownServerConfigs[runtimeID]
	if !ok {
		return nil
	}
	path := filepath.Join(home, f)
	if runtimeID == "codex" {
		b, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		// [mcp_servers.<name>], a line match rather than a TOML parser (R13).
		seen := map[string]bool{}
		var out []string
		for _, line := range strings.Split(string(b), "\n") {
			t := strings.TrimSpace(line)
			if !strings.HasPrefix(t, "[mcp_servers.") || !strings.HasSuffix(t, "]") {
				continue
			}
			name := t[len("[mcp_servers.") : len(t)-1]
			if strings.Contains(name, ".") {
				continue
			}
			name = strings.Trim(name, `"'`)
			if !seen[name] {
				seen[name] = true
				out = append(out, name)
			}
		}
		return out
	}
	servers, _ := jsonObjectAt(path)["mcpServers"].(map[string]any)
	return sortedKeys(servers)
}

func pluginDisplayName(plugin string) string {
	if n, ok := pluginManifest(plugin)["name"].(string); ok {
		return n
	}
	return filepath.Base(plugin)
}

func sharedPlugin(home, plugin string, present []sharedRule, record layoutRecord) wire.SharedPlugin {
	manifest := pluginManifest(plugin)
	servers := pluginServerNames(plugin)
	count := func(folder string, keep func(string) bool) int64 {
		var n int64
		for _, e := range visibleNames(filepath.Join(plugin, folder)) {
			if keep(e) {
				n++
			}
		}
		return n
	}
	md := func(n string) bool { return strings.HasSuffix(n, ".md") }
	contents := wire.SharedPluginContents{
		Skills:     count("skills", func(n string) bool { return lisDir(filepath.Join(plugin, "skills", n)) }),
		Commands:   count("commands", md),
		Agents:     count("agents", md),
		McpServers: int64(len(servers)),
	}
	if hooks := jsonObjectAt(filepath.Join(plugin, "hooks", "hooks.json")); hooks != nil {
		if inner, ok := hooks["hooks"].(map[string]any); ok {
			contents.Hooks = int64(len(inner))
		} else {
			contents.Hooks = int64(len(hooks))
		}
	}
	p := wire.SharedPlugin{Name: pluginDisplayName(plugin), Path: plugin, Contents: contents, Files: pluginFiles(plugin),
		ServerNames: servers, Reach: pluginReach(home, plugin, present, record)}
	if v, ok := manifest["version"].(string); ok {
		p.Version = &v
	}
	if v, ok := manifest["description"].(string); ok {
		p.Description = &v
	}
	return p
}

// pluginServerNames is PersonalDotAgents.pluginServers' names: from its .mcp.json (under
// mcpServers, or the servers themselves) or its manifest. One that is not a server is
// left out.
func pluginServerNames(plugin string) []string {
	b, _ := os.ReadFile(filepath.Join(plugin, ".mcp.json"))
	var file map[string]json.RawMessage
	_ = json.Unmarshal(b, &file)
	var listed map[string]json.RawMessage
	var order []string
	if raw, ok := file["mcpServers"]; ok && json.Unmarshal(raw, &listed) == nil {
		order = orderedKeys(raw)
	} else if len(file) > 0 {
		listed = file
	} else if m, ok := pluginManifest(plugin)["mcpServers"].(map[string]any); ok {
		raw, _ := json.Marshal(m)
		_ = json.Unmarshal(raw, &listed)
	}
	if order == nil {
		order = sortedKeys(listed)
	}
	out := []string{}
	for _, name := range order {
		if isServerEntry(listed[name]) {
			out = append(out, name)
		}
	}
	return out
}

// isServerEntry is whether parseServers would take the entry: a command, or a url of a
// type it knows.
func isServerEntry(raw json.RawMessage) bool {
	var e struct {
		Command *string `json:"command"`
		URL     *string `json:"url"`
		Type    *string `json:"type"`
		Hosted  *bool   `json:"hosted"`
	}
	if raw == nil || json.Unmarshal(raw, &e) != nil {
		return false
	}
	switch {
	case e.Command != nil:
		return true
	case e.Hosted != nil && *e.Hosted, e.URL == nil:
		return false
	case e.Type == nil:
		return true
	}
	switch *e.Type {
	case "http", "streamable-http", "streamableHttp", "sse":
		return true
	}
	return false
}

func pluginReach(home, plugin string, present []sharedRule, record layoutRecord) map[string]wire.SharedReach {
	name := pluginDisplayName(plugin)
	reach := map[string]wire.SharedReach{}
	for _, r := range present {
		switch r.handover {
		case "sessionMeta":
			reach[r.id] = gets("handed at start")
		case "sessionMetaWithServers":
			reach[r.id] = gets("handed at start; its servers go out with your MCP servers")
		case "codexMarketplace":
			if sum, ok := record.CodexPlugins[name]; ok && sum == pluginFingerprint(plugin) {
				when := ""
				if at, ok := record.CodexAddedAt[name]; ok {
					when = ", " + at.Time().Local().Format("Jan 2, 2006 at 3:04 PM")
				}
				reach[r.id] = gets("added to Codex" + when + ", a copy: added again when it changes")
			} else {
				reach[r.id] = leftOut("not added to Codex yet: the next Codex agent adds it")
			}
		default:
			if r.id == "copilot" {
				reach[r.id] = noWay("not in agents the app starts (its own CLI has it)")
			} else {
				reach[r.id] = noWay("no way in from the app")
			}
		}
	}
	return reach
}

// pluginFiles is a plugin's files, relative to it, for the detail's tree: at most 40.
func pluginFiles(plugin string) []string {
	root, err := store.Resolve(plugin)
	if err != nil {
		return []string{}
	}
	found := []string{}
	_ = filepath.WalkDir(root, func(path string, e fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if e.Name() == ".git" && e.IsDir() {
			return filepath.SkipDir
		}
		if !e.Type().IsRegular() || e.Name() == ".DS_Store" {
			return nil
		}
		found = append(found, path[len(root)+1:])
		if len(found) >= 40 {
			return filepath.SkipAll
		}
		return nil
	})
	sort.Strings(found)
	return found
}

// pluginFingerprint is PersonalDotAgents.fingerprint: each file's path, size and
// modification time, FNV-1a hashed. What the Swift host recorded when it added the plugin
// to Codex, so it is the same sum over the same lines.
func pluginFingerprint(plugin string) string {
	root, err := store.Resolve(plugin)
	if err != nil {
		root = plugin
	}
	var lines []string
	_ = filepath.WalkDir(root, func(path string, e fs.DirEntry, err error) error {
		if err != nil || !e.Type().IsRegular() {
			return nil
		}
		info, err := e.Info()
		if err != nil {
			return nil
		}
		modified := wire.DateOf(info.ModTime())
		text := strconv.FormatFloat(float64(modified), 'f', -1, 64)
		if !strings.Contains(text, ".") {
			text += ".0"
		}
		lines = append(lines, path[len(root):]+"\t"+strconv.FormatInt(info.Size(), 10)+"\t"+text)
		return nil
	})
	sort.Strings(lines)
	var hash uint64 = 0xcbf29ce484222325
	for _, b := range []byte(strings.Join(lines, "\n")) {
		hash ^= uint64(b)
		hash *= 0x100000001b3
	}
	return strconv.FormatUint(hash, 16)
}

// sharedOtherFiles is everything in the folder the other pages do not cover.
func sharedOtherFiles(shared string, appOwned map[string]bool) []wire.SharedOtherFile {
	covered := map[string]bool{"AGENTS.md": true, "skills": true, "plugins": true, "mcp.json": true, ".DS_Store": true}
	entries, _ := os.ReadDir(shared)
	files := []wire.SharedOtherFile{}
	for _, e := range entries {
		name := e.Name()
		switch {
		case covered[name]:
		case name == "personas":
			for _, p := range visibleNames(filepath.Join(shared, name)) {
				files = append(files, wire.SharedOtherFile{Path: "personas/" + p, Kind: wire.SharedOtherFileKindPersona})
			}
		case name == ".git":
			files = append(files, wire.SharedOtherFile{Path: name, Kind: wire.SharedOtherFileKindGit})
		case name == ".skill-lock.json" || name == mcpcatalog.SignInFileName:
			files = append(files, wire.SharedOtherFile{Path: name, Kind: wire.SharedOtherFileKindManaged})
		case appOwned[name]:
			files = append(files, wire.SharedOtherFile{Path: name, Kind: wire.SharedOtherFileKindApp})
		default:
			files = append(files, wire.SharedOtherFile{Path: name, Kind: wire.SharedOtherFileKindUnused})
		}
	}
	return files
}
