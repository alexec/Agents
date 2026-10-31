package mcpcatalog

import (
	_ "embed"
	"path/filepath"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// The connectors Agents makes (#1428, #2155): rows of the Agents marketplace, a file carried
// inside agentsd (agents.json), like any other connector: no group and no badge of their own.
// They are added the same way as any other connector and run hosted, one copy per host
// (#488). Their levels come from what they declare, as for any server.
//
// None asks for a secret. github-mcp, linear-mcp and gitlab-mcp read the person's GitHub,
// Linear and GitLab connections (#1343, #1630); email-mcp reads the person's email connection
// (Connect Email, #1780) and never sends mail. A token set by hand in mcp.json's env still goes
// first. tested is when each was last tested on a real account (docs/reference/integrations.md).

//go:embed agents.json
var agentsFile []byte

// AgentsMarketplace is the provided marketplace's id, as skillcatalog lists it.
const AgentsMarketplace = skillcatalog.AgentsMarketplaceID

// Ours is one connector that Agents makes.
type Ours struct {
	// ID is the catalogue's id, never a registry's (a registry name has a dot before its slash).
	ID          string
	Title       string
	Description string
	// Command is the binary beside agentsd: Agents Host and every Linux host carry it.
	Command string
	// Secret, when set, is the one secret it reads from its environment.
	Secret, SecretDescription string
	// Declares is what the server declares, for the catalogue before this host has checked
	// it. A test holds its events and tools to the servers' own.
	Declares Declared
	// Tested is when it was last tested on a real account, empty when never.
	Tested string
}

// Made is every connector Agents makes, in the file's order.
var Made = mustOurs(agentsFile)

func mustOurs(b []byte) []Ours {
	entries, err := parseFileMarketplace(b)
	if err != nil {
		panic("mcpcatalog: agents.json: " + err.Error())
	}
	out := []Ours{}
	for _, e := range entries {
		if o, ok := e.ours(); ok {
			out = append(out, o)
		}
	}
	return out
}

// NameHere is the name its entry takes in an mcp.json: github, gitlab.
func (o Ours) NameHere() string { return slug(o.Title) }

// OursByID is the connector with this catalogue id.
func OursByID(id string) (Ours, bool) {
	for _, o := range Made {
		if o.ID == id {
			return o, true
		}
	}
	return Ours{}, false
}

// OursByCommand is the connector an mcp.json entry with this command runs, by the
// command's base name.
func OursByCommand(command string) (Ours, bool) {
	base := filepath.Base(strings.TrimSpace(command))
	for _, o := range Made {
		if o.Command == base {
			return o, true
		}
	}
	return Ours{}, false
}

// OursResult is the connector as a row of the Agents marketplace, with the levels it declares.
func OursResult(o Ours, declared Declared) wire.MCPCatalogResult {
	levels := Levels(declared, o.Tested != "")
	market := AgentsMarketplace
	return wire.MCPCatalogResult{ID: o.ID, Title: o.Title, Description: o.Description, Version: "",
		Publisher: wire.MCPPublisherInfo{Label: "Agents", Namespace: "agents", Known: true}, Known: true,
		Runs: []wire.MCPRunKind{wire.MCPRunKindCommand}, Levels: &levels, Marketplace: &market}
}

// BuildOurs is the mcp.json entry for one of ours: its command, hosted, and its secret by name.
func BuildOurs(o Ours, alreadySet func(string) bool) Built {
	entry := skillcatalog.Object(skillcatalog.Pair{Key: "command", Value: skillcatalog.String(o.Command)},
		skillcatalog.Pair{Key: "hosted", Value: skillcatalog.Value{Kind: 'b', Bool: true}})
	vars := []wire.MCPVariable{}
	if o.Secret != "" {
		entry.Set("env", object([]pair{{o.Secret, "${" + o.Secret + "}"}}))
		vars = append(vars, wire.MCPVariable{Name: o.Secret, Description: o.SecretDescription, Kind: wire.MCPVariableKindSecret,
			Required: true, AlreadySet: alreadySet(o.Secret)})
	}
	return Built{NameHere: slug(o.Title), ChosenRun: wire.MCPRunKindCommand, CommandOrURL: o.Command + " (hosted)",
		Entry: entry, Variables: vars}
}

// Declared is what a server declares: tools in tools/list, events in initialize's
// capabilities (and their names in events/list), and ui:// views.
type Declared struct {
	Tools  bool
	Events []string
	// HasEvents is the capability, which a server can declare with no events listed yet.
	HasEvents bool
	Views     bool
}

// ReadyMadeEvents is the events that Agents' ready-made workflows start on (#1342). A
// workflow names events, never a server, so any server that declares one of them reaches
// the Workflows level. agentsd's readymade folder holds the workflows; a test there keeps
// this list the same as their triggers.
var ReadyMadeEvents = []string{"checks.failed", "email.received", "issue.labelled", "review.comment", "review.posted"}

// Levels is the five levels (#1428) from what a server declares, and whether it was tested.
func Levels(d Declared, tested bool) wire.MCPLevels {
	workflows := false
	for _, e := range d.Events {
		for _, r := range ReadyMadeEvents {
			workflows = workflows || e == r
		}
	}
	return wire.MCPLevels{Tools: d.Tools, Events: d.HasEvents || len(d.Events) > 0, Views: d.Views,
		Workflows: workflows, Tested: tested}
}
