package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"path/filepath"
	"slices"
	"sort"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/acp"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/internal/policylayers"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Allow, Ask or Off for each tool of a connector (#4099). The levels are the policy's
// connectorTools rule, in your layer for a connector of yours and in the folder's
// .agents/policy.json for one of the folder's, so a layer below can only make them tighter
// (policylayers.ToolLevel). A connector's tools are what its last health check's tools/list
// gave (mcphealth.go), with whether each writes from its annotations.
//
// What enforces them: an Off tool is in the runtime's own deny list where it has one
// (Claude's disallowedTools, Copilot's --deny-tool, OpenCode's tools), and a permission
// request for a tool is answered by its level before any card (Permission): Allow allows
// it, Off refuses it with the rule named in the chat, and Ask shows the card.

// toolLevelLayers is the layers for a destination's connectors, top down: the
// organisation's, yours, and the folder's for a folder. The last is the one a person edits
// there.
func (d *Daemon) toolLevelLayers(folder string) []policylayers.Layer {
	layers := []policylayers.Layer{
		{Ref: orgLayerRef(d.orgPolicy()), Rules: orgRulesFrom(d.orgPolicy())},
		{Ref: youLayerRef(), Rules: d.yourPolicyRules()},
	}
	if folder != "" {
		layers = append(layers, policylayers.Layer{Ref: folderLayerRef(folder), Rules: d.folderApprovedRules(folder)})
	}
	return layers
}

// checkedTools is a connector's tools as its last answered check found them, and the
// failure of its last check when it did not answer.
func (d *Daemon) checkedTools(folder *string, name string) ([]mcpToolInfo, string, bool) {
	d.healthMu.Lock()
	defer d.healthMu.Unlock()
	r, ok := d.results[healthID(folder, name)]
	if !ok {
		return nil, "", false
	}
	if r.check != wire.MCPCheckStateAnswered {
		return nil, r.err, false
	}
	return r.tools, "", true
}

func destinationFolder(dest wire.SkillDestination) string {
	if dest.Kind == wire.SkillDestinationKindFolder && dest.Folder != nil {
		return filepath.Clean(*dest.Folder)
	}
	return ""
}

// mcpTools is mcp/tools: a connector's tools with their levels, as the destination's layer
// sees them.
func (d *Daemon) mcpTools(dest wire.SkillDestination, name string) (wire.MCPToolsAnswer, error) {
	if err := d.requireMCPFolder(dest); err != nil {
		return wire.MCPToolsAnswer{}, mcpRefusal(err)
	}
	folder := destinationFolder(dest)
	layers := d.toolLevelLayers(folder)
	edited, above := layers[len(layers)-1], layers[:len(layers)-1]
	answer := wire.MCPToolsAnswer{Name: name, Tools: []wire.MCPToolRow{}}
	if rule, ok := edited.Rules.ConnectorTools[name]; ok && rule.Writes != nil {
		w := *rule.Writes
		answer.Writes = &w
	}
	if v, by := policylayers.WritesLevel(above, name); by != nil {
		line := policylayers.LayerName(*by) + ": at most " + policylayers.ToolLevelWords(v)
		answer.WritesCap, answer.WritesCapLine = &v, &line
	}
	var at *string
	if folder != "" {
		at = &folder
	}
	tools, failure, ok := d.checkedTools(at, name)
	if !ok {
		problem := "Its tools show once a check of it has answered."
		if failure != "" {
			problem = "Its tools show once it answers a check. " + failure
		}
		answer.Problem = &problem
		return answer, nil
	}
	for _, t := range tools {
		level, _ := policylayers.ToolLevel(layers, name, t.name, t.writes)
		row := wire.MCPToolRow{Name: t.name, Writes: t.writes, Level: level}
		if t.title != "" && t.title != t.name {
			title := t.title
			row.Title = &title
		}
		if rule, ok := edited.Rules.ConnectorTools[name]; ok {
			if v, ok := rule.Tools[t.name]; ok {
				row.Own = &v
			}
		}
		if v, by := policylayers.ToolLevel(above, name, t.name, t.writes); by != nil {
			line := policylayers.LayerName(*by) + ": at most " + policylayers.ToolLevelWords(v)
			row.Cap, row.CapLine = &v, &line
		}
		answer.Tools = append(answer.Tools, row)
	}
	return answer, nil
}

// withToolLevel is rules with one level set, or cleared when level is nil: a tool's own, or
// the writes switch when tool is nil. A connector left with nothing set is taken out.
func withToolLevel(rules wire.PolicyRules, name string, tool *string, level *wire.ConnectorToolLevel) wire.PolicyRules {
	all := map[string]wire.PolicyConnectorRule{}
	for k, v := range rules.ConnectorTools {
		all[k] = v
	}
	rule := all[name]
	if tool == nil {
		rule.Writes = level
	} else {
		tools := map[string]wire.ConnectorToolLevel{}
		for k, v := range rule.Tools {
			tools[k] = v
		}
		if level == nil {
			delete(tools, *tool)
		} else {
			tools[*tool] = *level
		}
		rule.Tools = tools
		if len(tools) == 0 {
			rule.Tools = nil
		}
	}
	if rule.Writes == nil && len(rule.Tools) == 0 {
		delete(all, name)
	} else {
		all[name] = rule
	}
	rules.ConnectorTools = all
	if len(all) == 0 {
		rules.ConnectorTools = nil
	}
	return rules
}

// mcpSetToolLevel is mcp/setToolLevel: the level written to the destination's layer, by the
// person's own clients only (an agent never loosens its own tools).
func (d *Daemon) mcpSetToolLevel(c *Client, r wire.MCPSetToolLevelRequest) (wire.MCPToolsAnswer, error) {
	if err := forbiddenCallerRefusal(c); err != nil {
		return wire.MCPToolsAnswer{}, err
	}
	if err := d.requireMCPFolder(r.Destination); err != nil {
		return wire.MCPToolsAnswer{}, mcpRefusal(err)
	}
	if r.Name == "" || (r.Tool != nil && *r.Tool == "") {
		return wire.MCPToolsAnswer{}, Invalid("a connector and a tool need a name")
	}
	if folder := destinationFolder(r.Destination); folder != "" {
		rules := withToolLevel(d.folderApprovedRules(folder), r.Name, r.Tool, r.Level)
		if _, err := d.setFolderPolicy(wire.SetFolderPolicyRequest{Folder: store.FolderURL(folder), Rules: rules}); err != nil {
			return wire.MCPToolsAnswer{}, err
		}
	} else {
		err := d.editYoursLocked(func(rules *wire.PolicyRules) error {
			next := withToolLevel(*rules, r.Name, r.Tool, r.Level)
			raw, _ := json.Marshal(next)
			if _, err := policylayers.Validate(raw); err != nil {
				return Invalid("Your policy: %v", err)
			}
			*rules = next
			return nil
		})
		if err != nil {
			return wire.MCPToolsAnswer{}, err
		}
	}
	return d.mcpTools(r.Destination, r.Name)
}

func (d *Daemon) registerMCPTools() {
	On(d, wire.CallMCPTools, func(_ context.Context, _ *Client, r wire.MCPToolsRequest) (wire.MCPToolsAnswer, error) {
		return d.mcpTools(r.Destination, r.Name)
	})
	On(d, wire.CallMCPSetToolLevel, func(_ context.Context, c *Client, r wire.MCPSetToolLevelRequest) (wire.MCPToolsAnswer, error) {
		return d.mcpSetToolLevel(c, r)
	})
}

// MARK: a session's tools

// sessionTool is one tool of a connector a session is given, with its level.
type sessionTool struct {
	server, tool string
	level        wire.ConnectorToolLevel
	decides      *wire.PolicyLayerRef
}

// sessionToolLevels is every tool a session in folder is given that the rule or its
// default sets, by connector: each checked tool with its level, and each tool a layer names
// that no check has seen yet (a tool not checked counts as one that writes).
func (d *Daemon) sessionToolLevels(folder string, agent wire.UUID) []sessionTool {
	layers := d.toolLevelLayers(folder)
	var out []sessionTool
	for _, e := range d.sessionEntries(folder, agent) {
		tools, _, _ := d.checkedTools(e.folder, e.name)
		seen := map[string]bool{}
		for _, t := range tools {
			seen[t.name] = true
			level, by := policylayers.ToolLevel(layers, e.name, t.name, t.writes)
			out = append(out, sessionTool{server: e.name, tool: t.name, level: level, decides: by})
		}
		var named []string
		for _, l := range layers {
			for t := range l.Rules.ConnectorTools[e.name].Tools {
				if !seen[t] {
					seen[t] = true
					named = append(named, t)
				}
			}
		}
		sort.Strings(named)
		for _, t := range named {
			level, by := policylayers.ToolLevel(layers, e.name, t, true)
			out = append(out, sessionTool{server: e.name, tool: t, level: level, decides: by})
		}
	}
	return out
}

// offTools is the tools a session may never use, as server and tool.
func (d *Daemon) offTools(a *wire.Agent) [][2]string {
	var out [][2]string
	for _, t := range d.sessionToolLevels(folderPath(a), a.ID) {
		if t.level == wire.ConnectorToolLevelOff {
			out = append(out, [2]string{t.server, t.tool})
		}
	}
	return out
}

// withToolLevels gives the runtime its Off tools in its own form, where it has one: Claude's
// disallowedTools on session/new (mcp__<server>__<tool>), Copilot's --deny-tool
// (<server>(<tool>)) and OpenCode's tools switched off in its configuration
// (<server>_<tool>). The others are refused when they ask (Permission).
func withToolLevels(l acp.Launch, meta map[string]any, runtimeID string, off [][2]string) (acp.Launch, map[string]any) {
	if len(off) == 0 {
		return l, meta
	}
	switch runtimeID {
	case "claude":
		code, _ := meta["claudeCode"].(map[string]any)
		options, _ := code["options"].(map[string]any)
		var denied []string
		if v, ok := options["disallowedTools"].([]string); ok {
			denied = slices.Clone(v)
		}
		for _, t := range off {
			denied = append(denied, "mcp__"+t[0]+"__"+t[1])
		}
		meta = mergeMeta(meta, map[string]any{"claudeCode": map[string]any{"options": map[string]any{"disallowedTools": denied}}})
	case "copilot":
		args := slices.Clone(l.Args)
		for _, t := range off {
			args = append(args, "--deny-tool", t[0]+"("+t[1]+")")
		}
		l.Args = args
	case "opencode":
		const key = "OPENCODE_CONFIG_CONTENT"
		config := map[string]any{}
		for _, kv := range l.Env {
			if v, ok := cutEnv(kv, key); ok {
				if err := json.Unmarshal([]byte(v), &config); err != nil {
					log.Printf("tool levels: %s is not JSON: %v", key, err)
					return l, meta
				}
			}
		}
		tools, _ := config["tools"].(map[string]any)
		merged := map[string]any{}
		for k, v := range tools {
			merged[k] = v
		}
		for _, t := range off {
			merged[t[0]+"_"+t[1]] = false
		}
		config["tools"] = merged
		b, _ := json.Marshal(config)
		l.Env = append(without(l.Env, key), key+"="+string(b))
	}
	return l, meta
}

func cutEnv(kv, key string) (string, bool) {
	if len(kv) > len(key) && kv[:len(key)] == key && kv[len(key)] == '=' {
		return kv[len(key)+1:], true
	}
	return "", false
}

// toolLevelAnswer is a permission request answered by its tool's level: the option to
// choose and true for Allow and Off, false for Ask (or a call to no connector's tool).
func (l *live) toolLevelAnswer(req wire.PermissionRequest) (string, bool) {
	d := l.d
	a := d.Store.Agent(l.id)
	if a == nil {
		return "", false
	}
	tools := d.sessionToolLevels(folderPath(a), l.id)
	if len(tools) == 0 {
		return "", false
	}
	var servers []string
	for _, t := range tools {
		if !slices.Contains(servers, t.server) {
			servers = append(servers, t.server)
		}
	}
	var hit *sessionTool
	for _, c := range shapeCandidates(req.ToolCall, servers) {
		for i := range tools {
			if tools[i].server == c.server && tools[i].tool == c.tool {
				hit = &tools[i]
				break
			}
		}
		if hit != nil {
			break
		}
	}
	if hit == nil {
		return "", false
	}
	pick := func(kinds ...wire.PermissionOptionKind) string {
		for _, kind := range kinds {
			for _, o := range req.Options {
				if o.Kind == kind {
					return o.OptionID
				}
			}
		}
		return ""
	}
	switch hit.level {
	case wire.ConnectorToolLevelAllow:
		if option := pick(wire.PermissionOptionKindAllowOnce, wire.PermissionOptionKindAllowAlways); option != "" {
			return option, true
		}
	case wire.ConnectorToolLevelOff:
		option := pick(wire.PermissionOptionKindRejectOnce, wire.PermissionOptionKindRejectAlways)
		words := toolOffWords(hit.server, hit.tool, hit.decides)
		var err error
		if hit.decides != nil {
			err = policyRefusal("policy", string(wire.PolicyRuleNameConnectorTools), words, nil, *hit.decides)
		}
		d.recordPolicyStop(l.id, err, "", words)
		return option, true
	}
	return "", false
}

// toolOffWords says which tool is off and where to change it.
func toolOffWords(server, tool string, by *wire.PolicyLayerRef) string {
	where := "Connectors in Settings"
	if by != nil && by.Kind == "folder" {
		where = "the folder's Connectors"
	}
	return "The tool " + tool + " of " + server + " is Off. Change it in " + where + "."
}
