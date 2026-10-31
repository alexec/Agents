package providers

import (
	"encoding/json"
	"fmt"
	"net/url"
	"reflect"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// Provider kinds, as ProviderRecord.Kind says them.
const (
	// The command provider Agents ships (workspace-commands).
	KindCommands = "commands"
	// An MCP server the control plane runs.
	KindStdio = "stdio"
	// An MCP server at an address.
	KindHTTP = "http"
)

func knownKind(kind string) bool {
	return kind == KindCommands || kind == KindStdio || kind == KindHTTP
}

// ProvidersPrefix is WorkspaceProviders.prefix: where provider records are kept.
const ProvidersPrefix = "v1/providers/"

// ProviderKey is WorkspaceProviders.key.
func ProviderKey(id string) string { return ProvidersPrefix + id + ".json" }

// ProviderRecord is ProviderRecord (v1/providers/<id>.json): never its secrets' values,
// which stay in the control plane's own home (research R3).
type ProviderRecord struct {
	ID      string
	Name    string
	Kind    string
	Command *string
	Args    []string
	URL     *string
	// Values may hold ${SECRET}, filled in from the secrets when the server is reached.
	Headers map[string]string
	// The command provider's configuration.
	Commands    any
	SecretNames []string
	// For a server whose tools do not follow the contract.
	Map any
	// Which optional contract tools it has: options, create, delete.
	Capabilities []string
	Contract     int
	Rev          int
	Forgotten    *bool
	// Set when the map or commands were kept as an agent wrote them (#858).
	WrittenBy *WrittenBy
	// The group whose users may see it and start machines from it (#1761, FR-028); nil
	// for the admins' alone, as every provider made before groups is.
	Group *string
	// What a later build wrote that this one does not know, written back as it was.
	Extra records.Extra
}

// WrittenBy is ProviderRecord.WrittenBy.
type WrittenBy struct {
	RuntimeID string        `json:"runtimeID"`
	At        records.Stamp `json:"at"`
}

type providerJSON struct {
	ID           string            `json:"id"`
	Name         string            `json:"name"`
	Kind         string            `json:"kind"`
	Command      *string           `json:"command,omitempty"`
	Args         []string          `json:"args,omitempty"`
	URL          *string           `json:"url,omitempty"`
	Headers      map[string]string `json:"headers,omitempty"`
	Commands     any               `json:"commands,omitempty"`
	SecretNames  []string          `json:"secretNames"`
	Map          any               `json:"map,omitempty"`
	Capabilities []string          `json:"capabilities"`
	Contract     int               `json:"contract"`
	Rev          int               `json:"rev"`
	Forgotten    *bool             `json:"forgotten,omitempty"`
	WrittenBy    *WrittenBy        `json:"writtenBy,omitempty"`
	Group        *string           `json:"group,omitempty"`
}

func (p ProviderRecord) MarshalJSON() ([]byte, error) {
	j := providerJSON{p.ID, p.Name, p.Kind, p.Command, p.Args, p.URL, p.Headers, p.Commands, p.SecretNames, p.Map,
		p.Capabilities, p.Contract, p.Rev, p.Forgotten, p.WrittenBy, p.Group}
	if j.SecretNames == nil {
		j.SecretNames = []string{}
	}
	if j.Capabilities == nil {
		j.Capabilities = []string{}
	}
	return encodeKeeping(j, p.Extra)
}

func (p *ProviderRecord) UnmarshalJSON(data []byte) error {
	var j providerJSON
	extra, err := decodeKeeping(data, &j, "id", "name", "kind", "secretNames", "capabilities", "contract", "rev")
	if err != nil {
		return err
	}
	if !knownKind(j.Kind) {
		return fmt.Errorf("no provider kind %q", j.Kind)
	}
	*p = ProviderRecord{j.ID, j.Name, j.Kind, j.Command, j.Args, j.URL, j.Headers, j.Commands, j.SecretNames, j.Map,
		j.Capabilities, j.Contract, j.Rev, j.Forgotten, j.WrittenBy, j.Group, extra}
	return nil
}

// Problem is ProviderRecord.problem: why it cannot be used as it is, in words for the
// sheet; "" when it can.
func (p *ProviderRecord) Problem() string {
	trimmed := trimSpaces(p.Name)
	if trimmed == "" {
		return "Give it a name."
	}
	if utf8.RuneCountInString(trimmed) > 60 {
		return "The name is over 60 characters."
	}
	switch p.Kind {
	case KindCommands:
		if _, ok := obj(p.Commands); !ok {
			return "Choose a preset or give its commands."
		}
	case KindStdio:
		if p.Command == nil || trimSpaces(*p.Command) == "" {
			return "Give the command that runs the server."
		}
	case KindHTTP:
		ok := p.URL != nil && (strings.HasPrefix(*p.URL, "http://") || strings.HasPrefix(*p.URL, "https://"))
		if ok {
			_, err := url.Parse(*p.URL)
			ok = err == nil
		}
		if !ok {
			return "The address must start with http:// or https://."
		}
	}
	for _, name := range p.ReferencedSecrets() {
		found := false
		for _, s := range p.SecretNames {
			found = found || s == name
		}
		if !found {
			return "${" + name + "} isn’t one of its secrets."
		}
	}
	return ""
}

// ReferencedSecrets is ProviderRecord.referencedSecrets: the ${NAME} its headers name.
func (p *ProviderRecord) ReferencedSecrets() []string {
	var found []string
	for _, v := range p.Headers {
		found = append(found, placeholders(v)...)
	}
	sort.Strings(found)
	return found
}

func placeholders(text string) []string {
	var found []string
	rest := text
	for {
		open := strings.Index(rest, "${")
		if open < 0 {
			return found
		}
		close := strings.IndexByte(rest[open+2:], '}')
		if close < 0 {
			return found
		}
		found = append(found, rest[open+2:open+2+close])
		rest = rest[open+2+close+1:]
	}
}

// preset is the command provider's preset, when it uses one.
func (p *ProviderRecord) preset() string { return strOr(get(p.Commands, "preset")) }

// DefaultIdleMinutes is WorkspaceLink.defaultIdleMinutes.
const DefaultIdleMinutes = 30

// WorkspaceLink is WorkspaceLink: a host and the workspace it runs on, kept in the host's
// own record (MachineRecord.Workspace).
type WorkspaceLink struct {
	Provider string
	// The workspace's id, as its provider lists it.
	Workspace string
	// A prompt or agent start for it while stopped starts it (US3). Nil reads as on.
	StartWhenUsed *bool
	// Stopped once idle this long (US4); nil is off.
	StopWhenIdleMinutes *int
	// Started a little before the host's next scheduled workflow (#1004). Nil reads as on.
	StartForSchedules *bool
	// The host's next scheduled workflow as it last said it, kept while it is stopped.
	Schedule *Schedule
	// How long its last start took, from asking the provider to the host connecting.
	MeasuredStartSeconds *int
	// The due time it was last started for, so each starts it once.
	WokeFor *time.Time
	Extra   records.Extra
}

// Schedule is DaemonAPI.MachineSchedule as a link keeps it.
type Schedule struct {
	At       *time.Time
	Workflow string
}

func (s *Schedule) equal(o *Schedule) bool {
	if s == nil || o == nil {
		return s == nil && o == nil
	}
	return s.Workflow == o.Workflow && sameTime(s.At, o.At)
}

func sameTime(a, b *time.Time) bool {
	if a == nil || b == nil {
		return a == nil && b == nil
	}
	return a.Truncate(time.Millisecond).Equal(b.Truncate(time.Millisecond))
}

type scheduleJSON struct {
	At       *records.Stamp `json:"at,omitempty"`
	Workflow string         `json:"workflow,omitempty"`
}

type linkJSON struct {
	Provider             string         `json:"provider"`
	Workspace            string         `json:"workspace"`
	StartWhenUsed        *bool          `json:"startWhenUsed,omitempty"`
	StopWhenIdleMinutes  *int           `json:"stopWhenIdleMinutes,omitempty"`
	StartForSchedules    *bool          `json:"startForSchedules,omitempty"`
	Schedule             *scheduleJSON  `json:"schedule,omitempty"`
	MeasuredStartSeconds *int           `json:"measuredStartSeconds,omitempty"`
	WokeFor              *records.Stamp `json:"wokeFor,omitempty"`
}

func stamp(t *time.Time) *records.Stamp {
	if t == nil {
		return nil
	}
	s := records.At(*t)
	return &s
}

func unstamp(s *records.Stamp) *time.Time {
	if s == nil {
		return nil
	}
	t := s.Time
	return &t
}

func (l WorkspaceLink) MarshalJSON() ([]byte, error) {
	j := linkJSON{l.Provider, l.Workspace, l.StartWhenUsed, l.StopWhenIdleMinutes, l.StartForSchedules, nil,
		l.MeasuredStartSeconds, stamp(l.WokeFor)}
	if l.Schedule != nil {
		j.Schedule = &scheduleJSON{stamp(l.Schedule.At), l.Schedule.Workflow}
	}
	return encodeKeeping(j, l.Extra)
}

func (l *WorkspaceLink) UnmarshalJSON(data []byte) error {
	var j linkJSON
	extra, err := decodeKeeping(data, &j, "provider", "workspace")
	if err != nil {
		return err
	}
	*l = WorkspaceLink{j.Provider, j.Workspace, j.StartWhenUsed, j.StopWhenIdleMinutes, j.StartForSchedules, nil,
		j.MeasuredStartSeconds, unstamp(j.WokeFor), extra}
	if j.Schedule != nil {
		l.Schedule = &Schedule{unstamp(j.Schedule.At), j.Schedule.Workflow}
	}
	return nil
}

func (l *WorkspaceLink) equal(o *WorkspaceLink) bool {
	if l == nil || o == nil {
		return l == nil && o == nil
	}
	a, _ := json.Marshal(l)
	b, _ := json.Marshal(o)
	return string(a) == string(b)
}

// LinkOf is a host's workspace link, or nil.
func LinkOf(h *records.MachineRecord) *WorkspaceLink {
	if h == nil || len(h.Workspace) == 0 || string(h.Workspace) == "null" {
		return nil
	}
	var l WorkspaceLink
	if json.Unmarshal(h.Workspace, &l) != nil {
		return nil
	}
	return &l
}

// setLink sets a host's workspace link; nil unlinks it.
func setLink(h *records.MachineRecord, l *WorkspaceLink) {
	if l == nil {
		h.Workspace = nil
		return
	}
	data, err := json.Marshal(l)
	if err != nil {
		return
	}
	h.Workspace = data
}

// decodeKeeping decodes data into v (a struct with no methods of its own), checks that
// each of required is there, and returns what it did not know.
func decodeKeeping(data []byte, v any, required ...string) (records.Extra, error) {
	var all map[string]json.RawMessage
	if err := json.Unmarshal(data, &all); err != nil {
		return nil, err
	}
	for _, name := range required {
		if raw, ok := all[name]; !ok || string(raw) == "null" {
			return nil, fmt.Errorf("no %s", name)
		}
	}
	if err := decodeJSON(data, v); err != nil {
		return nil, err
	}
	known := map[string]bool{}
	t := reflect.TypeOf(v).Elem()
	for i := range t.NumField() {
		name, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
		known[name] = true
	}
	var extra records.Extra
	for name, raw := range all {
		if !known[name] {
			if extra == nil {
				extra = records.Extra{}
			}
			extra[name] = raw
		}
	}
	return extra, nil
}

// encodeKeeping encodes v with extra beside it.
func encodeKeeping(v any, extra records.Extra) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil || len(extra) == 0 {
		return raw, err
	}
	var all map[string]json.RawMessage
	if err := json.Unmarshal(raw, &all); err != nil {
		return nil, err
	}
	for name, value := range extra {
		if _, ok := all[name]; !ok {
			all[name] = value
		}
	}
	return json.Marshal(all)
}
