package mcpcatalog

import (
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// A marketplace that is a file (#2155): the MCP Registry's list shape, {"servers": [{"server":
// {…}, "_meta": {…}}]}, or one server.json, in a file or in each .json file of a folder. The
// Agents marketplace is one, carried inside agentsd; a person's or a folder's
// marketplaces.json can name another with the format "file".

// connectorMeta is the key in _meta that says how one of ours runs. It is read only in the
// Agents marketplace: elsewhere a committed file could make a connector that runs any command.
const connectorMeta = "dev.agentloops/connector"

type fileEntry struct {
	Server Server
	// Connector is _meta's connector part, nil when there is none.
	Connector *connectorPart
}

type connectorPart struct {
	Command  string `json:"command"`
	Hosted   bool   `json:"hosted"`
	Declares struct {
		Tools  bool     `json:"tools"`
		Events []string `json:"events"`
		Views  bool     `json:"views"`
	} `json:"declares"`
	Tested string `json:"tested"`
}

// ours is the entry as one of ours, when its _meta says how it runs.
func (e fileEntry) ours() (Ours, bool) {
	c := e.Connector
	if c == nil || c.Command == "" || strings.ContainsAny(c.Command, "/\\") {
		return Ours{}, false
	}
	title := ShortName(e.Server.Name)
	if e.Server.Title != nil {
		title = *e.Server.Title
	}
	return Ours{ID: e.Server.Name, Title: title, Description: deref(e.Server.Description), Command: c.Command,
		Declares: Declared{Tools: c.Declares.Tools, Events: c.Declares.Events, Views: c.Declares.Views}, Tested: c.Tested}, true
}

// parseFileMarketplace reads the list shape or one server.json.
func parseFileMarketplace(b []byte) ([]fileEntry, error) {
	type item struct {
		Server json.RawMessage            `json:"server"`
		Meta   map[string]json.RawMessage `json:"_meta"`
	}
	var list struct {
		Servers []item `json:"servers"`
	}
	if err := json.Unmarshal(b, &list); err != nil {
		return nil, err
	}
	if list.Servers == nil {
		// One server.json: the server at the top, its _meta beside its fields.
		list.Servers = []item{{Server: b}}
	}
	out := []fileEntry{}
	for _, it := range list.Servers {
		var s Server
		var inner struct {
			Meta map[string]json.RawMessage `json:"_meta"`
		}
		if json.Unmarshal(it.Server, &s) != nil || strings.TrimSpace(s.Name) == "" {
			continue
		}
		json.Unmarshal(it.Server, &inner)
		e := fileEntry{Server: s}
		for _, meta := range []map[string]json.RawMessage{it.Meta, inner.Meta} {
			if raw, ok := meta[connectorMeta]; ok {
				var c connectorPart
				if json.Unmarshal(raw, &c) == nil {
					e.Connector = &c
				}
			}
		}
		out = append(out, e)
	}
	return out, nil
}

// FileMarketplace is a marketplace read from disk, or the Agents one when Builtin.
type FileMarketplace struct {
	Path    string
	Builtin bool
}

// Each file is read up to this size; a folder's first 200 .json files.
const (
	fileMarketLimit   = 4 << 20
	folderMarketFiles = 200
)

// UnreadableFile is a file marketplace that could not be read.
func UnreadableFile(path string) *Error {
	return Failed(path + " could not be read as a marketplace")
}

func (f FileMarketplace) entries() ([]fileEntry, error) {
	if f.Builtin {
		return parseFileMarketplace(agentsFile)
	}
	info, err := os.Stat(f.Path)
	if err != nil {
		return nil, UnreadableFile(f.Path)
	}
	files := []string{f.Path}
	if info.IsDir() {
		files, _ = filepath.Glob(filepath.Join(f.Path, "*.json"))
		sort.Strings(files)
		if len(files) > folderMarketFiles {
			files = files[:folderMarketFiles]
		}
	}
	out := []fileEntry{}
	for _, p := range files {
		b, err := readLimited(p)
		if err != nil {
			if !info.IsDir() {
				return nil, UnreadableFile(p)
			}
			continue
		}
		got, err := parseFileMarketplace(b)
		if err != nil {
			if !info.IsDir() {
				return nil, UnreadableFile(p)
			}
			continue
		}
		for _, e := range got {
			// Only the Agents marketplace says how one of ours runs.
			e.Connector = nil
			out = append(out, e)
		}
	}
	return out, nil
}

func readLimited(path string) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	b, err := io.ReadAll(io.LimitReader(file, fileMarketLimit+1))
	if err != nil {
		return nil, err
	}
	if len(b) > fileMarketLimit {
		return nil, errors.New("too large")
	}
	return b, nil
}

// Search is every entry, or those whose name, title or description holds every word typed.
// declared says what a checked copy of one of ours declared, when a host has one.
func (f FileMarketplace) Search(query string, tools Tools, declared func(Ours) Declared) ([]wire.MCPCatalogResult, error) {
	entries, err := f.entries()
	if err != nil {
		return nil, err
	}
	words := strings.Fields(strings.ToLower(query))
	out := []wire.MCPCatalogResult{}
	for _, e := range entries {
		text := strings.ToLower(e.Server.Name + " " + deref(e.Server.Title) + " " + deref(e.Server.Description))
		match := true
		for _, w := range words {
			match = match && strings.Contains(text, w)
		}
		if !match {
			continue
		}
		if o, ok := e.ours(); ok {
			out = append(out, OursResult(o, declared(o)))
			continue
		}
		out = append(out, Result(e.Server, tools))
	}
	return out, nil
}

// Detail is the entry with this name, and the connector it is when it is one of ours.
func (f FileMarketplace) Detail(name string) (Server, *Ours, error) {
	entries, err := f.entries()
	if err != nil {
		return Server{}, nil, err
	}
	for _, e := range entries {
		if e.Server.Name == name {
			if o, ok := e.ours(); ok {
				return e.Server, &o, nil
			}
			return e.Server, nil, nil
		}
	}
	return Server{}, nil, Failed(name + " is no longer in that marketplace")
}
