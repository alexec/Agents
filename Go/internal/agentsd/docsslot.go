package agentsd

import (
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/wire"
)

// The Docs slot (#3248): where the folder's docs live, so that agents find the requirements
// and designs behind an issue. This folder is the default, local first: the *.md files at
// its top (README.md and the like) and every *.md under specs/ and docs/. Its one read is the
// newest of them. The docs connectors in the folder's or the person's mcp.json fill the slot
// beside it: Confluence (Atlassian's server), Notion, Google Drive, or any whose name or
// address says docs or wiki, or any that a map says can search and read; each proves itself
// with one real search through that map (docsmap.go, #3307). Agents writes no server of its
// own for any of them.

// docsScanLimit is the most files one read looks at, so a huge docs/ costs a bounded walk.
const docsScanLimit = 5000

// docsFolders are the folders whose *.md files are docs, as well as the folder's top.
var docsFolders = []string{"specs", "docs"}

// docsKinds are the docs connectors the slot knows, by what their mcp.json name or their
// command or address has in it. The last has no name of its own: the entry's name is used.
var docsKinds = []struct {
	name  string
	marks []string
}{
	{"Confluence", []string{"atlassian", "confluence"}},
	{"Notion", []string{"notion"}},
	{"Google Drive", []string{"google-drive", "googledrive", "gdrive", "drive.google", "google_drive"}},
	{"", []string{"docs", "wiki", "knowledge"}},
}

// newestDoc is the folder's newest doc, relative to the folder, and when it changed.
// Found is false when the folder has no docs.
func newestDoc(folder string) (rel string, at time.Time, found bool) {
	for _, f := range folderDocFiles(folder) {
		if !found || f.at.After(at) {
			rel, at, found = f.rel, f.at, true
		}
	}
	return rel, at, found
}

// folderDocFiles is the folder's docs: the *.md files at its top and under specs/ and docs/
// (in no hidden folder or node_modules), regular files only, looking at docsScanLimit files
// at most.
func folderDocFiles(folder string) []docFile {
	var out []docFile
	seen := 0
	look := func(path string, d fs.DirEntry) {
		seen++
		if d.IsDir() || !strings.EqualFold(filepath.Ext(d.Name()), ".md") {
			return
		}
		info, err := d.Info()
		if err != nil || !info.Mode().IsRegular() {
			return
		}
		r, err := filepath.Rel(folder, path)
		if err != nil {
			return
		}
		out = append(out, docFile{rel: filepath.ToSlash(r), at: info.ModTime(), size: info.Size()})
	}
	if entries, err := os.ReadDir(folder); err == nil {
		for _, e := range entries {
			look(filepath.Join(folder, e.Name()), e)
		}
	}
	for _, sub := range docsFolders {
		root := filepath.Join(folder, sub)
		_ = filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil
			}
			if seen >= docsScanLimit {
				return fs.SkipAll
			}
			if d.IsDir() && path != root && (strings.HasPrefix(d.Name(), ".") || d.Name() == "node_modules") {
				return fs.SkipDir
			}
			look(path, d)
			return nil
		})
	}
	return out
}

// readDocs is the Docs slot's read of the folder.
func readDocs(folder string, now time.Time) *slotRecord {
	rel, at, found := newestDoc(folder)
	s := &slotRecord{Read: true, ReadAt: now}
	if found {
		date := wire.DateOf(at)
		s.Proof = &wire.ConnectorProof{Title: rel, At: &date}
	}
	return s
}

// docsServerEntry is a docs connector that reaches a folder: its name in mcp.json, and the
// words the slot says for it.
type docsServerEntry struct{ name, word string }

// docsServerEntries is the docs connectors that reach the folder (its own mcp.json, then the
// person's), each once. A server that its map says can search and read is one whatever its
// name (#3307).
func (d *Daemon) docsServerEntries(folder string, maps map[string]docsMap) []docsServerEntry {
	entries, _ := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
	if home := d.personalHome(); home != "" {
		personal, _ := readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
		entries = append(entries, personal...)
	}
	var out []docsServerEntry
	seen := map[string]bool{}
	for _, e := range entries {
		word, ok := docsKindOf(e.name, mcpSummary(e))
		if m, mapped := maps[e.name]; !ok && mapped && m.searchesAndReads() {
			word, ok = e.name, true
		}
		if !ok || seen[e.name] {
			continue
		}
		seen[e.name] = true
		out = append(out, docsServerEntry{e.name, word})
	}
	return out
}

// docsServers is the docs connectors that reach the folder: their names in mcp.json, and the
// words the slot says for them, each once.
func (d *Daemon) docsServers(folder string, maps map[string]docsMap) (names, words []string) {
	seenWord := map[string]bool{}
	for _, e := range d.docsServerEntries(folder, maps) {
		names = append(names, e.name)
		if !seenWord[e.word] {
			seenWord[e.word] = true
			words = append(words, e.word)
		}
	}
	return names, words
}

// docsKindOf is the words for a docs connector named name that runs as summary, and
// whether it is one.
func docsKindOf(name, summary string) (string, bool) {
	text := strings.ToLower(name + " " + summary)
	for _, k := range docsKinds {
		for _, m := range k.marks {
			if strings.Contains(text, m) {
				if k.name == "" {
					return name, true
				}
				return k.name, true
			}
		}
	}
	return "", false
}

// docsChoice is what fills the slot, in words: This folder, and the docs connectors.
func docsChoice(words []string) string {
	all := append([]string{"This folder"}, words...)
	if len(all) == 1 {
		return all[0]
	}
	return strings.Join(all[:len(all)-1], ", ") + " and " + all[len(all)-1]
}

// docsSlot is the Docs slot from its last read: each docs connector with its last search, or
// with no map yet, or mapped and not searched yet.
func docsSlot(rec *slotRecord, skipped bool, servers, words []string, maps map[string]docsMap) wire.ConnectorSlot {
	s := wire.ConnectorSlot{Slot: wire.ConnectorSlotKindDocs, Choice: docsChoice(nil)}
	switch {
	case skipped:
		s.State = wire.ConnectorSlotStateSkipped
		return s
	case rec == nil || !rec.Read:
		s.State = wire.ConnectorSlotStateNotRead
	default:
		s.State, s.Proof = wire.ConnectorSlotStateRead, rec.Proof
		at := wire.DateOf(rec.ReadAt)
		s.ReadAt = &at
	}
	s.Choice = docsChoice(words)
	if len(servers) > 0 {
		s.Servers = servers
	}
	for _, name := range servers {
		m, mapped := maps[name]
		r := findDocsRecord(rec, name)
		switch {
		case !mapped || !m.searchesAndReads():
			s.DocsServers = append(s.DocsServers, wire.DocsServer{Name: name, State: wire.DocsServerStateNoMap})
		case r == nil || r.Map != m.digest() || s.State != wire.ConnectorSlotStateRead:
			s.DocsServers = append(s.DocsServers, wire.DocsServer{Name: name, State: wire.DocsServerStateNotRead})
		default:
			s.DocsServers = append(s.DocsServers, r.DocsServer)
		}
	}
	return s
}
