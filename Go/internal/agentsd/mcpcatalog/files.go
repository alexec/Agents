package mcpcatalog

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// PersonalFile is <home>/.agents/mcp.json; FolderFile is <folder>/.agents/mcp.json.
func PersonalFile(home string) string  { return filepath.Join(home, ".agents", "mcp.json") }
func FolderFile(folder string) string { return filepath.Join(folder, ".agents", "mcp.json") }

// RemovedFile is <home>/.agents/mcp.removed.json: the entries last taken out of the personal
// mcp.json (#2195). That file is not in git, so this is where one written by hand comes back from.
func RemovedFile(home string) string { return filepath.Join(home, ".agents", "mcp.removed.json") }

// keptRemoved is how many entries RemovedFile keeps.
const keptRemoved = 20

// KeepRemoved puts a removed entry last in RemovedFile, in mcp.json's own shape so it can be
// copied back as it is, and keeps only the last keptRemoved. It is the person's only copy and
// may hold a token typed in, so it is theirs alone to read.
func KeepRemoved(home, name string, entry skillcatalog.Value) error {
	path := RemovedFile(home)
	root, err := LoadFile(path)
	if err != nil {
		return err
	}
	servers, ok := root.Get("mcpServers")
	if !ok {
		servers = skillcatalog.Object()
	}
	servers.Remove(name)
	servers.Set(name, entry)
	if n := len(servers.Pairs); n > keptRemoved {
		servers.Pairs = servers.Pairs[n-keptRemoved:]
	}
	root.Set("mcpServers", servers)
	return store.WriteAtomically(path, []byte(root.Stringified()+"\n"), 0o600)
}

// FileProblem is an mcp.json that is there and cannot be taken as it is.
type FileProblem struct{ Message string }

func (p FileProblem) Error() string { return p.Message }

// LoadFile is mcp.json in its own order, or an empty one where there is none. One that is
// there and does not read is refused, never taken as empty: the next write would drop every
// hand-written server.
func LoadFile(path string) (skillcatalog.Value, error) {
	empty := skillcatalog.Object(skillcatalog.Pair{Key: "mcpServers", Value: skillcatalog.Object()})
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return empty, nil
	}
	if err != nil {
		if b, err = os.ReadFile(path); err != nil {
			return skillcatalog.Value{}, FileProblem{"mcp.json could not be read."}
		}
	}
	if strings.TrimSpace(string(b)) == "" {
		return empty, nil
	}
	root, err := skillcatalog.Parse(b)
	if err != nil || root.Kind != 'o' {
		return skillcatalog.Value{}, FileProblem{"mcp.json is not valid JSON."}
	}
	if servers, ok := root.Get("mcpServers"); ok && servers.Kind != 'o' {
		return skillcatalog.Value{}, FileProblem{"\"mcpServers\" in mcp.json should be an object, one entry per server."}
	}
	return root, nil
}

// Entry is one server's entry, if it is there.
func Entry(path, name string) (skillcatalog.Value, bool, error) {
	root, err := LoadFile(path)
	if err != nil {
		return skillcatalog.Value{}, false, err
	}
	servers, _ := root.Get("mcpServers")
	e, ok := servers.Get(name)
	return e, ok, nil
}

// Upsert puts name under mcpServers, in its place or at the end.
func Upsert(path, name string, entry skillcatalog.Value) error {
	root, err := LoadFile(path)
	if err != nil {
		return err
	}
	servers, ok := root.Get("mcpServers")
	if !ok {
		servers = skillcatalog.Object()
	}
	servers.Set(name, entry)
	root.Set("mcpServers", servers)
	return write(root, path)
}

// Remove takes name out.
func Remove(path, name string) error {
	root, err := LoadFile(path)
	if err != nil {
		return err
	}
	servers, ok := root.Get("mcpServers")
	if !ok {
		return nil
	}
	servers.Remove(name)
	root.Set("mcpServers", servers)
	return write(root, path)
}

// write is whole and renamed over the old one, keeping the file's own permissions.
func write(root skillcatalog.Value, path string) error {
	mode := os.FileMode(0o644)
	if info, err := os.Stat(path); err == nil {
		mode = info.Mode().Perm()
	}
	return store.WriteAtomically(path, []byte(root.Stringified()+"\n"), mode)
}

// Sidecar is catalog-mcp.json in the daemon's root: which servers the app added, from the
// registry or by hand.
type Sidecar struct {
	Version int               `json:"version"`
	Servers map[string]Record `json:"servers"`
}

type Record struct {
	RegistryName string    `json:"registryName"`
	Version      string    `json:"version"`
	Run          string    `json:"run"`
	AddedAt      time.Time `json:"addedAt"`
	ByHand       *bool     `json:"byHand,omitempty"`
}

// Key is personal/<name>, or <folder>/<name>.
func Key(d wire.SkillDestination, name string) string { return skillcatalog.SidecarKey(d, name) }

// LoadSidecar reads it; one that does not decode is set aside and this starts empty.
func LoadSidecar(path string) Sidecar {
	empty := Sidecar{Version: 1, Servers: map[string]Record{}}
	b, err := os.ReadFile(path)
	if err != nil {
		return empty
	}
	var s Sidecar
	if json.Unmarshal(b, &s) != nil {
		aside := fmt.Sprintf("%s.unreadable-%d", path, time.Now().Unix())
		os.Rename(path, aside)
		store.TrimSetAsides(path)
		log.Printf("%s: unreadable; kept as %s; servers added from the registry show as written by hand",
			filepath.Base(path), filepath.Base(aside))
		return empty
	}
	if s.Servers == nil {
		s.Servers = map[string]Record{}
	}
	return s
}

func (s Sidecar) Save(path string) error {
	for k, r := range s.Servers {
		r.AddedAt = r.AddedAt.UTC().Truncate(time.Second)
		s.Servers[k] = r
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return store.WriteAtomically(path, b, 0o644)
}
