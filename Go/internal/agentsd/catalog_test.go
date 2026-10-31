package agentsd

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/wire"
)

// Ports SkillPreviewAndAddTests, SkillUpdateRemoveTests' updates, SkillFailureTests'
// rate limit and MarketplacesTests, against AgentsKit's recorded skills.sh and GitHub
// (Fixtures/catalog/http), served as CatalogStub serves them.

const catalogFixtures = "../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/catalog"

type catalogStub struct {
	movedOn, rateLimited atomic.Bool
	treeReads            atomic.Int32
}

func serveCatalog(t *testing.T) *catalogStub {
	t.Helper()
	var meta struct{ Owner, Repo, Commit, Next string }
	b, _ := os.ReadFile(filepath.Join(catalogFixtures, "http", "meta.json"))
	json.Unmarshal(b, &meta)
	stub := &catalogStub{}
	file := func(w http.ResponseWriter, name string) {
		b, err := os.ReadFile(filepath.Join(catalogFixtures, "http", name))
		if err != nil {
			http.NotFound(w, nil)
			return
		}
		w.Write(b)
	}
	repo := "/" + meta.Owner + "/" + meta.Repo
	skillsSh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/api/search":
			file(w, "search-fixture.json")
		case strings.HasPrefix(r.URL.Path, "/api/download"+repo+"/"):
			file(w, "download-"+filepath.Base(r.URL.Path)+".json")
		default:
			http.NotFound(w, r)
		}
	}))
	github := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		switch {
		case p == repo+".git/info/refs":
			if stub.movedOn.Load() {
				file(w, "next/info-refs.txt")
			} else {
				file(w, "info-refs.txt")
			}
		case strings.HasPrefix(p, "/api/"):
			stub.treeReads.Add(1)
			if stub.rateLimited.Load() {
				w.Header().Set("x-ratelimit-remaining", "0")
				w.WriteHeader(403)
				file(w, "rate-limited.json")
				return
			}
			switch p {
			case "/api/repos" + repo + "/git/trees/" + meta.Commit:
				file(w, "tree.json")
			case "/api/repos" + repo + "/git/trees/" + meta.Next:
				file(w, "next/tree.json")
			default:
				http.NotFound(w, r)
			}
		case strings.HasPrefix(p, "/raw"+repo+"/"+meta.Next+"/"):
			rel := strings.TrimPrefix(p, "/raw"+repo+"/"+meta.Next+"/")
			if b, err := os.ReadFile(filepath.Join(catalogFixtures, "http", "next", "raw", rel)); err == nil {
				w.Write(b)
				return
			}
			if b, err := os.ReadFile(filepath.Join(catalogFixtures, rel)); err == nil {
				w.Write(b)
				return
			}
			http.NotFound(w, r)
		case strings.HasPrefix(p, "/raw"+repo+"/"+meta.Commit+"/"):
			if b, err := os.ReadFile(filepath.Join(catalogFixtures, strings.TrimPrefix(p, "/raw"+repo+"/"+meta.Commit+"/"))); err == nil {
				w.Write(b)
				return
			}
			http.NotFound(w, r)
		case p == "/codeload"+repo+"/tar.gz/"+meta.Commit:
			file(w, "tarball.tar.gz")
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(skillsSh.Close)
	t.Cleanup(github.Close)
	t.Setenv(skillcatalog.CatalogVariable, skillsSh.URL)
	t.Setenv(skillcatalog.GitHubVariable, github.URL)
	return stub
}

func TestASkillSearchedPreviewedAddedAndUpdated(t *testing.T) {
	stub := serveCatalog(t)
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	t.Setenv("XDG_STATE_HOME", "")
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	personal := map[string]any{"kind": "personal"}

	var found wire.CatalogSearchAnswer
	json.Unmarshal(c.call(t, 1, "catalog/search", map[string]any{"query": "fixture"}), &found)
	if found.Error != nil || len(found.Results) < 2 || found.Results[0].SkillID != "nested" || found.Results[0].Installs != 5120 ||
		*found.Results[0].Marketplace != skillcatalog.SkillsShID {
		t.Fatalf("%+v", found)
	}

	var preview wire.CatalogPreviewAnswer
	json.Unmarshal(c.call(t, 2, "catalog/preview", map[string]any{"result": found.Results[0], "destination": personal}), &preview)
	p := preview.Preview
	if preview.Error != nil || p == nil || p.Name != "nested" || len(p.Files) != 4 || p.DestinationState.Free == nil ||
		p.TreeSHA != "b4146b99df32f406302cf36ff69949f3b394ea01" ||
		p.ComputedHash != "43d79cc2b2a7065d4f3f4cc5ae35447d31c5b22469dcee4c35395c2c09d0ac0e" {
		t.Fatalf("%+v %+v", preview.Error, p)
	}
	via := map[string]string{}
	for _, f := range p.Files {
		via[f.Path] = f.Via
	}
	if via["SKILL.md"] != "snapshot" || via["assets/logo.png"] != "raw" || !p.Files[3].Runnable {
		t.Fatalf("%+v", p.Files)
	}

	var added wire.SkillAddAnswer
	json.Unmarshal(c.call(t, 3, "skills/add", map[string]any{"previewID": p.PreviewID, "destination": personal, "replace": false}), &added)
	if added.Skill.Name != "nested" || added.Skill.Source != "fixture-owner/fixture-skills" || added.Skill.Update.Current == nil {
		t.Fatalf("%+v", added)
	}
	if info, err := os.Stat(filepath.Join(home, ".agents", "skills", "nested", "scripts", "lint.sh")); err != nil || info.Mode()&0o100 == 0 {
		t.Fatal("not added whole", err)
	}
	lock, _ := skillcatalog.LoadLock(skillcatalog.Personal, filepath.Join(home, ".agents", ".skill-lock.json"))
	if e, ok := lock.Entry("nested"); !ok || e.SkillFolderHash != p.TreeSHA || e.SkillPath != "skills/nested/SKILL.md" {
		t.Fatalf("%+v", e)
	}
	// A preview is used once.
	if e := c.callError(t, 4, "skills/add", map[string]any{"previewID": p.PreviewID, "destination": personal, "replace": false}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}

	// The same skill again is the same skill, with nothing to update.
	json.Unmarshal(c.call(t, 5, "catalog/preview", map[string]any{"result": found.Results[0], "destination": personal}), &preview)
	if s := preview.Preview.DestinationState.SameSkill; s == nil || s.Update {
		t.Fatalf("%+v", preview.Preview.DestinationState)
	}

	var updates wire.SkillUpdatesAnswer
	json.Unmarshal(c.call(t, 6, "skills/check-updates", map[string]any{"destination": personal}), &updates)
	if updates.Updates["nested"].Current == nil {
		t.Fatalf("%+v", updates)
	}

	// The repository moves on and the skill's folder changes with it.
	stub.movedOn.Store(true)
	d.catalog().updates = &skillcatalog.UpdateCache{}
	updates = wire.SkillUpdatesAnswer{}
	json.Unmarshal(c.call(t, 7, "skills/check-updates", map[string]any{"destination": personal}), &updates)
	if a := updates.Updates["nested"].Available; a == nil || a.Commit != "9ca8b5441cc3bfe5f3a6c20e5eda0119083b7c4f" {
		t.Fatalf("%+v", updates)
	}
	var update wire.SkillUpdatePreviewAnswer
	json.Unmarshal(c.call(t, 8, "skills/update-preview", map[string]any{"destination": personal, "name": "nested"}), &update)
	if strings.Join(update.Changes.Added, ",") != "references/y.md" || strings.Join(update.Changes.Changed, ",") != "SKILL.md" ||
		update.Edited || update.Preview.DestinationState.SameSkill == nil || !update.Preview.DestinationState.SameSkill.Update {
		t.Fatalf("%+v", update)
	}
	if e := c.callError(t, 9, "skills/add", map[string]any{"previewID": update.Preview.PreviewID, "destination": personal, "replace": false}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
}

func TestASkillPreviewedFromTheTarballWhenGitHubLimitsRequests(t *testing.T) {
	stub := serveCatalog(t)
	stub.rateLimited.Store(true)
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	result := wire.CatalogResult{ID: "fixture-owner/fixture-skills/plain", Name: "plain", Owner: "fixture-owner",
		Repo: "fixture-skills", SkillID: "plain"}
	var preview wire.CatalogPreviewAnswer
	json.Unmarshal(c.call(t, 1, "catalog/preview", map[string]any{"result": result, "destination": map[string]any{"kind": "personal"}}), &preview)
	if preview.Preview == nil || preview.Preview.Files[0].Via != "tarball" || preview.Preview.TreeSHA != "23d62e67393a5c2fea8e704ecd9d15f6541312c8" {
		t.Fatalf("%+v %+v", preview.Error, preview.Preview)
	}
}

func TestThePersonsOwnMarketplaces(t *testing.T) {
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	var list wire.MarketplacesListAnswer
	json.Unmarshal(c.call(t, 1, "marketplaces/list", map[string]any{"kind": "skills"}), &list)
	if len(list.Marketplaces) != 2 || list.Marketplaces[0].ID != skillcatalog.SkillsShID || !list.Marketplaces[0].Enabled {
		t.Fatalf("%+v", list)
	}
	if e := c.callError(t, 2, "marketplaces/add", map[string]any{"name": "Acme", "format": "mcp-registry", "url": "http://acme.example"}); e.Message != "The address must be https (http only for localhost)." {
		t.Fatalf("%+v", e)
	}
	json.Unmarshal(c.call(t, 3, "marketplaces/add", map[string]any{"name": "Acme", "format": "mcp-registry", "url": "https://mcp.acme.example/",
		"token": "ACME_TOKEN", "tokenValue": "s3cret"}), &list)
	var acme *wire.Marketplace
	for i, m := range list.Marketplaces {
		if m.ID == "personal:https://mcp.acme.example" {
			acme = &list.Marketplaces[i]
		}
	}
	if acme == nil || acme.TokenMissing || *acme.Token != "ACME_TOKEN" || !acme.Enabled {
		t.Fatalf("%+v", list)
	}
	secrets, _ := os.ReadFile(filepath.Join(home, ".agents-secrets", "secrets.env"))
	if info, _ := os.Stat(filepath.Join(home, ".agents-secrets", "secrets.env")); string(secrets) != "ACME_TOKEN=s3cret\n" || info.Mode().Perm() != 0o600 {
		t.Fatalf("%q", secrets)
	}
	file, _ := os.ReadFile(filepath.Join(home, ".agents", "marketplaces.json"))
	if string(file) != "{\n  \"marketplaces\" : [\n    {\n      \"format\" : \"mcp-registry\",\n      \"name\" : \"Acme\",\n      \"token\" : \"ACME_TOKEN\",\n      \"url\" : \"https://mcp.acme.example\"\n    }\n  ]\n}\n" {
		t.Fatal(string(file))
	}
	json.Unmarshal(c.call(t, 4, "marketplaces/set-enabled", map[string]any{"id": "provided:official-mcp", "enabled": false}), &list)
	for _, m := range list.Marketplaces {
		if m.ID == "provided:official-mcp" && m.Enabled {
			t.Fatal("still on")
		}
	}
	if e := c.callError(t, 5, "marketplaces/remove", map[string]any{"id": "provided:official-mcp"}); e.Code != wire.FailureCatalogRefused {
		t.Fatalf("%+v", e)
	}
	list = wire.MarketplacesListAnswer{}
	json.Unmarshal(c.call(t, 6, "marketplaces/remove", map[string]any{"id": "personal:https://mcp.acme.example"}), &list)
	if len(list.Marketplaces) != 5 {
		t.Fatalf("%+v", list)
	}
}
