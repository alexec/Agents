package agentsd

import (
	"encoding/json"
	"maps"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// The shared words (#2658): Fast, Balanced and Smart; Plan, Ask and Approve for me; Request
// cards and Yes to all; Default sandbox, Runtime sandbox and No sandbox. Each is a cell of a
// table per field, one row a runtime: the runtime's own setting for that value. The table
// ships here; the person's own cells are in auto.json (autosettings.go). A cell is checked
// against what its runtime last offered (runtimeOffers): a value it no longer offers is
// dropped, and Auto does not use that runtime for it.
//
// No shipped cell gives more access than its value says (SC-005): where a runtime has no
// exact match, the cell is its nearest setting with less access, or not possible.

// autoCell is a shipped cell. models lists the model values to try, the first offered wins,
// so a plan that lacks one model still has the cell.
type autoCell struct {
	options map[string]string
	models  []string
	sandbox *wire.SandboxChoice
	client  *wire.ClientPermissionMode
	words   string
	mark    wire.AutoMark
	note    string
	// rank is how much the cell lets the agent do (permission: 0 changes nothing, 1 asks,
	// 2 does normal changes without asking; sandbox: 0 on, 1 the runtime's own, 2 off).
	rank int
}

var (
	modelLevels      = []string{string(wire.ModelLevelFast), string(wire.ModelLevelBalanced), string(wire.ModelLevelSmart)}
	permissionLevels = []string{string(wire.PermissionLevelPlan), string(wire.PermissionLevelAsk), string(wire.PermissionLevelApproveForMe)}
	requestLevels    = []string{string(wire.ClientPermissionModeDefault), string(wire.ClientPermissionModeAlwaysApprove)}
	sandboxLevels    = []string{string(wire.SandboxChoiceRuntime), string(wire.SandboxChoiceOn), string(wire.SandboxChoiceOff)}
	autoFields       = []wire.AutoField{wire.AutoFieldModel, wire.AutoFieldPermission, wire.AutoFieldPermissionRequests, wire.AutoFieldSandbox}
)

// levelRank is how much a value lets the agent do, on the cells' scale.
var levelRank = map[wire.AutoField]map[string]int{
	wire.AutoFieldPermission: {"plan": 0, "ask": 1, "approveForMe": 2},
	wire.AutoFieldSandbox:    {"on": 0, "runtime": 1, "off": 2},
}

// levelWords is each value's words, as the clients show them.
var levelWords = map[string]string{
	"fast": "Fast", "balanced": "Balanced", "smart": "Smart",
	"plan": "Plan", "ask": "Ask", "approveForMe": "Approve for me",
	"default": "Request cards", "alwaysApprove": "Yes to all",
	"runtime": "Default sandbox", "on": "Runtime sandbox", "off": "No sandbox",
}

// clientAnswered is the runtimes whose permission requests the app answers (061).
var clientAnswered = map[string]bool{"cursor": true, "grok": true, "opencode": true}

// autoShippedOrder is the order Auto tries the runtimes in before the person sets one.
var autoShippedOrder = []string{"claude", "codex", "cursor", "copilot", "gemini", "grok", "opencode", "antigravity"}

func cp(m wire.ClientPermissionMode) *wire.ClientPermissionMode { return &m }

var (
	requestCards = cp(wire.ClientPermissionModeDefault)
	yesToAll     = cp(wire.ClientPermissionModeAlwaysApprove)
)

const copilotModes = "https://agentclientprotocol.com/protocol/session-modes#"

// autoModels is the Model table. Balanced is the runtime's usual model: nothing is set,
// except on Claude, whose own default may be its largest. Effort follows the level (FR-003):
// low for Fast, the runtime's own for Balanced, high for Smart.
var autoModels = map[string]map[string]autoCell{
	"claude": {
		"fast":     {models: []string{"haiku"}, options: map[string]string{"effort": "low"}, words: "Haiku, low effort"},
		"balanced": {models: []string{"sonnet"}, words: "Sonnet"},
		"smart":    {models: []string{"opus[1m]", "opus"}, options: map[string]string{"effort": "high"}, words: "Opus, high effort"},
	},
	"codex": {
		"fast":     {models: []string{"gpt-5.6-luna"}, options: map[string]string{"reasoning_effort": "low"}, words: "5.6 Luna, low effort"},
		"balanced": {words: "Its default model"},
		"smart":    {models: []string{"gpt-6-luna"}, options: map[string]string{"reasoning_effort": "high"}, words: "6 Luna, high effort"},
	},
	"grok": {
		"fast":     {models: []string{"grok-4.7-build-fast"}, options: map[string]string{"reasoning_effort": "low"}, words: "Grok 4.7 Fast, low effort"},
		"balanced": {words: "Its default model"},
		"smart":    {models: []string{"grok-4.7"}, options: map[string]string{"reasoning_effort": "high"}, words: "Grok 4.7, high effort"},
	},
	"antigravity": {
		"fast":     {models: []string{"gemini-3.8-flash-low"}, words: "Gemini 3.8 Flash (Low)"},
		"balanced": {words: "Its default model"},
		"smart":    {models: []string{"gemini-3.8-flash-high"}, words: "Gemini 3.8 Flash (High)"},
	},
	"copilot": {
		"fast":     {words: "Its default model", mark: wire.AutoMarkNearestSafer, note: "nearest: no smaller model known"},
		"balanced": {words: "Its default model"},
		"smart":    {models: []string{"claude-sonnet-5.5"}, words: "Claude Sonnet 5.5"},
	},
}

// The runtimes whose model list the app has not measured get their default model for every
// level, said in the cell, until the nightly check or the person sets them.
func defaultModelCells() map[string]autoCell {
	same := autoCell{words: "Its default model", mark: wire.AutoMarkNearestSafer, note: "nearest: no other model known"}
	return map[string]autoCell{"fast": same, "balanced": {words: "Its default model"}, "smart": same}
}

// autoPermissions is the Permission mode table (spec, "Default mappings").
var autoPermissions = map[string]map[string]autoCell{
	"claude": {
		"plan":         {options: map[string]string{"mode": "plan"}, words: "Plan", rank: 0},
		"ask":          {options: map[string]string{"mode": "default"}, words: "Manual", rank: 1},
		"approveForMe": {options: map[string]string{"mode": "acceptEdits"}, words: "Accept edits", rank: 2},
	},
	"codex": {
		"plan":         {options: map[string]string{"mode": "read-only", "collaboration_mode": "plan"}, words: "Ask for approval, Plan", rank: 0},
		"ask":          {options: map[string]string{"mode": "read-only", "collaboration_mode": "default"}, words: "Ask for approval", rank: 1},
		"approveForMe": {options: map[string]string{"mode": "agent", "collaboration_mode": "default"}, words: "Approve for me", rank: 2},
	},
	"gemini": {
		"plan":         {options: map[string]string{"mode": "plan"}, words: "Plan", rank: 0},
		"ask":          {options: map[string]string{"mode": "default"}, words: "Default", rank: 1},
		"approveForMe": {options: map[string]string{"mode": "autoEdit"}, words: "Auto Edit", rank: 2},
	},
	"grok": {
		"plan":         {client: requestCards, words: "Default, Request cards", mark: wire.AutoMarkNearestSafer, note: "nearest safer: no plan mode", rank: 1},
		"ask":          {client: requestCards, words: "Default, Request cards", rank: 1},
		"approveForMe": {client: yesToAll, words: "Default, Yes to all", rank: 2},
	},
	"cursor": {
		"plan":         {options: map[string]string{"mode": "plan"}, client: requestCards, words: "Plan", rank: 0},
		"ask":          {options: map[string]string{"mode": "agent"}, client: requestCards, words: "Agent, Request cards", rank: 1},
		"approveForMe": {options: map[string]string{"mode": "agent"}, client: yesToAll, words: "Agent, Yes to all", rank: 2},
	},
	"opencode": {
		"plan":         {options: map[string]string{"mode": "plan"}, client: requestCards, words: "plan", rank: 0},
		"ask":          {options: map[string]string{"mode": "build"}, client: requestCards, words: "build, Request cards", rank: 1},
		"approveForMe": {options: map[string]string{"mode": "build"}, client: yesToAll, words: "build, Yes to all", rank: 2},
	},
	"copilot": {
		"plan": {options: map[string]string{"mode": copilotModes + "plan"}, words: "Plan", rank: 0},
		"ask":  {options: map[string]string{"mode": copilotModes + "agent"}, words: "Agent", rank: 1},
		"approveForMe": {options: map[string]string{"mode": copilotModes + "agent"}, words: "Agent", rank: 1,
			mark: wire.AutoMarkNearestSafer, note: "nearest safer: Autopilot and Allow all approve everything"},
	},
	"antigravity": {
		"plan": {options: map[string]string{"mode": "default"}, words: "Default", rank: 1,
			mark: wire.AutoMarkNearestSafer, note: "nearest safer: no plan mode"},
		"ask":          {options: map[string]string{"mode": "default"}, words: "Default", rank: 1},
		"approveForMe": {options: map[string]string{"mode": "auto_edit"}, words: "Auto Edit", rank: 2},
	},
}

// requestCell is the Permission requests table: the app answers only Cursor's, Grok's and
// OpenCode's; on the others the permission mode decides.
func requestCell(runtimeID, level string) autoCell {
	if clientAnswered[runtimeID] {
		if level == string(wire.ClientPermissionModeAlwaysApprove) {
			return autoCell{client: yesToAll, words: "Yes to all", rank: 2}
		}
		return autoCell{client: requestCards, words: "Request cards", rank: 1}
	}
	if level == string(wire.ClientPermissionModeAlwaysApprove) {
		return autoCell{mark: wire.AutoMarkNotPossible, words: "Not possible", note: "use Approve for me"}
	}
	return autoCell{words: "Its permission mode decides", rank: 1}
}

// sandboxCell is the Sandbox table, from the sandbox catalog (064).
func sandboxCell(runtimeID, level string) autoCell {
	choice := wire.SandboxChoice(level)
	route := sandboxCatalog[runtimeID]
	own := wire.SandboxChoiceRuntime
	fixedWords := "Default sandbox (fixed)"
	if route.fixed == wire.SandboxStateNone {
		fixedWords = "No sandbox (fixed)"
	}
	switch {
	case choice == wire.SandboxChoiceRuntime && route.fixed != "":
		return autoCell{sandbox: &own, words: fixedWords, rank: 1}
	case choice == wire.SandboxChoiceRuntime:
		return autoCell{sandbox: &own, words: "As configured", rank: 1}
	case slices.Contains(sandboxChoices(runtimeID), choice):
		c := choice
		words := map[wire.SandboxChoice]string{wire.SandboxChoiceOn: "On", wire.SandboxChoiceOff: "Off"}[choice]
		if runtimeID == "codex" && choice == wire.SandboxChoiceOff {
			words = "Off (Full access)"
		}
		return autoCell{sandbox: &c, words: words, rank: levelRank[wire.AutoFieldSandbox][level]}
	case choice == wire.SandboxChoiceOff && route.fixed == wire.SandboxStateNone:
		return autoCell{sandbox: &own, words: fixedWords, rank: 1}
	case choice == wire.SandboxChoiceOff:
		return autoCell{sandbox: &own, words: fixedWords, rank: 1, mark: wire.AutoMarkNearestSafer, note: "nearest safer: its own sandbox setting decides"}
	}
	why := "the app cannot turn its sandbox on"
	if runtimeID == "gemini" {
		why = "its sandbox never answers the app"
	}
	return autoCell{mark: wire.AutoMarkNotPossible, words: "Not possible", note: why}
}

// shippedCell is the shipped cell for a runtime, field and value.
func shippedCell(runtimeID string, field wire.AutoField, level string) autoCell {
	var c autoCell
	switch field {
	case wire.AutoFieldModel:
		table, ok := autoModels[runtimeID]
		if !ok {
			table = defaultModelCells()
		}
		c = table[level]
	case wire.AutoFieldPermission:
		c = autoPermissions[runtimeID][level]
	case wire.AutoFieldPermissionRequests:
		c = requestCell(runtimeID, level)
	case wire.AutoFieldSandbox:
		c = sandboxCell(runtimeID, level)
	}
	if c.mark == "" {
		c.mark = wire.AutoMarkAutoMapped
	}
	return c
}

func levelsOf(field wire.AutoField) []string {
	switch field {
	case wire.AutoFieldModel:
		return modelLevels
	case wire.AutoFieldPermission:
		return permissionLevels
	case wire.AutoFieldPermissionRequests:
		return requestLevels
	}
	return sandboxLevels
}

// optionChoice is one value of a select option, with its words.
type optionChoice struct{ Value, Name string }

// optionChoices is a select option's values, flat or in groups, from what a runtime offered.
func optionChoices(offers []wire.ConfigOption, id string) ([]optionChoice, bool) {
	for _, o := range offers {
		if o.ID != id {
			continue
		}
		var items []struct {
			Value   string `json:"value"`
			Name    string `json:"name"`
			Options []struct {
				Value string `json:"value"`
				Name  string `json:"name"`
			} `json:"options"`
		}
		if json.Unmarshal(o.Options, &items) != nil {
			return nil, true
		}
		var out []optionChoice
		for _, it := range items {
			if it.Value != "" {
				out = append(out, optionChoice{it.Value, it.Name})
			}
			for _, g := range it.Options {
				out = append(out, optionChoice{g.Value, g.Name})
			}
		}
		return out, true
	}
	return nil, false
}

// offeredName is a value's words in what the runtime offered, and whether it is offered.
// With nothing offered yet, every value is taken as offered: the cell is not dropped for
// a runtime the app has not asked.
func offeredName(offers []wire.ConfigOption, id, value string) (string, bool) {
	if len(offers) == 0 {
		return "", true
	}
	choices, ok := optionChoices(offers, id)
	if !ok {
		return "", false
	}
	for _, c := range choices {
		if c.Value == value {
			return c.Name, true
		}
	}
	return "", false
}

func jsonString(s string) wire.JSONValue {
	b, _ := json.Marshal(s)
	return b
}

// mapping is one cell for the runtime, the person's own where they set one, marked; offers
// is what the runtime last offered.
func cellMapping(runtimeID string, field wire.AutoField, level string, settings wire.AutoSettings, offers []wire.ConfigOption) wire.AutoMapping {
	out := wire.AutoMapping{RuntimeID: runtimeID, Field: field, Level: level}
	for _, o := range settings.Overrides {
		if o.RuntimeID == runtimeID && o.Field == field && o.Level == level {
			n := o.Native
			out.Native, out.Mark, out.Words = &n, wire.AutoMarkYours, nativeWords(runtimeID, n, offers)
			if missing := nativeNotOffered(n, offers); missing != "" {
				out.Mark, out.Note = wire.AutoMarkDropped, new(missing+" is no longer offered")
			}
			return out
		}
	}
	c := shippedCell(runtimeID, field, level)
	out.Mark, out.Words = c.mark, c.words
	if c.note != "" {
		out.Note = new(c.note)
	}
	if c.mark == wire.AutoMarkNotPossible {
		return out
	}
	n := wire.NativeSetting{Sandbox: c.sandbox, ClientPermission: c.client}
	if len(c.options) > 0 || len(c.models) > 0 {
		n.Options = map[string]wire.JSONValue{}
	}
	for k, v := range c.options {
		n.Options[k] = jsonString(v)
	}
	if len(c.models) > 0 {
		id := modelOptionID(offers)
		picked := ""
		for _, m := range c.models {
			if _, ok := offeredName(offers, id, m); ok {
				picked = m
				break
			}
		}
		if picked == "" {
			picked = c.models[0]
		}
		n.Options[id] = jsonString(picked)
	}
	out.Native = &n
	if missing := nativeNotOffered(n, offers); missing != "" {
		out.Mark, out.Note = wire.AutoMarkDropped, new(missing+" is no longer offered")
	} else if words := nativeWords(runtimeID, n, offers); words != "" && len(offers) > 0 && len(n.Options) > 0 {
		out.Words = words
	}
	return out
}

// nativeNotOffered is the first value of n the runtime did not offer last time, or "".
func nativeNotOffered(n wire.NativeSetting, offers []wire.ConfigOption) string {
	if len(offers) == 0 {
		return ""
	}
	for _, k := range slices.Sorted(maps.Keys(n.Options)) {
		v := stringValue(n.Options[k])
		if _, ok := offeredName(offers, k, v); !ok {
			return v
		}
	}
	return ""
}

// nativeWords is a native setting in the runtime's own words: its options' names, then the
// sandbox and the answer to permission requests.
func nativeWords(runtimeID string, n wire.NativeSetting, offers []wire.ConfigOption) string {
	var parts []string
	keys := slices.Sorted(maps.Keys(n.Options))
	// The model first, then the mode, then the rest, as a person reads them.
	slices.SortStableFunc(keys, func(a, b string) int { return optionOrder(a) - optionOrder(b) })
	for _, k := range keys {
		v := stringValue(n.Options[k])
		name, _ := offeredName(offers, k, v)
		if name == "" {
			name = v
		}
		if k == "collaboration_mode" && v == "default" {
			continue
		}
		if strings.Contains(k, "effort") {
			name = strings.ToLower(name) + " effort"
		}
		parts = append(parts, name)
	}
	if n.Sandbox != nil {
		parts = append(parts, map[wire.SandboxChoice]string{wire.SandboxChoiceRuntime: "As configured", wire.SandboxChoiceOn: "On", wire.SandboxChoiceOff: "Off"}[*n.Sandbox])
	}
	if n.ClientPermission != nil {
		parts = append(parts, levelWords[string(*n.ClientPermission)])
	}
	if len(parts) == 0 {
		return "Its default"
	}
	return strings.Join(parts, ", ")
}

func optionOrder(id string) int {
	switch {
	case id == "model":
		return 0
	case id == "mode":
		return 1
	case strings.Contains(id, "effort"):
		return 2
	}
	return 3
}

// autoMappings is auto/mappings: every cell of every runtime, and the choices a person can
// set a cell to.
func (d *Daemon) autoMappings() wire.AutoMappings {
	settings := d.autoSettings()
	out := wire.AutoMappings{Cells: []wire.AutoMapping{}, Choices: []wire.AutoNativeChoice{}}
	for _, id := range d.autoOrder(settings) {
		offers := d.runtimeOffers(id)
		for _, f := range autoFields {
			for _, l := range levelsOf(f) {
				out.Cells = append(out.Cells, cellMapping(id, f, l, settings, offers))
			}
			out.Choices = append(out.Choices, nativeChoices(id, f, offers)...)
		}
	}
	return out
}

// nativeChoices is what a cell of a field can be set to on a runtime: the values it offers,
// or the shipped cells' values before it has said.
func nativeChoices(runtimeID string, field wire.AutoField, offers []wire.ConfigOption) []wire.AutoNativeChoice {
	var out []wire.AutoNativeChoice
	add := func(n wire.NativeSetting) {
		for _, c := range out {
			if sameJSON(c.Native, n) {
				return
			}
		}
		out = append(out, wire.AutoNativeChoice{RuntimeID: runtimeID, Field: field, Native: n, Words: nativeWords(runtimeID, n, offers)})
	}
	single := func(id string) bool {
		choices, ok := optionChoices(offers, id)
		for _, c := range choices {
			add(wire.NativeSetting{Options: map[string]wire.JSONValue{id: jsonString(c.Value)}})
		}
		return ok && len(choices) > 0
	}
	switch field {
	case wire.AutoFieldModel:
		if single(modelOptionID(offers)) {
			return out
		}
	case wire.AutoFieldPermission:
		mo := modeOption(offers)
		if mo != nil {
			choices, _ := optionChoices(offers, mo.ID)
			for _, c := range choices {
				opts := map[string]wire.JSONValue{mo.ID: jsonString(c.Value)}
				if clientAnswered[runtimeID] {
					add(wire.NativeSetting{Options: opts, ClientPermission: requestCards})
					add(wire.NativeSetting{Options: opts, ClientPermission: yesToAll})
				} else {
					add(wire.NativeSetting{Options: opts})
				}
			}
			if len(out) > 0 {
				return out
			}
		}
	case wire.AutoFieldPermissionRequests:
		if clientAnswered[runtimeID] {
			add(wire.NativeSetting{ClientPermission: requestCards})
			add(wire.NativeSetting{ClientPermission: yesToAll})
		}
		return out
	case wire.AutoFieldSandbox:
		for _, c := range append([]wire.SandboxChoice{wire.SandboxChoiceRuntime}, sandboxChoices(runtimeID)...) {
			add(wire.NativeSetting{Sandbox: &c})
		}
		return out
	}
	settings := wire.AutoSettings{}
	for _, l := range levelsOf(field) {
		c := shippedCell(runtimeID, field, l)
		if c.mark == wire.AutoMarkNotPossible {
			continue
		}
		m := cellMapping(runtimeID, field, l, settings, offers)
		if m.Native != nil {
			add(*m.Native)
		}
	}
	return out
}
