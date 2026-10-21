package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The user scope on this machine (#1760, spec 736 US4): host/userSettings, which the
// control plane sends on channel 0 when this machine joins and when its person's settings
// or secrets change. Each part goes into the file this machine already reads:
//
//	mcpServers    ~/.agents/mcp.json's mcpServers
//	agentConfig   ~/.agents/AGENTS.md, ~/.agents/personas/<name>.md, ~/.agents/skills/<name>/SKILL.md
//	runtimes      <settings>/sandbox.json and <settings>/client-permissions.json
//	costLimits    <settings>/limits.json
//	resources     <root>/resources.json
//	secrets       ~/.agents-secrets/secrets.env, NAME=value
//
// <root>/from-control-plane.json marks what came from the control plane: the parts, the
// secrets and the agentConfig files written. A local edit to a marked part is refused; it
// is changed under You. A part the control plane no longer sends stays as it was, and is
// this machine's own again. A secret it no longer sends is taken out of secrets.env.

const userScopeFile = "from-control-plane.json"

// userScopeMark is from-control-plane.json. It never holds a secret's value.
type userScopeMark struct {
	User    string                      `json:"user"`
	At      string                      `json:"at"`
	Parts   []wire.UserSettingsPartName `json:"parts"`
	Secrets []string                    `json:"secrets"`
	// The agentConfig files written, relative to ~/.agents, so a persona or skill the
	// control plane no longer sends is taken away again.
	Files []string `json:"files,omitempty"`
}

type userScopeState struct {
	userScopeMu sync.Mutex
	userMark    *userScopeMark
}

// agentConfigName is a persona's or a skill's name, as one folder or file name.
var agentConfigName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func (d *Daemon) userScopeFile() string { return filepath.Join(d.Store.Loc.Root, userScopeFile) }

// userMarkLocked is the mark, read once.
func (d *Daemon) userMarkLocked() userScopeMark {
	if d.userMark == nil {
		var m userScopeMark
		if b, err := os.ReadFile(d.userScopeFile()); err == nil {
			json.Unmarshal(b, &m)
		}
		d.userMark = &m
	}
	return *d.userMark
}

// FromControlPlane says whether a part of the settings here is the control plane's.
func (d *Daemon) FromControlPlane(part wire.UserSettingsPartName) bool {
	d.userScopeMu.Lock()
	defer d.userScopeMu.Unlock()
	return slices.Contains(d.userMarkLocked().Parts, part)
}

// refuseUserScoped is a local edit of a part that is the control plane's.
func (d *Daemon) refuseUserScoped(part wire.UserSettingsPartName) error {
	if !d.FromControlPlane(part) {
		return nil
	}
	return &Error{Code: CodeNotSupported, Message: "This is set under You on the control plane, for every machine of yours. Change it there.",
		Data: map[string]any{"userScope": part}}
}

// guardUserScope refuses, on the methods that change a part here, a change to a part that
// is the control plane's.
func (d *Daemon) guardUserScope() {
	guarded := map[string]wire.UserSettingsPartName{
		wire.CallCostSetLimits.Name:      wire.UserSettingsPartNameCostLimits,
		wire.CallResourcesDeclare.Name:   wire.UserSettingsPartNameResources,
		wire.CallResourcesRemove.Name:    wire.UserSettingsPartNameResources,
	}
	for method, part := range guarded {
		next, ok := d.handlers[method]
		if !ok {
			continue
		}
		d.handlers[method] = func(ctx context.Context, c *Client, params json.RawMessage) (any, error) {
			if err := d.refuseUserScoped(part); err != nil {
				return nil, err
			}
			return next(ctx, c, params)
		}
	}
}

// toldUserSettings is host/userSettings.
func (d *Daemon) toldUserSettings(params json.RawMessage) {
	var u wire.HostUserSettings
	if err := json.Unmarshal(params, &u); err != nil {
		log.Printf("user settings: %v", err)
		return
	}
	if err := d.ApplyUserSettings(u); err != nil {
		log.Printf("user settings: %v", err)
	}
}

// ApplyUserSettings writes what the control plane sent. Its errors never hold a secret.
func (d *Daemon) ApplyUserSettings(u wire.HostUserSettings) error {
	d.userScopeMu.Lock()
	defer d.userScopeMu.Unlock()
	before := d.userMarkLocked()
	mark := userScopeMark{User: u.User, At: time.Now().UTC().Format(time.RFC3339), Parts: []wire.UserSettingsPartName{}, Secrets: []string{}}
	var problems []string
	note := func(part wire.UserSettingsPartName, err error) {
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: %v", part, err))
			return
		}
		mark.Parts = append(mark.Parts, part)
	}
	home := d.personalHome()
	s := u.Settings
	if partSent(s.McpServers) {
		note(wire.UserSettingsPartNameMcpServers, writeMCPServers(home, s.McpServers))
	}
	if partSent(s.AgentConfig) {
		files, err := writeAgentConfig(home, s.AgentConfig, before.Files)
		mark.Files = files
		note(wire.UserSettingsPartNameAgentConfig, err)
	} else {
		// Not the control plane's any more: what it wrote stays, as this machine's own.
		mark.Files = nil
	}
	if partSent(s.Runtimes) {
		note(wire.UserSettingsPartNameRuntimes, d.writeRuntimeChoices(s.Runtimes))
	}
	if partSent(s.CostLimits) {
		note(wire.UserSettingsPartNameCostLimits, d.writeCostLimits(s.CostLimits))
	}
	if partSent(s.Resources) {
		note(wire.UserSettingsPartNameResources, d.writeResources(s.Resources))
	}
	names, err := writeSecrets(home, u.Secrets, before.Secrets)
	if err != nil {
		problems = append(problems, "secrets: "+err.Error())
		names = before.Secrets
	}
	mark.Secrets = names
	sort.Slice(mark.Parts, func(i, j int) bool { return mark.Parts[i] < mark.Parts[j] })
	b, _ := diskjson.Marshal(mark)
	if err := store.WriteAtomically(d.userScopeFile(), b, 0o644); err != nil {
		problems = append(problems, err.Error())
	}
	d.userMark = &mark
	log.Printf("user settings from the control plane: %d parts, %d secrets", len(mark.Parts), len(mark.Secrets))
	if len(problems) > 0 {
		return errors.New(strings.Join(problems, "; "))
	}
	return nil
}

func partSent(v wire.JSONValue) bool { return len(v) > 0 && string(v) != "null" }

// writeMCPServers is mcpServers as ~/.agents/mcp.json, with the file's other keys kept.
func writeMCPServers(home string, servers wire.JSONValue) error {
	if home == "" {
		return errors.New("this machine has no personal home")
	}
	var check map[string]json.RawMessage
	if json.Unmarshal(servers, &check) != nil {
		return errors.New("not an object")
	}
	path := filepath.Join(home, ".agents", "mcp.json")
	file := map[string]json.RawMessage{}
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, &file)
	}
	file["mcpServers"] = json.RawMessage(servers)
	b, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	return store.WriteAtomically(path, append(b, '\n'), 0o644)
}

// writeAgentConfig writes the instructions, personas and skills, and takes away the files
// it wrote before that are no longer sent. It gives the files it wrote.
func writeAgentConfig(home string, raw wire.JSONValue, wroteBefore []string) ([]string, error) {
	if home == "" {
		return wroteBefore, errors.New("this machine has no personal home")
	}
	var config wire.UserAgentConfig
	if err := json.Unmarshal(raw, &config); err != nil {
		return wroteBefore, errors.New("not an agent configuration")
	}
	files := map[string]string{}
	if config.Instructions != nil {
		files["AGENTS.md"] = *config.Instructions
	}
	for name, text := range config.Personas {
		if !agentConfigName.MatchString(name) || strings.Contains(name, "..") {
			return wroteBefore, fmt.Errorf("%q is not a persona's name", name)
		}
		files[filepath.Join("personas", name+".md")] = text
	}
	for name, text := range config.Skills {
		if !agentConfigName.MatchString(name) || strings.Contains(name, "..") {
			return wroteBefore, fmt.Errorf("%q is not a skill's name", name)
		}
		files[filepath.Join("skills", name, "SKILL.md")] = text
	}
	base := filepath.Join(home, ".agents")
	var wrote []string
	for rel, text := range files {
		path := filepath.Join(base, rel)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			return wroteBefore, err
		}
		if err := store.WriteAtomically(path, []byte(text), 0o644); err != nil {
			return wroteBefore, err
		}
		wrote = append(wrote, rel)
	}
	for _, rel := range wroteBefore {
		if _, still := files[rel]; still || !safeRelative(rel) {
			continue
		}
		os.Remove(filepath.Join(base, rel))
		if strings.HasPrefix(rel, "skills"+string(filepath.Separator)) {
			os.Remove(filepath.Dir(filepath.Join(base, rel))) // only when it is empty
		}
	}
	sort.Strings(wrote)
	return wrote, nil
}

// safeRelative is a path the mark may name: AGENTS.md, or inside personas/ or skills/.
func safeRelative(rel string) bool {
	clean := filepath.Clean(rel)
	if clean != rel || filepath.IsAbs(rel) || strings.Contains(rel, "..") {
		return false
	}
	return rel == "AGENTS.md" || strings.HasPrefix(rel, "personas"+string(filepath.Separator)) ||
		strings.HasPrefix(rel, "skills"+string(filepath.Separator))
}

// userRuntimes is the runtimes part: each runtime's choices that follow the person.
// Sign-ins stay on each machine.
type userRuntimes struct {
	Sandbox           *wire.SandboxSettings          `json:"sandbox,omitempty"`
	ClientPermissions *wire.ClientPermissionSettings `json:"clientPermissions,omitempty"`
}

func (d *Daemon) writeRuntimeChoices(raw wire.JSONValue) error {
	var r userRuntimes
	if err := json.Unmarshal(raw, &r); err != nil {
		return errors.New("not runtime choices")
	}
	if err := os.MkdirAll(d.SettingsDir, 0o755); err != nil {
		return err
	}
	if r.Sandbox != nil {
		b, _ := json.Marshal(r.Sandbox)
		if err := store.WriteAtomically(filepath.Join(d.SettingsDir, "sandbox.json"), b, 0o644); err != nil {
			return err
		}
	}
	if r.ClientPermissions != nil {
		b, _ := json.Marshal(r.ClientPermissions)
		if err := store.WriteAtomically(filepath.Join(d.SettingsDir, "client-permissions.json"), b, 0o644); err != nil {
			return err
		}
	}
	return nil
}

// writeCostLimits sets every limit as the part has it: one it leaves out is no limit.
func (d *Daemon) writeCostLimits(raw wire.JSONValue) error {
	var given map[string]json.RawMessage
	if err := json.Unmarshal(raw, &given); err != nil {
		return errors.New("not cost limits")
	}
	whole := map[string]json.RawMessage{}
	for _, k := range []string{"perAgent", "daily", "perAgentTokens", "dailyTokens"} {
		if v, ok := given[k]; ok {
			whole[k] = v
		} else {
			whole[k] = json.RawMessage("null")
		}
	}
	b, _ := json.Marshal(whole)
	_, err := d.setLimits(b)
	return err
}

// writeResources declares the part's resources, and only those.
func (d *Daemon) writeResources(raw wire.JSONValue) error {
	var list []wire.DeclaredResource
	if err := json.Unmarshal(raw, &list); err != nil {
		return errors.New("not a list of resources")
	}
	var clean []wire.DeclaredResource
	for _, r := range list {
		name, ok := resourceName(string(r.Name))
		if !ok || r.Holders < 1 {
			continue
		}
		r.Name = name
		clean = append(clean, r)
	}
	sort.Slice(clean, func(i, j int) bool { return clean[i].Name < clean[j].Name })
	return d.declareAll(clean)
}

// writeSecrets sets each secret in secrets.env, and takes out the ones the control plane
// set before and no longer sends. A secret the person set here by hand, under a name the
// control plane never sent, is left alone. It gives the names now from the control plane.
func writeSecrets(home string, secrets []wire.UserSecret, before []string) ([]string, error) {
	if len(secrets) == 0 && len(before) == 0 {
		return []string{}, nil
	}
	if home == "" {
		return nil, errors.New("this machine has no personal home")
	}
	path := skillcatalog.SecretsPath(home)
	file, err := skillcatalog.LoadSecretsForChange(path)
	if err != nil {
		return nil, err
	}
	names := []string{}
	sent := map[string]bool{}
	for _, s := range secrets {
		name := string(s.Name)
		if !secretNameHere.MatchString(name) || strings.ContainsAny(s.Value, "\n\r\x00") {
			continue
		}
		file.Set(name, s.Value)
		sent[name] = true
		names = append(names, name)
	}
	for _, name := range before {
		if !sent[name] {
			file.Remove(name)
		}
	}
	if err := file.Save(path); err != nil {
		return nil, err
	}
	sort.Strings(names)
	return names, nil
}

var secretNameHere = regexp.MustCompile(`^[A-Z_][A-Z0-9_]{0,63}$`)

// declareAll is resources.json as list, and each one's rules, as resources/declare does.
func (d *Daemon) declareAll(list []wire.DeclaredResource) error {
	d.leaseMu.Lock()
	loaded := d.loadLeases()
	err := d.saveDeclared(list)
	var events []leaseEvent
	if err == nil {
		for _, r := range list {
			events = append(events, d.setRules(r.Name, rulesOf(r))...)
		}
	}
	d.leasesChanged()
	d.leaseMu.Unlock()
	d.settle(append(loaded, events...))
	return err
}
