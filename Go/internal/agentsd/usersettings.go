package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

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
// <root>/user-settings-sync.json stores sync metadata: secret names and the agentConfig
// files written. A machine does not send its own agent configuration files to the person's
// other machines, nor write the ones a control plane sends (agentConfigFiles), so one
// machine cannot change what runs on the others.

const userSettingsSyncFile = "user-settings-sync.json"

// userSettingsSyncState never holds a secret's value.
type userSettingsSyncState struct {
	User    string   `json:"user,omitempty"`
	Secrets []string `json:"secrets"`
	// The agentConfig files written, relative to ~/.agents, so a persona or skill the
	// control plane no longer sends is taken away again.
	Files []string `json:"files,omitempty"`
}

type userScopeState struct {
	userScopeMu sync.Mutex
	userMark    *userSettingsSyncState
}

// agentConfigName is a persona's or a skill's name, as one folder or file name.
var agentConfigName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func (d *Daemon) userSettingsSyncPath() string {
	return filepath.Join(d.Store.Loc.Root, userSettingsSyncFile)
}

// userMarkLocked is the mark, read once.
func (d *Daemon) userMarkLocked() userSettingsSyncState {
	if d.userMark == nil {
		var m userSettingsSyncState
		b, err := os.ReadFile(d.userSettingsSyncPath())
		if err != nil {
			// Read the old metadata once, so its secret names and files survive the upgrade.
			b, _ = os.ReadFile(filepath.Join(d.Store.Loc.Root, "from-control-plane.json"))
		}
		if len(b) > 0 {
			json.Unmarshal(b, &m)
		}
		d.userMark = &m
	}
	return *d.userMark
}

// toldUserSettings is host/userSettings.
func (d *Daemon) toldUserSettings(params json.RawMessage) {
	var u wire.MachineUserSettings
	if err := json.Unmarshal(params, &u); err != nil {
		log.Printf("user settings: %v", err)
		return
	}
	if err := d.ApplyUserSettings(u); err != nil {
		log.Printf("user settings: %v", err)
	}
}

// ApplyUserSettings writes what the control plane sent. Its errors never hold a secret.
func (d *Daemon) ApplyUserSettings(u wire.MachineUserSettings) error {
	d.userScopeMu.Lock()
	defer d.userScopeMu.Unlock()
	before := d.userMarkLocked()
	mark := userSettingsSyncState{User: u.User, Secrets: []string{}}
	var problems []string
	note := func(part wire.UserSettingsPartName, err error) {
		if err != nil {
			problems = append(problems, fmt.Sprintf("%s: %v", part, err))
		}
	}
	home := d.personalHome()
	s := u.Settings
	if partSent(s.McpServers) {
		note(wire.UserSettingsPartNameMcpServers, writeMCPServers(home, s.McpServers))
	}
	if partSent(s.AgentConfig) {
		files, err := writeAgentConfig(home, s.AgentConfig, agentConfigWrote(before.Files))
		mark.Files = files
		note(wire.UserSettingsPartNameAgentConfig, err)
	} else {
		// Not the control plane's any more: what it wrote stays, as this machine's own.
		mark.Files = nil
	}
	if s.AgentConfigFiles != nil && len(s.AgentConfigFiles.Files) > 0 {
		log.Printf("user settings: %d agent configuration files from other machines were not written", len(s.AgentConfigFiles.Files))
	}
	if partSent(s.Runtimes) {
		note(wire.UserSettingsPartNameRuntimes, d.writeRuntimeChoices(s.Runtimes))
	}
	if partSent(s.CostLimits) {
		note(wire.UserSettingsPartNameCostLimits, d.writeCostLimits(s.CostLimits))
	}
	names, err := writeSecrets(home, u.Secrets, before.Secrets)
	if err != nil {
		problems = append(problems, "secrets: "+err.Error())
		names = before.Secrets
	}
	mark.Secrets = names
	b, _ := diskjson.Marshal(mark)
	if err := store.WriteAtomically(d.userSettingsSyncPath(), b, 0o644); err != nil {
		problems = append(problems, err.Error())
	} else {
		_ = os.Remove(filepath.Join(d.Store.Loc.Root, "from-control-plane.json"))
	}
	d.userMark = &mark
	log.Printf("user settings synced from the control plane: %d secrets", len(mark.Secrets))
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
	path, err := safeConfigPath(filepath.Join(home, ".agents"), "mcp.json", true)
	if err != nil {
		return err
	}
	file := map[string]json.RawMessage{}
	if b, err := os.ReadFile(path); err == nil {
		json.Unmarshal(b, &file)
	}
	file["mcpServers"] = json.RawMessage(servers)
	b, err := json.MarshalIndent(file, "", "  ")
	if err != nil {
		return err
	}
	return writeIfChanged(path, append(b, '\n'))
}

// writeIfChanged writes a file only when its bytes on disk differ, so a delivery that
// changes one part does not write and fsync every file of the others again (#2729).
func writeIfChanged(path string, b []byte) error {
	if on, err := os.ReadFile(path); err == nil && bytes.Equal(on, b) {
		return nil
	}
	return store.WriteAtomically(path, b, 0o644)
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
		if err := writeIfChanged(path, []byte(text)); err != nil {
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

// agentConfigWrote is what the agentConfig part can have written of the files a mark names.
// A mark from before agentConfigFiles were refused also names files other machines sent
// (mcp.json, plugins and any file of a skill); those stay, as this machine's own.
func agentConfigWrote(files []string) []string {
	var out []string
	for _, rel := range files {
		parts := strings.Split(filepath.ToSlash(rel), "/")
		if rel == "AGENTS.md" || len(parts) == 2 && parts[0] == "personas" && strings.HasSuffix(parts[1], ".md") ||
			len(parts) == 3 && parts[0] == "skills" && parts[2] == "SKILL.md" {
			out = append(out, rel)
		}
	}
	return out
}

// safeRelative is a path the mark may name under ~/.agents.
func safeRelative(rel string) bool {
	clean := filepath.Clean(rel)
	if clean != rel || filepath.IsAbs(rel) || strings.Contains(rel, "..") {
		return false
	}
	return rel == "AGENTS.md" || rel == "mcp.json" || strings.HasPrefix(rel, "personas"+string(filepath.Separator)) ||
		strings.HasPrefix(rel, "skills"+string(filepath.Separator)) || strings.HasPrefix(rel, "plugins"+string(filepath.Separator))
}

func safeAgentConfigPath(rel string) bool {
	if !safeRelative(rel) {
		return false
	}
	if rel == "mcp.json" {
		return true
	}
	parts := strings.Split(filepath.ToSlash(rel), "/")
	if len(parts) == 1 {
		return parts[0] == "AGENTS.md"
	}
	for _, part := range parts {
		switch strings.ToLower(part) {
		case "node_modules", ".git", ".cache", "cache", "caches", "dist", "build", "target", "vendor", "__pycache__":
			return false
		}
	}
	if len(parts) < 2 || !agentConfigName.MatchString(parts[1]) || strings.Contains(parts[1], "..") {
		return false
	}
	if parts[0] == "personas" {
		return len(parts) == 2 && strings.HasSuffix(parts[1], ".md")
	}
	return len(parts) >= 3
}

func safeConfigPath(base, rel string, createParents bool) (string, error) {
	if !safeAgentConfigPath(rel) {
		return "", errors.New("invalid agent configuration path")
	}
	if createParents {
		if err := os.MkdirAll(base, 0o755); err != nil {
			return "", err
		}
	}
	if info, err := os.Lstat(base); err == nil {
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return "", errors.New("~/.agents is not a regular folder")
		}
	} else if !errors.Is(err, os.ErrNotExist) || createParents {
		return "", err
	}
	parts := strings.Split(filepath.FromSlash(rel), string(filepath.Separator))
	current := base
	for _, part := range parts[:len(parts)-1] {
		current = filepath.Join(current, part)
		if createParents {
			if err := os.Mkdir(current, 0o755); err != nil && !errors.Is(err, os.ErrExist) {
				return "", err
			}
		}
		info, err := os.Lstat(current)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) && !createParents {
				return filepath.Join(base, filepath.FromSlash(rel)), nil
			}
			return "", err
		}
		if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
			return "", errors.New("agent configuration path crosses a link or file")
		}
	}
	target := filepath.Join(current, parts[len(parts)-1])
	if info, err := os.Lstat(target); err == nil && info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("agent configuration file is a link")
	} else if err != nil && !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	return target, nil
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

// registerUserScope is settings/userPart: a part as this machine has it, for Use This
// Mac's under You.
func (d *Daemon) registerUserScope() {
	On(d, wire.CallSettingsUserPart, func(ctx context.Context, c *Client, r wire.UserPartRequest) (wire.UserPartHere, error) {
		return d.userPartHere(r.Part)
	})
}

func (d *Daemon) userPartHere(part wire.UserSettingsPartName) (wire.UserPartHere, error) {
	out := wire.UserPartHere{Part: part}
	home := d.personalHome()
	switch part {
	case wire.UserSettingsPartNameMcpServers:
		servers := json.RawMessage(`{}`)
		if home != "" {
			var file struct {
				MCPServers json.RawMessage `json:"mcpServers"`
			}
			if b, err := os.ReadFile(filepath.Join(home, ".agents", "mcp.json")); err == nil && json.Unmarshal(b, &file) == nil && len(file.MCPServers) > 0 {
				servers = file.MCPServers
			}
		}
		if err := tokensInClear(servers); err != nil {
			return out, err
		}
		out.Value = servers
	case wire.UserSettingsPartNameAgentConfig:
		config, left := agentConfigHere(home)
		out.Value, out.LeftOut = asJSON(config), left
	case wire.UserSettingsPartNameRuntimes:
		out.Value = asJSON(userRuntimes{Sandbox: new(d.sandboxSettings()), ClientPermissions: new(d.clientPermissions())})
	case wire.UserSettingsPartNameCostLimits:
		out.Value = asJSON(d.costState().Limits)
	default:
		return out, Invalid("There is no part called %q.", part)
	}
	return out, nil
}

// secretLooking is a header or variable whose value is a secret by its name.
var secretLooking = regexp.MustCompile(`(?i)(token|secret|key|password|passwd|auth|bearer|cookie|credential)`)

// tokensInClear refuses servers with a secret written in clear in an env or a header: in
// the user settings it would be kept unsealed. Its words name the server and the key,
// never the value.
func tokensInClear(servers json.RawMessage) error {
	var list map[string]struct {
		Env     map[string]string `json:"env"`
		Headers map[string]string `json:"headers"`
	}
	if err := json.Unmarshal(servers, &list); err != nil {
		return Invalid("mcp.json's mcpServers cannot be read.")
	}
	names := make([]string, 0, len(list))
	for name := range list {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		s := list[name]
		for _, kv := range []map[string]string{s.Env, s.Headers} {
			for k, v := range kv {
				if v == "" || secretRef.MatchString(v) {
					continue
				}
				if secretLooking.MatchString(k) || strings.HasPrefix(strings.ToLower(v), "bearer ") {
					return Invalid("The server %s has %s written in clear. Put it in a secret under You, write ${NAME} in its place, and try again.", name, k)
				}
			}
		}
	}
	return nil
}

// agentConfigHere is ~/.agents' instructions, personas and one-file skills. A skill with
// other files beside its SKILL.md is left out, by name: the user settings keep text only.
func agentConfigHere(home string) (wire.UserAgentConfig, []string) {
	var config wire.UserAgentConfig
	var left []string
	if home == "" {
		return config, nil
	}
	base := filepath.Join(home, ".agents")
	if b, err := os.ReadFile(filepath.Join(base, "AGENTS.md")); err == nil {
		text := string(b)
		config.Instructions = &text
	}
	if entries, err := os.ReadDir(filepath.Join(base, "personas")); err == nil {
		for _, e := range entries {
			name, ok := strings.CutSuffix(e.Name(), ".md")
			if !ok || !e.Type().IsRegular() || !agentConfigName.MatchString(name) {
				continue
			}
			if b, err := os.ReadFile(filepath.Join(base, "personas", e.Name())); err == nil {
				if config.Personas == nil {
					config.Personas = map[string]string{}
				}
				config.Personas[name] = string(b)
			}
		}
	}
	if entries, err := os.ReadDir(filepath.Join(base, "skills")); err == nil {
		for _, e := range entries {
			if !e.IsDir() || !agentConfigName.MatchString(e.Name()) {
				continue
			}
			files, _ := os.ReadDir(filepath.Join(base, "skills", e.Name()))
			if len(files) != 1 || files[0].Name() != "SKILL.md" || !files[0].Type().IsRegular() {
				left = append(left, e.Name())
				continue
			}
			if b, err := os.ReadFile(filepath.Join(base, "skills", e.Name(), "SKILL.md")); err == nil {
				if config.Skills == nil {
					config.Skills = map[string]string{}
				}
				config.Skills[e.Name()] = string(b)
			}
		}
	}
	sort.Strings(left)
	return config, left
}

func asJSON(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}
