package skillcatalog

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Sidecar is what the lock files have no field for (CatalogSidecar, catalog-skills.json in
// the daemon's root): the commit a skill was taken at, its date, the folder's tree SHA and
// the catalogue. Losing it costs a "Taken at" line and one API call, nothing more.
type Sidecar struct {
	Version int                      `json:"version"`
	Skills  map[string]SidecarRecord `json:"skills"`
}

// SidecarRecord's dates are ISO 8601 to the second, as Swift's .iso8601 writes them.
type SidecarRecord struct {
	Commit      string     `json:"commit"`
	CommittedAt *time.Time `json:"committedAt,omitempty"`
	TreeSHA     string     `json:"treeSHA"`
	Catalogue   string     `json:"catalogue"`
	AddedAt     time.Time  `json:"addedAt"`
	// FolderHash is the CLI's hash of the folder as written, which "edited since it was
	// added" is judged against.
	FolderHash *string `json:"folderHash,omitempty"`
}

// SidecarKey is personal/<name>, or <folder>/<name>.
func SidecarKey(d wire.SkillDestination, name string) string {
	if d.Kind == wire.SkillDestinationKindFolder && d.Folder != nil {
		return filepath.Clean(*d.Folder) + "/" + name
	}
	return "personal/" + name
}

// LoadSidecar reads the file; one that does not decode is set aside and this starts empty.
func LoadSidecar(path string) Sidecar {
	empty := Sidecar{Version: 1, Skills: map[string]SidecarRecord{}}
	b, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) || err != nil {
		return empty
	}
	var s Sidecar
	if json.Unmarshal(b, &s) != nil {
		aside := fmt.Sprintf("%s.unreadable-%d", path, time.Now().Unix())
		os.Rename(path, aside)
		store.TrimSetAsides(path)
		log.Printf("%s: unreadable; kept as %s; skills added from the catalogue show without where they were taken from",
			filepath.Base(path), filepath.Base(aside))
		return empty
	}
	if s.Skills == nil {
		s.Skills = map[string]SidecarRecord{}
	}
	return s
}

func (s Sidecar) Save(path string) error {
	for k, r := range s.Skills {
		r.AddedAt = r.AddedAt.UTC().Truncate(time.Second)
		if r.CommittedAt != nil {
			t := r.CommittedAt.UTC().Truncate(time.Second)
			r.CommittedAt = &t
		}
		s.Skills[k] = r
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	return store.WriteAtomically(path, b, 0o644)
}
