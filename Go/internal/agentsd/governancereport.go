package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// governanceItemsMost is what the control plane keeps of one report (#2019, M5).
const governanceItemsMost = 500

// governanceItems is each MCP server and skill this machine has from a catalogue,
// personal and in its folders, from the catalogue sidecars: a server's registry name
// and version, a skill's catalogue and commit. A folder is not said. The files
// are only read here: one that does not decode says nothing.
func (d *Daemon) governanceItems() []wire.CatalogItem {
	seen := map[string]bool{}
	var out []wire.CatalogItem
	add := func(item wire.CatalogItem) {
		key := string(item.Kind) + "\x00" + item.Name + "\x00" + deref(item.Version)
		if item.Name != "" && !seen[key] {
			seen[key] = true
			out = append(out, item)
		}
	}
	var servers mcpcatalog.Sidecar
	if b, err := os.ReadFile(d.mcpSidecarPath()); err == nil && json.Unmarshal(b, &servers) == nil {
		still := d.mcpStillThere()
		for key, r := range servers.Servers {
			if !still(key) {
				continue
			}
			add(wire.CatalogItem{Kind: wire.CatalogKindMCP, Name: lastPart(key), Source: optionalString(r.RegistryName),
				Version: optionalString(r.Version), ByHand: r.ByHand})
		}
	}
	var skills skillcatalog.Sidecar
	if b, err := os.ReadFile(filepath.Join(d.Store.Loc.Root, "catalog-skills.json")); err == nil && json.Unmarshal(b, &skills) == nil {
		for key, r := range skills.Skills {
			commit := r.Commit
			if len(commit) > 12 {
				commit = commit[:12]
			}
			add(wire.CatalogItem{Kind: wire.CatalogKindSkills, Name: lastPart(key), Source: optionalString(r.Catalogue),
				Version: optionalString(commit)})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Kind != out[j].Kind {
			return out[i].Kind < out[j].Kind
		}
		return out[i].Name < out[j].Name
	})
	if len(out) > governanceItemsMost {
		out = out[:governanceItemsMost]
	}
	return out
}

// lastPart is a sidecar key's name: personal/<name> or <folder>/<name>.
func lastPart(key string) string { return key[strings.LastIndex(key, "/")+1:] }

// mcpStillThere says whether a sidecar entry's server is still in the mcp.json its key
// names, the personal one or the folder's (#2505). The sidecar is not pruned when a
// server leaves mcp.json by hand, so the report would keep a server no agent can use. Each
// mcp.json is read once a report. One that cannot be read, or that is not valid, settles
// nothing: its entries stay, as the sidecar is all that is known of them.
func (d *Daemon) mcpStillThere() func(key string) bool {
	type names struct {
		known bool
		has   map[string]bool
	}
	files := map[string]names{}
	return func(key string) bool {
		i := strings.LastIndex(key, "/")
		if i < 0 {
			return true
		}
		scope, name := key[:i], key[i+1:]
		path := ""
		if scope == "personal" {
			if home := d.personalHome(); home != "" {
				path = mcpcatalog.PersonalFile(home)
			}
		} else {
			path = mcpcatalog.FolderFile(scope)
		}
		if path == "" {
			return true
		}
		f, ok := files[path]
		if !ok {
			if _, err := mcpcatalog.LoadFile(path); err == nil {
				if entries, problem := readMCPFile(path); problem == "" {
					f = names{known: true, has: map[string]bool{}}
					for _, e := range entries {
						f.has[e.name] = true
					}
				}
			}
			files[path] = f
		}
		return !f.known || f.has[name]
	}
}

func optionalString(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

// sendGovernanceReport tells the control plane what this machine has from a catalogue,
// with the hourly report. A control plane before governance/1 answers that it has no such
// method; nothing more is tried until the next hour.
func (d *Daemon) sendGovernanceReport() {
	ask := d.askControl.Load()
	if ask == nil {
		return
	}
	items := d.governanceItems()
	if items == nil {
		items = []wire.CatalogItem{}
	}
	ctx, cancel := context.WithTimeout(d.ctx, reportPatience)
	defer cancel()
	if _, err := (*ask)(ctx, wire.CallGovernanceReport.Name, wire.MachineCatalog{Items: items}); err != nil {
		log.Printf("governance/report: not sent, tried again within the hour: %v", err)
	}
}
