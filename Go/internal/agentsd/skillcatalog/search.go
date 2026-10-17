package skillcatalog

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/wire"
)

// SkillsSh is skills.sh, the catalogue (SkillsCatalog): its search, and its copy of a
// skill's text files, each checked against GitHub before it is used.
type SkillsSh struct {
	Client *http.Client
	// Base is the catalogue's address: skills.sh, or a marketplace of its format.
	Base string
}

// Search is results in the catalogue's order, most installed first. Only skills on GitHub
// (owner/repo); a query shorter than two characters is not sent.
func (s SkillsSh) Search(ctx context.Context, query string) ([]wire.CatalogResult, error) {
	q := strings.TrimSpace(query)
	if utf8.RuneCountInString(q) < 2 {
		return []wire.CatalogResult{}, nil
	}
	b, err := get(ctx, s.Client, s.Base+"/api/search?q="+url.QueryEscape(q), false)
	if err != nil {
		return nil, err
	}
	var answer struct {
		Skills []struct {
			ID       string `json:"id"`
			Source   string `json:"source"`
			SkillID  string `json:"skillId"`
			Name     string `json:"name"`
			Installs *int64 `json:"installs"`
		} `json:"skills"`
	}
	if json.Unmarshal(b, &answer) != nil {
		return nil, Unreachable(host(s.Base))
	}
	out := []wire.CatalogResult{}
	for _, r := range answer.Skills {
		owner, repo, ok := GitHubSource(r.Source)
		if !ok {
			continue
		}
		installs := int64(0)
		if r.Installs != nil {
			installs = *r.Installs
		}
		out = append(out, wire.CatalogResult{ID: r.ID, Name: r.Name, Owner: owner, Repo: repo, SkillID: r.SkillID,
			Installs: installs, Known: KnownOwner(owner)})
	}
	return out, nil
}

// Snapshot is skills.sh's copy of a skill's text files by path, or nil: GitHub alone is
// enough, only slower.
func (s SkillsSh) Snapshot(ctx context.Context, owner, repo, skillID string) map[string][]byte {
	b, err := get(ctx, s.Client, s.Base+"/api/download/"+owner+"/"+repo+"/"+skillID, false)
	if err != nil {
		return nil
	}
	var answer struct {
		Files []struct {
			Path     string `json:"path"`
			Contents string `json:"contents"`
		} `json:"files"`
	}
	if json.Unmarshal(b, &answer) != nil {
		return nil
	}
	out := map[string][]byte{}
	for _, f := range answer.Files {
		if _, ok := out[f.Path]; !ok {
			out[f.Path] = []byte(f.Contents)
		}
	}
	return out
}

// GitHubSkills is a GitHub repository of skills as a marketplace: every folder with a
// SKILL.md, by its folder. One tree read per repository, kept ten minutes.
type GitHubSkills struct {
	GitHub      GitHub
	Owner, Repo string
	Marketplace string
}

// Folder is a SKILL.md's folder: its own name, or the repository's for one at the top.
type Folder struct{ ID, Path string }

var folderCache = struct {
	sync.Mutex
	m map[string]struct {
		at      time.Time
		folders []Folder
	}
}{m: map[string]struct {
	at      time.Time
	folders []Folder
}{}}

// Search is every skill whose folder name holds the query, in the repository's order, at
// most a hundred; an empty query lists them all.
func (g GitHubSkills) Search(ctx context.Context, query string) ([]wire.CatalogResult, error) {
	want := strings.ToLower(strings.TrimSpace(query))
	key := g.Owner + "/" + g.Repo
	folderCache.Lock()
	hit, ok := folderCache.m[key]
	folderCache.Unlock()
	folders := hit.folders
	if !ok || time.Since(hit.at) >= 10*time.Minute {
		head, err := g.GitHub.Head(ctx, g.Owner, g.Repo)
		if err != nil {
			return nil, err
		}
		tree, err := g.GitHub.Tree(ctx, g.Owner, g.Repo, head.Commit)
		if err != nil {
			return nil, err
		}
		folders = SkillFolders(tree, g.Repo)
		folderCache.Lock()
		folderCache.m[key] = struct {
			at      time.Time
			folders []Folder
		}{time.Now(), folders}
		folderCache.Unlock()
	}
	out := []wire.CatalogResult{}
	for _, f := range folders {
		if len(out) == 100 {
			break
		}
		if want != "" && !strings.Contains(strings.ToLower(f.ID), want) {
			continue
		}
		path, market := f.Path, g.Marketplace
		out = append(out, wire.CatalogResult{ID: g.Owner + "/" + g.Repo + "/" + f.ID, Name: f.ID, Owner: g.Owner, Repo: g.Repo,
			SkillID: f.ID, Known: KnownOwner(g.Owner), Marketplace: &market, SkillPath: &path})
	}
	return out, nil
}

// SkillFolders is each SKILL.md's folder, with only the ids a preview will take.
func SkillFolders(tree []TreeEntry, repo string) []Folder {
	var out []Folder
	for _, e := range tree {
		if e.Type != "blob" || !(e.Path == "SKILL.md" || strings.HasSuffix(e.Path, "/SKILL.md")) {
			continue
		}
		parts := strings.Split(e.Path, "/")
		id := repo
		if len(parts) >= 2 {
			id = parts[len(parts)-2]
		}
		if !plainName(id) {
			continue
		}
		out = append(out, Folder{id, e.Path})
	}
	return out
}
