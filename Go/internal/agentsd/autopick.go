package agentsd

import (
	"context"
	"maps"
	"slices"
	"strings"

	"github.com/alexec/agents/Go/internal/policylayers"
	"github.com/alexec/agents/Go/wire"
)

// Auto (#2658): a runtime choice that is not a runtime. At agents/start the daemon picks the
// first runtime in the person's order that is included, installed, signed in, not out and
// can honour every value asked for; a rate-limited one is tried after the others (FR-006).
// The pick and the native settings it gave are kept on the agent, and its runtime never
// changes in the session (FR-007, FR-008).

const autoRuntimeID = "auto"

// autoSettings is auto.json, with the runtimes this host knows.
func (d *Daemon) autoSettings() wire.AutoSettings {
	var s wire.AutoSettings
	d.readSetting("auto.json", &s)
	if s.Order == nil {
		s.Order = []string{}
	}
	if s.Excluded == nil {
		s.Excluded = []string{}
	}
	if s.Overrides == nil {
		s.Overrides = []wire.AutoOverride{}
	}
	return s
}

// setAutoSettings is auto/set: runtimes this host does not know are kept, so a Mac that
// sends the same file to each machine does not lose a server's runtime (FR-017).
func (d *Daemon) setAutoSettings(in wire.AutoSettings) (wire.AutoSettings, error) {
	in.SetBy = nil
	seen := map[string]bool{}
	order := []string{}
	for _, id := range in.Order {
		if id != "" && id != autoRuntimeID && !seen[id] {
			seen[id] = true
			order = append(order, id)
		}
	}
	in.Order = order
	if in.Excluded == nil {
		in.Excluded = []string{}
	}
	overrides := []wire.AutoOverride{}
	for _, o := range in.Overrides {
		if slices.Contains(levelsOf(o.Field), o.Level) {
			overrides = append(overrides, o)
		}
	}
	in.Overrides = overrides
	if err := d.writeSetting("auto.json", in); err != nil {
		return wire.AutoSettings{}, &Error{Code: wire.FailureCouldNotSave, Message: "auto.json: " + err.Error()}
	}
	st := d.autoSettings()
	Broadcast(d, wire.NotifyAutoChanged, st)
	return st, nil
}

// autoOrder is every runtime this host knows, in the person's order, then the shipped one.
func (d *Daemon) autoOrder(s wire.AutoSettings) []string {
	var out []string
	add := func(id string) {
		if runtimeByID(id) != nil && !slices.Contains(out, id) {
			out = append(out, id)
		}
	}
	for _, id := range s.Order {
		add(id)
	}
	for _, id := range autoShippedOrder {
		add(id)
	}
	for _, r := range catalog {
		add(r.ID)
	}
	return out
}

// autoLevels is the levels a start asks for, with the defaults Auto uses for a value not
// given: Balanced, and the effective permissionMode rule (#2957, FR-008), else Ask.
func (d *Daemon) autoLevels(l *wire.Levels) wire.Levels {
	out := wire.Levels{}
	if l != nil {
		out = *l
	}
	if out.Model == nil {
		m := wire.ModelLevelBalanced
		out.Model = &m
	}
	if out.Permission == nil {
		p := wire.PermissionLevelAsk
		if v, _, ok := d.effectivePermissionMode(); ok {
			p = v
		}
		out.Permission = &p
	}
	return out
}

// permissionLevelCeiling caps or refuses levels.Permission against the effective
// permissionMode rule (#2957, FR-008): a person's own choice looser than the ceiling is
// refused; an agent's, a helper's or a workflow's own falls to the ceiling, with a note for
// the new agent's chat. levels is changed in place when it falls.
func (d *Daemon) permissionLevelCeiling(levels *wire.Levels, by startedBy) (note string, err error) {
	if levels.Permission == nil {
		return "", nil
	}
	ceiling, layer, ok := d.effectivePermissionMode()
	if !ok || policylayers.PermissionModeOrder(*levels.Permission) >= policylayers.PermissionModeOrder(ceiling) {
		return "", nil
	}
	if by.owner == wire.SessionLabelOwnerPerson && by.agent == nil {
		return "", policyRefusal("policy", "permissionMode", "Your policy allows at most "+permissionWord(ceiling)+".", nil, *layer)
	}
	asked := permissionWord(*levels.Permission)
	levels.Permission = &ceiling
	return "It asked for " + asked + ". " + layer.Name + " allows at most " + permissionWord(ceiling) + ". It runs within that.", nil
}

// levelCells is the cells a start's levels and sandbox ask for on one runtime.
func levelCells(runtimeID string, l wire.Levels, sandbox *wire.SandboxChoice, settings wire.AutoSettings, offers []wire.ConfigOption) []wire.AutoMapping {
	var cells []wire.AutoMapping
	if l.Model != nil {
		cells = append(cells, cellMapping(runtimeID, wire.AutoFieldModel, string(*l.Model), settings, offers))
	}
	if l.Permission != nil {
		cells = append(cells, cellMapping(runtimeID, wire.AutoFieldPermission, string(*l.Permission), settings, offers))
	}
	if l.PermissionRequests != nil {
		cells = append(cells, cellMapping(runtimeID, wire.AutoFieldPermissionRequests, string(*l.PermissionRequests), settings, offers))
	}
	if sandbox != nil {
		cells = append(cells, cellMapping(runtimeID, wire.AutoFieldSandbox, string(*sandbox), settings, offers))
	}
	return cells
}

// nativeOf is the native setting the cells give together.
func nativeOf(cells []wire.AutoMapping) wire.NativeSetting {
	var n wire.NativeSetting
	for _, c := range cells {
		if c.Native == nil {
			continue
		}
		for k, v := range c.Native.Options {
			if n.Options == nil {
				n.Options = map[string]wire.JSONValue{}
			}
			n.Options[k] = v
		}
		if c.Native.Sandbox != nil {
			n.Sandbox = c.Native.Sandbox
		}
		if c.Native.ClientPermission != nil {
			n.ClientPermission = c.Native.ClientPermission
		}
	}
	return n
}

// cantHonour is why a runtime cannot give one of the cells, in short, or "".
func cantHonour(cells []wire.AutoMapping) string {
	for _, c := range cells {
		switch c.Mark {
		case wire.AutoMarkNotPossible:
			return "no " + levelWords[c.Level]
		case wire.AutoMarkDropped:
			return levelWords[c.Level] + " no longer offered"
		}
	}
	return ""
}

// credentialState is the allowance of the credential a new session on the runtime spends.
func (d *Daemon) credentialState(runtimeID string) (wire.AllowanceState, bool) {
	key := ownKey(runtimeID)
	if def := d.defaultAccount(runtimeID); def != nil {
		key = accountKey(runtimeID, &def.ID)
	}
	d.allowMu.Lock()
	defer d.allowMu.Unlock()
	s, ok := d.allowancesLocked()[key]
	return s, ok
}

// pickRuntime is Auto's pick for the levels and sandbox, or "" and why each runtime was not
// used. A helper of a sandboxed agent still gets no No sandbox, at its start (FR-021).
func (d *Daemon) pickRuntime(l wire.Levels, sandbox *wire.SandboxChoice) (string, wire.NativeSetting, []wire.AutoSkip) {
	settings := d.autoSettings()
	skipped := []wire.AutoSkip{}
	type candidate struct {
		id     string
		native wire.NativeSetting
	}
	var limited []candidate
	skip := func(id, why string) { skipped = append(skipped, wire.AutoSkip{RuntimeID: id, Reason: why}) }
	for _, id := range d.autoOrder(settings) {
		rt := runtimeByID(id)
		if slices.Contains(settings.Excluded, id) {
			skip(id, "left out")
			continue
		}
		if p, _, _ := locateFor(rt); p == "" {
			skip(id, "not installed")
			continue
		}
		if d.needsSignIn(id) != nil {
			skip(id, "not signed in")
			continue
		}
		if err := d.accountRefusal(id, d.defaultAccount(id)); err != nil {
			skip(id, "not allowed")
			continue
		}
		cells := levelCells(id, l, sandbox, settings, d.runtimeOffers(id))
		if why := cantHonour(cells); why != "" {
			skip(id, why)
			continue
		}
		// The effective sandbox rule (#998, #2957): a runtime that cannot turn its own on
		// is not used.
		if d.sandboxRequired() {
			if _, ok := requiredSandbox(id); !ok {
				skip(id, "no sandbox, which your policy requires")
				continue
			}
		}
		native := nativeOf(cells)
		if s, ok := d.credentialState(id); ok {
			if isOutState(s) {
				skip(id, "out")
				continue
			}
			if s.Status.RateLimited != nil {
				limited = append(limited, candidate{id, native})
				continue
			}
		}
		return id, native, skipped
	}
	if len(limited) > 0 {
		return limited[0].id, limited[0].native, skipped
	}
	return "", wire.NativeSetting{}, skipped
}

// noRuntime is autoNoRuntime: the prompt stays, and the reasons say why (FR-011).
func noRuntime(skipped []wire.AutoSkip) error {
	parts := make([]string, 0, len(skipped))
	for _, s := range skipped {
		parts = append(parts, runtimeName(s.RuntimeID)+": "+s.Reason)
	}
	msg := "No runtime can take this session."
	if len(parts) > 0 {
		msg = "No runtime can take this session. " + strings.Join(parts, "; ") + "."
	}
	return &Error{Code: wire.FailureAutoNoRuntime, Message: msg, Data: map[string]any{"skipped": skipped}}
}

// applyLevels folds the levels into a start on a named or picked runtime: the model and mode
// cells' options where the start set none of its own (a native value wins, the ⋯ own menu),
// and the answer to permission requests. On Auto the permission mode's cell answers them
// (FR-010); on a named runtime the pill, or Settings, does.
func applyLevels(runtimeID string, l wire.Levels, values map[string]wire.JSONValue, auto bool, settings wire.AutoSettings, offers []wire.ConfigOption) (map[string]wire.JSONValue, *wire.ClientPermissionMode) {
	out := maps.Clone(values)
	if out == nil {
		out = map[string]wire.JSONValue{}
	}
	var client *wire.ClientPermissionMode
	fill := func(m wire.AutoMapping) {
		if m.Native == nil || m.Mark == wire.AutoMarkNotPossible || m.Mark == wire.AutoMarkDropped {
			return
		}
		for k, v := range m.Native.Options {
			if _, set := values[k]; !set {
				out[k] = v
			}
		}
		if auto && m.Native.ClientPermission != nil {
			client = m.Native.ClientPermission
		}
	}
	if l.Model != nil {
		fill(cellMapping(runtimeID, wire.AutoFieldModel, string(*l.Model), settings, offers))
	}
	if l.Permission != nil {
		fill(cellMapping(runtimeID, wire.AutoFieldPermission, string(*l.Permission), settings, offers))
	}
	if l.PermissionRequests != nil && clientAnswered[runtimeID] && !auto {
		c := *l.PermissionRequests
		client = &c
	}
	return out, client
}

// matchLevels is the values an agent runs with now, where its own settings match a cell of
// its runtime: Custom (absent) where none does.
func (d *Daemon) matchLevels(a *wire.Agent) *wire.Levels {
	settings := d.autoSettings()
	offers := a.AdvertisedOptions
	if len(offers) == 0 {
		offers = d.runtimeOffers(a.RuntimeID)
	}
	value := func(id string) string {
		if v, ok := a.StartOptions.Values[id]; ok {
			return stringValue(v)
		}
		for _, o := range a.AdvertisedOptions {
			if o.ID == id {
				return stringValue(o.CurrentValue)
			}
		}
		return ""
	}
	matches := func(m wire.AutoMapping, field wire.AutoField) bool {
		if m.Native == nil || m.Mark == wire.AutoMarkNotPossible {
			return false
		}
		if len(m.Native.Options) == 0 && field == wire.AutoFieldModel {
			// The runtime's own default: the agent set no model of its own.
			_, set := a.StartOptions.Values[modelOptionID(offers)]
			return !set
		}
		for k, v := range m.Native.Options {
			if value(k) != stringValue(v) {
				return false
			}
		}
		if field == wire.AutoFieldPermission && m.Native.ClientPermission != nil && a.Auto != nil {
			return a.ClientPermission != nil && *a.ClientPermission == *m.Native.ClientPermission
		}
		return true
	}
	out := wire.Levels{}
	// The more particular cells first: Fast and Smart set a model, Balanced may set none.
	for _, l := range []string{"fast", "smart", "balanced"} {
		if matches(cellMapping(a.RuntimeID, wire.AutoFieldModel, l, settings, offers), wire.AutoFieldModel) {
			m := wire.ModelLevel(l)
			out.Model = &m
			break
		}
	}
	for _, l := range permissionLevels {
		m := cellMapping(a.RuntimeID, wire.AutoFieldPermission, l, settings, offers)
		if m.Mark == wire.AutoMarkNearestSafer && l == string(wire.PermissionLevelPlan) {
			// A runtime with no plan mode: its Ask cell is the same, and says it truly.
			continue
		}
		if matches(m, wire.AutoFieldPermission) {
			p := wire.PermissionLevel(l)
			out.Permission = &p
			break
		}
	}
	if a.Auto != nil && a.Auto.Levels.Permission != nil && out.Permission != nil &&
		*out.Permission == wire.PermissionLevelAsk && *a.Auto.Levels.Permission == wire.PermissionLevelPlan {
		out.Permission = a.Auto.Levels.Permission
	}
	if clientAnswered[a.RuntimeID] && a.ClientPermission != nil {
		c := *a.ClientPermission
		out.PermissionRequests = &c
	}
	return &out
}

// setLevels is agents/setLevels: a running agent's model level or permission mode, mapped
// on its own runtime and set through agents/setOption, from its next step (Story 2).
func (d *Daemon) setLevels(ctx context.Context, r wire.SetLevelsRequest) (wire.Agent, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
	}
	// The effective permissionMode rule (#2957, FR-008): a direct choice looser than the
	// ceiling is refused, as this call always is the person's or an agent's own, not a
	// helper or workflow's start that could fall to it instead (resolveLevels).
	if r.Levels.Permission != nil {
		if ceiling, layer, ok := d.effectivePermissionMode(); ok &&
			policylayers.PermissionModeOrder(*r.Levels.Permission) < policylayers.PermissionModeOrder(ceiling) {
			return wire.Agent{}, policyRefusal("policy", "permissionMode", "Your policy allows at most "+permissionWord(ceiling)+".", nil, *layer)
		}
	}
	settings := d.autoSettings()
	offers := a.AdvertisedOptions
	if len(offers) == 0 {
		offers = d.runtimeOffers(a.RuntimeID)
	}
	cells := levelCells(a.RuntimeID, wire.Levels{Model: r.Levels.Model, Permission: r.Levels.Permission}, nil, settings, offers)
	if why := cantHonour(cells); why != "" {
		return wire.Agent{}, Invalid("%s has %s.", runtimeName(a.RuntimeID), why)
	}
	n := nativeOf(cells)
	yes := a.Auto != nil && n.ClientPermission != nil && *n.ClientPermission == wire.ClientPermissionModeAlwaysApprove ||
		r.Levels.PermissionRequests != nil && clientAnswered[a.RuntimeID] && *r.Levels.PermissionRequests == wire.ClientPermissionModeAlwaysApprove
	if yes {
		if err := d.alwaysApproveRefusal(); err != nil {
			return wire.Agent{}, err
		}
	}
	for _, k := range slices.Sorted(maps.Keys(n.Options)) {
		if _, err := d.setOption(ctx, wire.SetOptionRequest{AgentID: a.ID, OptionID: k, Value: n.Options[k]}); err != nil {
			return wire.Agent{}, err
		}
	}
	if a.Auto != nil && n.ClientPermission != nil {
		c := *n.ClientPermission
		d.change(a.ID, func(a *wire.Agent) { a.ClientPermission = &c })
	}
	if r.Levels.PermissionRequests != nil && clientAnswered[a.RuntimeID] {
		c := *r.Levels.PermissionRequests
		d.change(a.ID, func(a *wire.Agent) { a.ClientPermission = &c })
	}
	d.change(a.ID, func(a *wire.Agent) {
		if a.Auto != nil {
			if r.Levels.Model != nil {
				a.Auto.Levels.Model = r.Levels.Model
			}
			if r.Levels.Permission != nil {
				a.Auto.Levels.Permission = r.Levels.Permission
			}
		}
		a.Levels = d.matchLevels(a)
	})
	return *d.Store.Agent(a.ID), nil
}

// setClientPermission is agents/setClientPermission: the agent's own answer to permission
// requests, nil to follow Settings (FR-019).
func (d *Daemon) setClientPermission(r wire.SetClientPermissionRequest) (wire.Agent, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
	}
	if !clientAnswered[a.RuntimeID] {
		return wire.Agent{}, Invalid("%s asks by its permission mode; the app does not answer its requests.", runtimeName(a.RuntimeID))
	}
	if r.Mode != nil && clientPermissionMode(string(*r.Mode)) == wire.ClientPermissionModeAlwaysApprove {
		if err := d.alwaysApproveRefusal(); err != nil {
			return wire.Agent{}, err
		}
	}
	d.change(a.ID, func(a *wire.Agent) {
		if r.Mode == nil {
			a.ClientPermission = nil
		} else {
			m := clientPermissionMode(string(*r.Mode))
			a.ClientPermission = &m
		}
		a.Levels = d.matchLevels(a)
	})
	return *d.Store.Agent(a.ID), nil
}

// autoPreview is auto/preview: what Auto would pick now, for the chooser's "Picks Claude
// now" and the menus' "Balanced: Sonnet on Claude".
func (d *Daemon) autoPreview(r wire.AutoPreviewRequest) wire.AutoPreview {
	id, native, skipped := d.pickRuntime(d.autoLevels(r.Levels), r.Sandbox)
	out := wire.AutoPreview{Skipped: skipped}
	if id != "" {
		out.RuntimeID, out.Native = &id, &native
	}
	return out
}

func (d *Daemon) registerAuto() {
	On(d, wire.CallAutoState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.AutoSettings, error) {
		return d.autoSettings(), nil
	})
	On(d, wire.CallAutoSet, func(ctx context.Context, c *Client, s wire.AutoSettings) (wire.AutoSettings, error) {
		return d.setAutoSettings(s)
	})
	On(d, wire.CallAutoMappings, func(ctx context.Context, c *Client, _ wire.Empty) (wire.AutoMappings, error) {
		return d.autoMappings(), nil
	})
	On(d, wire.CallAutoPreview, func(ctx context.Context, c *Client, r wire.AutoPreviewRequest) (wire.AutoPreview, error) {
		return d.autoPreview(r), nil
	})
	On(d, wire.CallAgentsSetLevels, func(ctx context.Context, c *Client, r wire.SetLevelsRequest) (wire.Agent, error) {
		return d.setLevels(ctx, r)
	})
	On(d, wire.CallAgentsSetClientPermission, func(ctx context.Context, c *Client, r wire.SetClientPermissionRequest) (wire.Agent, error) {
		return d.setClientPermission(r)
	})
}

// autoNote is the line an Auto agent's chat starts with: what it picked, and why not the
// runtimes before it.
func autoNote(p wire.AutoPick) string {
	s := "Auto picked " + runtimeName(p.RuntimeID) + "."
	var parts []string
	for _, k := range p.Skipped {
		parts = append(parts, runtimeName(k.RuntimeID)+": "+k.Reason)
	}
	if len(parts) > 0 {
		s += " Not used: " + strings.Join(parts, "; ") + "."
	}
	return s
}

// resolveLevels is a start's levels made the runtime's own settings (#2658): on Auto, the
// runtime is picked first (FR-006); then the model and mode cells fill the options the start
// did not set itself. It returns the pick, for an Auto start, the agent's own answer to
// permission requests, when the start gives one, and a note for the chat when the
// effective permissionMode rule (#2957, FR-008) capped a looser choice.
func (d *Daemon) resolveLevels(r *wire.StartRequest, by startedBy) (pick *wire.AutoPick, client *wire.ClientPermissionMode, note string, err error) {
	auto := r.RuntimeID == autoRuntimeID
	if !auto && r.Levels == nil {
		return nil, nil, "", nil
	}
	settings := d.autoSettings()
	levels := wire.Levels{}
	if r.Levels != nil {
		levels = *r.Levels
	}
	askOnly := false
	if auto {
		levels = d.autoLevels(r.Levels)
		// On Auto, permission requests follow the permission mode (FR-010), but no further
		// than a start that asks for Request cards (a helper whose starter asks).
		askOnly = levels.PermissionRequests != nil && *levels.PermissionRequests == wire.ClientPermissionModeDefault
		levels.PermissionRequests = nil
	}
	note, err = d.permissionLevelCeiling(&levels, by)
	if err != nil {
		return nil, nil, "", err
	}
	if auto {
		id, native, skipped := d.pickRuntime(levels, r.Sandbox)
		if id == "" {
			return nil, nil, "", noRuntime(skipped)
		}
		r.RuntimeID = id
		if r.Sandbox != nil && native.Sandbox != nil {
			s := *native.Sandbox
			r.Sandbox = &s
		}
		pick = &wire.AutoPick{RuntimeID: id, Levels: levels, Native: native, Skipped: skipped}
	}
	var values map[string]wire.JSONValue
	values, client = applyLevels(r.RuntimeID, levels, r.StartOptions.Values, auto, settings, d.runtimeOffers(r.RuntimeID))
	r.StartOptions.Values = values
	if askOnly && client != nil {
		client = requestCards
	}
	return pick, client, note, nil
}

// The words in workflow files and start_session (#2658): the shared values in lower case
// with hyphens.
var (
	modelLevelWords      = map[string]wire.ModelLevel{"fast": wire.ModelLevelFast, "balanced": wire.ModelLevelBalanced, "smart": wire.ModelLevelSmart}
	permissionLevelWords = map[string]wire.PermissionLevel{"plan": wire.PermissionLevelPlan, "ask": wire.PermissionLevelAsk, "approve-for-me": wire.PermissionLevelApproveForMe, "bypass-permissions": wire.PermissionLevelBypassPermissions}
	requestWords         = map[string]wire.ClientPermissionMode{"request-cards": wire.ClientPermissionModeDefault, "yes-to-all": wire.ClientPermissionModeAlwaysApprove}
	sandboxWords         = map[string]wire.SandboxChoice{"default": wire.SandboxChoiceRuntime, "runtime": wire.SandboxChoiceOn, "none": wire.SandboxChoiceOff}
	// A runtime's own permission modes that Auto takes as a level (#2873), so a file
	// written for Claude runs the same on Auto.
	permissionAliases = map[string]wire.PermissionLevel{"default": wire.PermissionLevelAsk, "auto": wire.PermissionLevelApproveForMe, "bypassPermissions": wire.PermissionLevelBypassPermissions}
)

// permissionWord is a permission level in a file's words.
func permissionWord(p wire.PermissionLevel) string {
	for w, l := range permissionLevelWords {
		if l == p {
			return w
		}
	}
	return string(p)
}

// fileLevels is a workflow's or a helper's model, permission mode, permission requests and
// sandbox: the shared words become levels, and anything else stays the runtime's own value.
// On Auto a runtime's own model or mode is refused: Auto cannot map one runtime's name onto
// another (Story 5). The exceptions are the modes in permissionAliases (#2873).
func fileLevels(runtimeID, model string, mode *string, requests, sandbox string) (levels *wire.Levels, nativeModel string, nativeMode *string, box *wire.SandboxChoice, err error) {
	auto := runtimeID == autoRuntimeID
	l := wire.Levels{}
	set := false
	if model != "" {
		if m, ok := modelLevelWords[model]; ok {
			l.Model, set = &m, true
		} else if auto {
			return nil, "", nil, nil, Invalid("`runtime: auto` takes `model: fast`, `balanced` or `smart`, not %s", model)
		} else {
			nativeModel = model
		}
	}
	if mode != nil && *mode != "" {
		if p, ok := permissionLevelWords[*mode]; ok {
			l.Permission, set = &p, true
		} else if p, ok := permissionAliases[*mode]; ok && auto {
			l.Permission, set = &p, true
		} else if auto {
			return nil, "", nil, nil, Invalid("`runtime: auto` takes `permission-mode: plan`, `ask`, `approve-for-me` or `bypass-permissions`, not %s", *mode)
		} else {
			nativeMode = mode
		}
	}
	if requests != "" {
		r, ok := requestWords[requests]
		if !ok {
			return nil, "", nil, nil, Invalid("`permission-requests:` is `request-cards` or `yes-to-all`, not %s", requests)
		}
		l.PermissionRequests, set = &r, true
	}
	if sandbox != "" {
		s, ok := sandboxWords[sandbox]
		if !ok {
			return nil, "", nil, nil, Invalid("`sandbox:` is `default`, `runtime` or `none`, not %s", sandbox)
		}
		box = &s
	}
	if set || auto {
		levels = &l
	}
	return levels, nativeModel, nativeMode, box, nil
}

// effortOptionID is the runtime's effort option, from what it last offered.
func effortOptionID(offers []wire.ConfigOption) string {
	for _, o := range offers {
		if o.Type == "select" && o.Category != nil && *o.Category == "thought_level" {
			return o.ID
		}
	}
	return ""
}
