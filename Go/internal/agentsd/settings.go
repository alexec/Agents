package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/agentsd/yamlnode"
	"github.com/alexec/agents/Go/wire"
)

// What the window reads of the person's settings on this host, as the Swift host keeps
// them: display preferences (display.json) and each runtime's last mode (modes.json) in
// the settings folder, each new agent's options as last seen (option-cache.json, in the
// cache), and the personas in a folder's .agents/personas.

type settingsState struct {
	settingsMu  sync.Mutex
	seenDisplay map[string]wire.JSONValue
}

func (d *Daemon) displayFile() string { return filepath.Join(d.SettingsDir, "display.json") }
func (d *Daemon) modesFile() string   { return filepath.Join(d.SettingsDir, "modes.json") }

// readJSONMap reads a map of JSON values, {} when it is missing; a file that will not read
// is set aside as <name>.corrupt-<time>, as DisplayPreferencesStore.load does.
func readJSONMap(path string) map[string]wire.JSONValue {
	b, err := os.ReadFile(path)
	if err != nil {
		return map[string]wire.JSONValue{}
	}
	var m map[string]wire.JSONValue
	if json.Unmarshal(b, &m) != nil || m == nil {
		os.Rename(path, fmt.Sprintf("%s.corrupt-%d", path, time.Now().Unix()))
		store.TrimSetAsides(path)
		return map[string]wire.JSONValue{}
	}
	return m
}

// storeJSON is StoreCoding.encoder's: sorted keys, slashes as they are, not pretty.
func storeJSON(v any) ([]byte, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return diskjson.Compact(b)
}

func (d *Daemon) preferences() map[string]wire.JSONValue {
	d.settingsMu.Lock()
	defer d.settingsMu.Unlock()
	return readJSONMap(d.displayFile())
}

// setPreferences merges: each key takes its new value, and null takes the key away.
func (d *Daemon) setPreferences(change map[string]wire.JSONValue) (map[string]wire.JSONValue, error) {
	d.settingsMu.Lock()
	m := readJSONMap(d.displayFile())
	for k, v := range change {
		if len(v) == 0 || string(v) == "null" {
			delete(m, k)
		} else {
			m[k] = v
		}
	}
	b, err := storeJSON(m)
	if err == nil {
		os.MkdirAll(d.SettingsDir, 0o700)
		err = store.WriteAtomically(d.displayFile(), b, 0o600)
	}
	tell := !reflect.DeepEqual(normalized(m), normalized(d.seenDisplay))
	d.seenDisplay = m
	d.settingsMu.Unlock()
	if err != nil {
		return nil, &Error{Code: wire.FailureCouldNotSave, Message: "The display settings could not be saved: " + err.Error()}
	}
	if tell {
		Broadcast(d, wire.NotifyPreferencesChanged, m)
	}
	return m, nil
}

func normalized(m map[string]wire.JSONValue) map[string]any {
	out := map[string]any{}
	for k, v := range m {
		out[k] = value(v)
	}
	return out
}

// modes is ModeStore.remembered: each runtime's mode, from {"mode", "chosenAt"} entries.
func (d *Daemon) modes() map[string]wire.JSONValue {
	out := map[string]wire.JSONValue{}
	for runtime, raw := range readJSONMap(d.modesFile()) {
		var e struct {
			Mode wire.JSONValue `json:"mode"`
		}
		if json.Unmarshal(raw, &e) == nil && len(e.Mode) > 0 {
			out[runtime] = e.Mode
		}
	}
	return out
}

// modeOption is ModeMemory.modeOption: the first select in the mode category, else the
// one called mode.
func modeOption(options []wire.ConfigOption) *wire.ConfigOption {
	for _, o := range options {
		if o.Type == "select" && o.Category != nil && *o.Category == "mode" {
			return &o
		}
	}
	for _, o := range options {
		if o.ID == "mode" {
			return &o
		}
	}
	return nil
}

// rememberMode keeps the runtime's mode when the option set is its mode, and says
// modes/changed (DaemonCore.rememberMode).
func (d *Daemon) rememberMode(runtimeID, optionID string, v wire.JSONValue, options []wire.ConfigOption) {
	mo := modeOption(options)
	if mo == nil || mo.ID != optionID {
		return
	}
	d.settingsMu.Lock()
	all := readJSONMap(d.modesFile())
	var old struct {
		Mode wire.JSONValue `json:"mode"`
	}
	json.Unmarshal(all[runtimeID], &old)
	if reflect.DeepEqual(value(old.Mode), value(v)) {
		d.settingsMu.Unlock()
		return
	}
	entry, _ := json.Marshal(map[string]any{"mode": v, "chosenAt": diskjson.FormatDate(now())})
	all[runtimeID] = entry
	b, err := storeJSON(all)
	if err == nil {
		os.MkdirAll(d.SettingsDir, 0o700)
		err = store.WriteAtomically(d.modesFile(), b, 0o600)
	}
	d.settingsMu.Unlock()
	if err != nil {
		return
	}
	Broadcast(d, wire.NotifyModesChanged, d.modes())
}

// rememberedOptions is OptionCache: the options a runtime last showed for a folder.
func (d *Daemon) rememberedOptions(r wire.RememberedOptionsRequest) []wire.ConfigOption {
	b, err := os.ReadFile(filepath.Join(d.Store.Loc.Cache, "option-cache.json"))
	if err != nil {
		return []wire.ConfigOption{}
	}
	var cache map[string]struct {
		Options  []wire.ConfigOption `json:"options"`
		Commands []json.RawMessage   `json:"commands"`
	}
	if json.Unmarshal(b, &cache) != nil {
		return []wire.ConfigOption{}
	}
	e, ok := cache[r.RuntimeID+"\t"+filepath.Clean(store.FolderPath(r.Cwd))+"\t"]
	if !ok || (len(e.Options) == 0 && len(e.Commands) == 0) || e.Options == nil {
		return []wire.ConfigOption{}
	}
	return e.Options
}

// MARK: personas (PersonaFile)

func personas(folder string, home string) []wire.Persona {
	byID := map[string]wire.Persona{}
	for _, p := range readPersonas(home, "personal") {
		byID[p.ID] = p
	}
	for _, p := range readPersonas(folder, "folder") {
		byID[p.ID] = p
	}
	out := []wire.Persona{}
	for _, p := range byID {
		out = append(out, p)
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name) })
	return out
}

func readPersonas(base, origin string) []wire.Persona {
	if base == "" {
		return nil
	}
	folder := filepath.Join(base, ".agents", "personas")
	entries, _ := os.ReadDir(folder)
	var out []wire.Persona
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") || !strings.HasSuffix(name, ".md") {
			continue
		}
		id := strings.TrimSuffix(name, ".md")
		b, ok := regularFileBytes(filepath.Join(folder, name))
		if !ok {
			problem := "This file could not be read"
			out = append(out, newPersona(id, origin, &problem))
			continue
		}
		out = append(out, parsePersona(string(b), id, origin))
	}
	return out
}

// regularFileBytes is WorkflowFile.bytes: a regular file with one link, never followed.
func regularFileBytes(path string) ([]byte, bool) {
	fi, err := os.Lstat(path)
	if err != nil || !fi.Mode().IsRegular() || links(fi) != 1 {
		return nil, false
	}
	b, err := os.ReadFile(path)
	return b, err == nil
}

func newPersona(id, origin string, problem *string) wire.Persona {
	return wire.Persona{ID: id, Name: id, Origin: wire.PersonaOrigin(origin), Problem: problem,
		Settings: wire.WorkflowSettings{Options: map[string]string{}, Labels: []string{}}}
}

// parsePersona is PersonaFile.parse: front matter with name, description and the
// workflow settings, the rest the prompt.
func parsePersona(text, id, origin string) wire.Persona {
	p := newPersona(id, origin, nil)
	lines := strings.Split(text, "\n")
	if strings.TrimSpace(lines[0]) != "---" {
		return p
	}
	closing := -1
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			closing = i
			break
		}
	}
	if closing < 0 {
		problem := "The metadata block is never closed"
		p.Problem = &problem
		return p
	}
	mapping, err := yamlnode.MappingFrom(lines[1:closing])
	if err == nil {
		var s wire.WorkflowSettings
		if s, err = workflowSettings(mapping); err == nil {
			p.Settings = s
			if n, ok := mapping["name"].Text(); ok && n != "" {
				p.Name = n
			}
			if d, ok := mapping["description"].Text(); ok && d != "" {
				p.Description = &d
			}
			return p
		}
	}
	problem := "The metadata could not be read"
	if f, ok := err.(*yamlnode.Failure); ok {
		problem = f.Message
	}
	p.Problem = &problem
	return p
}

// workflowSettings is WorkflowFile.settings(from:).
func workflowSettings(m map[string]yamlnode.Node) (wire.WorkflowSettings, error) {
	s := wire.WorkflowSettings{Options: map[string]string{}, Labels: []string{}}
	setting := func(key string) (*string, error) {
		n, ok := m[key]
		if !ok {
			return nil, nil
		}
		v, ok := n.Text()
		if !ok {
			return nil, &yamlnode.Failure{Message: "`" + key + ":` must be a single value"}
		}
		if v == "" {
			return nil, nil
		}
		return &v, nil
	}
	var err error
	for key, to := range map[string]**string{"permission-mode": &s.PermissionMode, "runtime": &s.RuntimeID,
		"model": &s.Model, "effort": &s.Effort, "permission-requests": &s.PermissionRequests, "sandbox": &s.Sandbox} {
		if *to, err = setting(key); err != nil {
			return s, err
		}
	}
	// The shared words (#2658): `runtime: auto` takes only them, and the two keys that
	// have no runtime's own values take only theirs.
	runtimeID, model, requests, box := "", "", "", ""
	for to, from := range map[*string]*string{&runtimeID: s.RuntimeID, &model: s.Model, &requests: s.PermissionRequests, &box: s.Sandbox} {
		if from != nil {
			*to = *from
		}
	}
	if _, _, _, _, err := fileLevels(runtimeID, model, s.PermissionMode, requests, box); err != nil {
		return s, &yamlnode.Failure{Message: err.(*Error).Message}
	}
	if n, ok := m["options"]; ok {
		if v, isText := n.Text(); !(isText && v == "") {
			if !n.IsMapping() {
				return s, &yamlnode.Failure{Message: "`options:` must be a list of keys, like `fast: true`"}
			}
			for id, value := range n.Mapping {
				text, ok := value.Text()
				if !ok {
					return s, &yamlnode.Failure{Message: "`" + id + ":` under `options:` must be a single value"}
				}
				if text != "" {
					s.Options[id] = text
				}
			}
		}
	}
	if n, ok := m["labels"]; ok {
		values, ok := n.Values()
		if !ok {
			return s, &yamlnode.Failure{Message: "`labels:` must be a list of names"}
		}
		labels, err := changeLabels(nil, values, nil, nil)
		if err != nil {
			return s, &yamlnode.Failure{Message: "`labels:` " + err.(*Error).Message}
		}
		for _, l := range labels {
			s.Labels = append(s.Labels, l.Value)
		}
	}
	return s, nil
}

func (d *Daemon) registerSettings() {
	On(d, wire.CallPreferencesGet, func(ctx context.Context, c *Client, _ wire.Empty) (map[string]wire.JSONValue, error) {
		return d.preferences(), nil
	})
	On(d, wire.CallPreferencesSet, func(ctx context.Context, c *Client, r map[string]wire.JSONValue) (map[string]wire.JSONValue, error) {
		m, err := d.setPreferences(r)
		if err == nil {
			d.noticeLimitsChanged(r)
		}
		return m, err
	})
	On(d, wire.CallModesRemembered, func(ctx context.Context, c *Client, _ wire.Empty) (map[string]wire.JSONValue, error) {
		return d.modes(), nil
	})
	On(d, wire.CallOptionsRemembered, func(ctx context.Context, c *Client, r wire.RememberedOptionsRequest) ([]wire.ConfigOption, error) {
		return d.rememberedOptions(r), nil
	})
	On(d, wire.CallPersonasList, func(ctx context.Context, c *Client, r wire.PersonasListRequest) ([]wire.Persona, error) {
		return personas(store.FolderPath(r.Folder), personaHome()), nil
	})
	On(d, wire.CallPersonasFiles, func(ctx context.Context, c *Client, r wire.PersonasFilesRequest) (wire.PersonaFilesAnswer, error) {
		base, err := personaFilesBase(r.Folder, r.Origin)
		if err != nil {
			return nil, err
		}
		return listPersonaFiles(base, r.Origin)
	})
	On(d, wire.CallPersonasSave, func(ctx context.Context, c *Client, r wire.PersonaFileSaveRequest) (wire.Empty, error) {
		base, err := personaFilesBase(r.Folder, r.Origin)
		if err != nil {
			return wire.Empty{}, err
		}
		return wire.Empty{}, savePersonaFile(base, r)
	})
}

func personaFilesBase(folder *wire.URL, origin wire.PersonaOrigin) (string, error) {
	var base string
	switch origin {
	case wire.PersonaOriginPersonal:
		base = personaHome()
	case wire.PersonaOriginFolder:
		if folder == nil {
			return "", Invalid("Choose a folder for folder personas.")
		}
		base = store.FolderPath(*folder)
		root, err := store.Resolve(base)
		if err != nil {
			return "", Invalid("That folder is not available.")
		}
		if !inside(root, resolved(filepath.Join(base, ".agents", "personas"))) {
			return "", Invalid("The folder's persona folder has to stay inside the folder.")
		}
	default:
		return "", Invalid("Choose personal or folder personas.")
	}
	if base == "" {
		return "", Invalid("Personal personas are not available on this host.")
	}
	return base, nil
}

func listPersonaFiles(base string, origin wire.PersonaOrigin) (wire.PersonaFilesAnswer, error) {
	folder := filepath.Join(base, ".agents", "personas")
	entries, err := os.ReadDir(folder)
	if err != nil && !os.IsNotExist(err) {
		return nil, fileError(CodeFileNotReadable, "Persona files can't be opened.")
	}
	out := wire.PersonaFilesAnswer{}
	for _, entry := range entries {
		name := entry.Name()
		if strings.HasPrefix(name, ".") || !strings.HasSuffix(name, ".md") {
			continue
		}
		id := strings.TrimSuffix(name, ".md")
		bytes, ok := regularFileBytes(filepath.Join(folder, name))
		if ok {
			out = append(out, wire.PersonaFile{ID: id, Origin: origin, Content: string(bytes)})
		}
	}
	sort.Slice(out, func(i, j int) bool { return strings.ToLower(out[i].ID) < strings.ToLower(out[j].ID) })
	return out, nil
}

func savePersonaFile(base string, r wire.PersonaFileSaveRequest) error {
	if r.ID == "" || r.ID == "." || r.ID == ".." || strings.HasPrefix(r.ID, ".") ||
		strings.HasSuffix(r.ID, ".md") || filepath.Base(r.ID) != r.ID || strings.ContainsAny(r.ID, `/\\`) {
		return Invalid("Use a persona name without a folder.")
	}
	if len(r.Content) > 256<<10 {
		return Invalid("A persona file has to be smaller than 256 KB.")
	}
	folder := filepath.Join(base, ".agents", "personas")
	path := filepath.Join(folder, r.ID+".md")
	if r.Delete != nil && *r.Delete {
		info, err := os.Lstat(path)
		if err != nil {
			if os.IsNotExist(err) {
				return fileError(CodeFileGone, r.ID+".md is gone.")
			}
			return fileError(CodeFileNotReadable, r.ID+".md can't be opened.")
		}
		if !info.Mode().IsRegular() || links(info) != 1 {
			return Invalid("That persona file can't be safely removed.")
		}
		if err := os.Remove(path); err != nil {
			return fileError(CodeFileNotReadable, r.ID+".md can't be removed.")
		}
		return nil
	}
	if err := unreadableFrontMatter("personas", r.ID+".md", r.Content); err != nil {
		return err
	}
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return fileError(CodeFileNotReadable, "The persona folder can't be created.")
	}
	if root, err := store.Resolve(base); err != nil || !inside(root, resolved(folder)) {
		return Invalid("The folder's persona folder has to stay inside the folder.")
	}
	info, err := os.Lstat(path)
	if err == nil && (!info.Mode().IsRegular() || links(info) != 1) {
		return Invalid("That persona file can't be safely replaced.")
	}
	if err != nil && !os.IsNotExist(err) {
		return fileError(CodeFileNotReadable, r.ID+".md can't be opened.")
	}
	if err := store.WriteAtomically(path, []byte(r.Content), 0o644); err != nil {
		return fileError(CodeFileNotReadable, r.ID+".md can't be saved.")
	}
	return nil
}

// personaHome is the folder whose .agents/personas are the person's own.
func personaHome() string { return os.Getenv("AGENTS_PERSONAL_HOME") }
