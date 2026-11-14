package agentsd

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"sort"
	"sync"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/skillcatalog"
	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Personas from a marketplace (#3665): searched in a GitHub marketplace's personas/ folder,
// shown whole, added to .agents/personas at one commit and named in the lock, and updated
// only when the person says so. A person's: an agent's own connection is never sent these.

var personaStagings sync.Map // *Daemon → *skillcatalog.PersonaStaging

func (d *Daemon) personaStaging() *skillcatalog.PersonaStaging {
	s, _ := personaStagings.LoadOrStore(d, &skillcatalog.PersonaStaging{})
	return s.(*skillcatalog.PersonaStaging)
}

func (d *Daemon) registerPersonaCatalog() {
	On(d, wire.CallPersonasSearch, func(ctx context.Context, c *Client, r wire.CatalogSearchRequest) (wire.CatalogSearchAnswer, error) {
		return d.personasSearch(ctx, r), nil
	})
	On(d, wire.CallPersonasPreview, func(ctx context.Context, c *Client, r wire.CatalogPreviewRequest) (wire.PersonaPreviewAnswer, error) {
		place, err := d.skillPlace(r.Destination)
		if err != nil {
			why := catalogWhy(err)
			return wire.PersonaPreviewAnswer{Error: &why}, nil
		}
		st, err := d.stagePersona(ctx, r.Result, place)
		if err != nil {
			log.Printf("catalog: persona preview %s failed: %v", r.Result.ID, err)
			why := catalogWhy(err)
			return wire.PersonaPreviewAnswer{Error: &why}, nil
		}
		return wire.PersonaPreviewAnswer{Preview: &st.Preview}, nil
	})
	On(d, wire.CallPersonasAdd, func(ctx context.Context, c *Client, r wire.SkillAddRequest) (wire.PersonaAddAnswer, error) {
		st, ok := d.personaStaging().Take(r.PreviewID)
		if !ok {
			return wire.PersonaAddAnswer{}, catalogRefusal(skillcatalog.PreviewExpired())
		}
		place, err := d.skillPlace(r.Destination)
		if err != nil {
			return wire.PersonaAddAnswer{}, catalogRefusal(err)
		}
		p, err := skillcatalog.PersonaInstaller{}.Add(st, place, r.Replace, nowFunc())
		if err != nil {
			log.Printf("catalog: add persona %s refused: %v", st.Preview.Persona.ID, err)
			return wire.PersonaAddAnswer{}, catalogRefusal(err)
		}
		log.Printf("catalog: add persona %s from %s @ %.7s → %s", p.ID, p.Source, st.Preview.Commit, personaPlaceName(place))
		return wire.PersonaAddAnswer{Persona: p}, nil
	})
	On(d, wire.CallPersonasManaged, func(ctx context.Context, c *Client, r wire.SkillsListRequest) (wire.PersonasManagedAnswer, error) {
		place, err := d.skillPlace(r.Destination)
		if err != nil {
			return wire.PersonasManagedAnswer{}, catalogRefusal(err)
		}
		out := []wire.ManagedPersona{}
		for _, p := range (skillcatalog.PersonaInstaller{}).Managed(place) {
			out = append(out, p)
		}
		sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
		return wire.PersonasManagedAnswer{Personas: out}, nil
	})
	On(d, wire.CallPersonasCheckUpdates, func(ctx context.Context, c *Client, r wire.SkillsListRequest) (wire.SkillUpdatesAnswer, error) {
		place, err := d.skillPlace(r.Destination)
		if err != nil {
			return wire.SkillUpdatesAnswer{}, catalogRefusal(err)
		}
		u := skillcatalog.Updates{GitHub: d.catalogGitHub(), Cache: d.catalog().updates}
		states := u.CheckPersonas(ctx, skillcatalog.PersonaInstaller{}.Managed(place), place, nowFunc())
		return wire.SkillUpdatesAnswer{Updates: states}, nil
	})
	On(d, wire.CallPersonasUpdatePreview, func(ctx context.Context, c *Client, r wire.SkillNameRequest) (wire.PersonaUpdatePreviewAnswer, error) {
		return d.personasUpdatePreview(ctx, r)
	})
	On(d, wire.CallPersonasRemove, func(ctx context.Context, c *Client, r wire.SkillNameRequest) (wire.SkillRemoveAnswer, error) {
		place, err := d.skillPlace(r.Destination)
		if err != nil {
			return wire.SkillRemoveAnswer{}, catalogRefusal(err)
		}
		trashed, err := skillcatalog.PersonaInstaller{}.Remove(r.Name, place, nowFunc())
		if err != nil {
			return wire.SkillRemoveAnswer{}, catalogRefusal(err)
		}
		log.Printf("catalog: remove persona %s → %s", r.Name, personaPlaceName(place))
		return wire.SkillRemoveAnswer{TrashedTo: trashed}, nil
	})
}

func personaPlaceName(place skillcatalog.Place) string {
	if place.Folder != "" {
		return "folder " + filepath.Base(place.Folder)
	}
	return "personal"
}

// personasSearch is a GitHub marketplace's personas. Only that format holds a repository's
// files; skills.sh lists skills alone.
func (d *Daemon) personasSearch(ctx context.Context, r wire.CatalogSearchRequest) wire.CatalogSearchAnswer {
	none := []wire.CatalogResult{}
	kind := wire.CatalogKindSkills
	var m wire.Marketplace
	found := false
	for _, each := range d.marketplacesList(&kind, r.Destination).Marketplaces {
		if each.Enabled && each.Format == wire.MarketplaceFormatGithubSkills && (r.Marketplace == nil || each.ID == *r.Marketplace) {
			m, found = each, true
			break
		}
	}
	if !found {
		return wire.CatalogSearchAnswer{Results: none,
			Error: &skillcatalog.Failed("That marketplace is turned off, not a GitHub repository, or no longer listed.").Why}
	}
	owner, repo, ok := skillcatalog.GitHubSource(m.URL)
	if !ok {
		return wire.CatalogSearchAnswer{Results: none, Error: &skillcatalog.Failed(m.URL + " is not a GitHub repository.").Why}
	}
	results, err := skillcatalog.GitHubSkills{GitHub: d.catalogGitHub(), Owner: owner, Repo: repo, Marketplace: m.ID}.
		SearchPersonas(ctx, r.Query)
	if err != nil {
		log.Printf("catalog: persona search %q failed: %v", r.Query, err)
		why := catalogWhy(err)
		return wire.CatalogSearchAnswer{Results: none, Error: &why}
	}
	log.Printf("catalog: persona search %q in %s → %d", r.Query, m.ID, len(results))
	return wire.CatalogSearchAnswer{Results: results}
}

func personaOrigin(place skillcatalog.Place) wire.PersonaOrigin {
	if place.Folder != "" {
		return wire.PersonaOriginFolder
	}
	return wire.PersonaOriginPersonal
}

// stagePersona fetches a persona, works out what is at the destination, and keeps it for
// personas/add.
func (d *Daemon) stagePersona(ctx context.Context, result wire.CatalogResult, place skillcatalog.Place) (skillcatalog.StagedPersona, error) {
	st, err := skillcatalog.StagePersona(ctx, d.catalogGitHub(), result, store.NewUUID(), personaOrigin(place), parsePersona, nowFunc())
	if err != nil {
		return st, err
	}
	st.Preview.DestinationState = skillcatalog.PersonaInstaller{}.State(st.Preview, place)
	d.personaStaging().Put(st)
	log.Printf("catalog: persona preview %s @ %.7s", result.ID, st.Preview.Commit)
	return st, nil
}

// personasUpdatePreview is the persona's source at its current commit, staged, with the file
// as it is now, whether it was edited since, and the runtime and permission mode it changes.
func (d *Daemon) personasUpdatePreview(ctx context.Context, r wire.SkillNameRequest) (wire.PersonaUpdatePreviewAnswer, error) {
	place, err := d.skillPlace(r.Destination)
	if err != nil {
		return wire.PersonaUpdatePreviewAnswer{}, catalogRefusal(err)
	}
	m, ok := skillcatalog.PersonaInstaller{}.Managed(place)[r.Name]
	owner, repo, okSource := skillcatalog.GitHubSource(m.Source)
	if !ok || !okSource {
		return wire.PersonaUpdatePreviewAnswer{}, catalogRefusal(skillcatalog.NotManaged(r.Name))
	}
	path := m.Path
	result := wire.CatalogResult{ID: owner + "/" + repo + "/" + path, Name: r.Name, Owner: owner, Repo: repo, SkillID: r.Name,
		Known: skillcatalog.KnownOwner(owner), SkillPath: &path}
	installed, err := os.ReadFile(filepath.Join(place.PersonaFolder(), r.Name+".md"))
	if err != nil {
		return wire.PersonaUpdatePreviewAnswer{}, catalogRefusal(skillcatalog.NotManaged(r.Name))
	}
	st, err := d.stagePersona(ctx, result, place)
	if err != nil {
		return wire.PersonaUpdatePreviewAnswer{}, catalogRefusal(err)
	}
	was := parsePersona(string(installed), r.Name, string(personaOrigin(place)))
	return wire.PersonaUpdatePreviewAnswer{Preview: st.Preview, Installed: string(installed), Edited: m.Edited,
		Changes: skillcatalog.PersonaSettingChanges(was.Settings, st.Preview.Persona.Settings)}, nil
}
