package agentsd

import (
	"slices"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Searching a catalogue, previewing a skill and adding it to the person or a folder, its
// updates, and the marketplaces searched (DaemonCore+Catalog, DaemonCore+Marketplaces).

// catalogState is a daemon's previews and update answers, kept beside it.
type catalogState struct {
	staging   *skillcatalog.Staging
	updates   *skillcatalog.UpdateCache
	recovered sync.Once
}

var catalogStates sync.Map // *Daemon → *catalogState

func (d *Daemon) catalog() *catalogState {
	if s, ok := catalogStates.Load(d); ok {
		return s.(*catalogState)
	}
	s, _ := catalogStates.LoadOrStore(d, &catalogState{
		staging: &skillcatalog.Staging{Root: filepath.Join(d.Store.Loc.Cache, "catalog-staging")},
		updates: &skillcatalog.UpdateCache{}})
	cs := s.(*catalogState)
	// An add the last daemon died in the middle of is undone before anything else.
	cs.recovered.Do(func() {
		if undone := d.skillInstaller().Recover(); undone != "" {
			log.Printf("catalog: %s", undone)
		}
	})
	return cs
}

var catalogHTTP = &http.Client{Timeout: skillcatalog.Timeout}

func (d *Daemon) catalogEndpoints() skillcatalog.Endpoints {
	return skillcatalog.EndpointsFrom(os.Getenv)
}

func (d *Daemon) catalogGitHub() skillcatalog.GitHub {
	return skillcatalog.GitHub{Client: catalogHTTP, Endpoints: d.catalogEndpoints(), GH: personsGH}
}

// personsGH is the person's own gh, signed in or not: its sign-in is gh's, a token the
// daemon never holds.
func personsGH(ctx context.Context, path string) ([]byte, error) {
	gh := ""
	for _, dir := range searchPaths() {
		if info, err := os.Stat(filepath.Join(dir, "gh")); err == nil && info.Mode()&0o111 != 0 {
			gh = filepath.Join(dir, "gh")
			break
		}
	}
	if gh == "" {
		return nil, errors.New("gh is not installed")
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, gh, "api", "--hostname", "github.com", "-X", "GET", path)
	cmd.Env = append(os.Environ(), "GH_PROMPT_DISABLED=1", "GH_NO_UPDATE_NOTIFIER=1", "NO_COLOR=1")
	var out, errs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errs
	if err := cmd.Run(); err != nil {
		said, _, _ := strings.Cut(errs.String(), "\n")
		return nil, fmt.Errorf("gh: %s", said)
	}
	return out.Bytes(), nil
}

func (d *Daemon) registerCatalog() {
	// Skills answer a CatalogSearchAnswer, MCP servers an MCPSearchAnswer.
	On(d, wire.CallCatalogSearch, func(ctx context.Context, c *Client, r wire.CatalogSearchRequest) (wire.JSONValue, error) {
		var answer any = d.catalogSearch(ctx, r)
		if r.Kind != nil && *r.Kind == wire.CatalogKindMCP {
			answer = d.mcpCatalogSearch(ctx, r)
		}
		return json.Marshal(answer)
	})
	On(d, wire.CallCatalogPreview, func(ctx context.Context, c *Client, r wire.CatalogPreviewRequest) (wire.CatalogPreviewAnswer, error) {
		return d.catalogPreview(ctx, r), nil
	})
	On(d, wire.CallCatalogDestinationState, func(ctx context.Context, c *Client, r wire.DestinationStateRequest) (wire.DestinationStateAnswer, error) {
		st, ok := d.catalog().staging.Get(r.PreviewID)
		if !ok {
			return wire.DestinationStateAnswer{}, catalogRefusal(skillcatalog.PreviewExpired())
		}
		return wire.DestinationStateAnswer{DestinationState: d.destinationState(st.Preview, r.Destination)}, nil
	})
	On(d, wire.CallSkillsAdd, func(ctx context.Context, c *Client, r wire.SkillAddRequest) (wire.SkillAddAnswer, error) {
		return d.skillsAdd(r)
	})
	On(d, wire.CallSkillsCheckUpdates, func(ctx context.Context, c *Client, r wire.SkillsListRequest) (wire.SkillUpdatesAnswer, error) {
		place, err := d.skillPlace(r.Destination)
		if err != nil {
			return wire.SkillUpdatesAnswer{}, catalogRefusal(err)
		}
		in := d.skillInstaller()
		u := skillcatalog.Updates{GitHub: d.catalogGitHub(), Sidecar: in.Sidecar, Cache: d.catalog().updates}
		states := u.Check(ctx, in.Managed(place), place, nowFunc())
		var available []string
		for name, s := range states {
			if s.Available != nil {
				available = append(available, name)
			}
		}
		log.Printf("catalog: update-check %d skills → available: %v", len(states), available)
		return wire.SkillUpdatesAnswer{Updates: states}, nil
	})
	On(d, wire.CallSkillsUpdatePreview, func(ctx context.Context, c *Client, r wire.SkillNameRequest) (wire.SkillUpdatePreviewAnswer, error) {
		return d.skillsUpdatePreview(ctx, r)
	})
	On(d, wire.CallMarketplacesList, func(ctx context.Context, c *Client, r wire.MarketplacesListRequest) (wire.MarketplacesListAnswer, error) {
		return d.marketplacesList(r.Kind, r.Destination), nil
	})
	On(d, wire.CallMarketplacesAdd, func(ctx context.Context, c *Client, r wire.MarketplaceAddRequest) (wire.MarketplacesListAnswer, error) {
		return d.marketplacesAdd(r)
	})
	On(d, wire.CallMarketplacesRemove, func(ctx context.Context, c *Client, r wire.MarketplaceIDRequest) (wire.MarketplacesListAnswer, error) {
		return d.marketplacesRemove(r.ID)
	})
	On(d, wire.CallMarketplacesSetEnabled, func(ctx context.Context, c *Client, r wire.MarketplaceSetEnabledRequest) (wire.MarketplacesListAnswer, error) {
		return d.marketplacesSetEnabled(r)
	})
}

// MARK: catalog/search

func (d *Daemon) catalogSearch(ctx context.Context, r wire.CatalogSearchRequest) wire.CatalogSearchAnswer {
	kind := wire.CatalogKindSkills
	if r.Kind != nil {
		kind = *r.Kind
	}
	none := []wire.CatalogResult{}
	m, ok := d.marketplace(r.Marketplace, kind, r.Destination)
	if !ok {
		why := "That marketplace is turned off, or no longer listed."
		if r.Marketplace == nil {
			why = "Every skills marketplace is turned off."
		}
		return wire.CatalogSearchAnswer{Results: none, Error: &skillcatalog.Failed(why).Why}
	}
	var results []wire.CatalogResult
	var err error
	switch m.Format {
	case wire.MarketplaceFormatGithubSkills:
		owner, repo, ok := skillcatalog.GitHubSource(m.URL)
		if !ok {
			return wire.CatalogSearchAnswer{Results: none, Error: &skillcatalog.Failed(m.URL + " is not a GitHub repository.").Why}
		}
		results, err = skillcatalog.GitHubSkills{GitHub: d.catalogGitHub(), Owner: owner, Repo: repo, Marketplace: m.ID}.Search(ctx, r.Query)
	default:
		results, err = skillcatalog.SkillsSh{Client: catalogHTTP, Base: m.URL}.Search(ctx, r.Query)
		for i := range results {
			id := m.ID
			results[i].Marketplace = &id
		}
	}
	if err != nil {
		log.Printf("catalog: search %q failed: %v", r.Query, err)
		why := catalogWhy(err)
		return wire.CatalogSearchAnswer{Results: none, Error: &why}
	}
	log.Printf("catalog: search %q in %s → %d", r.Query, m.ID, len(results))
	return wire.CatalogSearchAnswer{Results: results}
}

func catalogWhy(err error) wire.CatalogError {
	var ce *skillcatalog.Error
	if errors.As(err, &ce) {
		return ce.Why
	}
	return skillcatalog.Failed(err.Error()).Why
}

// MARK: catalog/preview

// previewCatalog is skills.sh, for its copy of a skill's files, only when the skill was
// found there.
func (d *Daemon) previewCatalog(result wire.CatalogResult, dest wire.SkillDestination) *skillcatalog.SkillsSh {
	if result.Marketplace == nil && !d.marketplaceAllowed(skillcatalog.SkillsShID, "") {
		return nil
	}
	if result.Marketplace == nil {
		return &skillcatalog.SkillsSh{Client: catalogHTTP, Base: d.catalogEndpoints().Catalog}
	}
	kind := wire.CatalogKindSkills
	for _, m := range d.marketplacesList(&kind, &dest).Marketplaces {
		if m.ID == *result.Marketplace && m.Format == wire.MarketplaceFormatSkillsSh {
			return &skillcatalog.SkillsSh{Client: catalogHTTP, Base: m.URL}
		}
	}
	return nil
}

func (d *Daemon) catalogPreview(ctx context.Context, r wire.CatalogPreviewRequest) wire.CatalogPreviewAnswer {
	staging := d.catalog().staging
	id := store.NewUUID()
	folder := staging.FolderFor(id)
	p := skillcatalog.Previewer{Catalog: d.previewCatalog(r.Result, r.Destination), GitHub: d.catalogGitHub()}
	st, err := p.Stage(ctx, r.Result, folder, id, nowFunc())
	if err != nil {
		os.RemoveAll(folder)
		log.Printf("catalog: preview %s failed: %v", r.Result.ID, err)
		why := catalogWhy(err)
		return wire.CatalogPreviewAnswer{Error: &why}
	}
	st.Preview.DestinationState = d.destinationState(st.Preview, r.Destination)
	staging.Put(st)
	log.Printf("catalog: preview %s @ %.7s", r.Result.ID, st.Preview.Commit)
	return wire.CatalogPreviewAnswer{Preview: &st.Preview}
}

func (d *Daemon) destinationState(p wire.SkillPreview, dest wire.SkillDestination) wire.DestinationState {
	place, err := d.skillPlace(dest)
	if err != nil {
		return wire.DestinationState{Unavailable: &wire.DestinationStateUnavailable{Value: catalogWhy(err)}}
	}
	return d.skillInstaller().State(p, place)
}

// MARK: skills/add

func (d *Daemon) skillsAdd(r wire.SkillAddRequest) (wire.SkillAddAnswer, error) {
	staging := d.catalog().staging
	st, ok := staging.Take(r.PreviewID)
	if !ok {
		return wire.SkillAddAnswer{}, catalogRefusal(skillcatalog.PreviewExpired())
	}
	defer staging.Discard(r.PreviewID)
	place, err := d.skillPlace(r.Destination)
	if err != nil {
		return wire.SkillAddAnswer{}, catalogRefusal(err)
	}
	skill, err := d.skillInstaller().Add(st, place, r.Replace, nowFunc())
	if err != nil {
		log.Printf("catalog: add %s refused: %v", st.Preview.Name, err)
		return wire.SkillAddAnswer{}, catalogRefusal(err)
	}
	where := "personal"
	if place.Folder != "" {
		where = "folder " + filepath.Base(place.Folder)
	}
	log.Printf("catalog: add %s from %s @ %.7s → %s", skill.Name, skill.Source, st.Preview.Commit, where)
	return wire.SkillAddAnswer{Skill: skill}, nil
}

// MARK: skills/update-preview

// skillsUpdatePreview is the skill's source at its current commit, staged as a preview, with
// what it would change in the installed folder and whether that folder was edited since.
func (d *Daemon) skillsUpdatePreview(ctx context.Context, r wire.SkillNameRequest) (wire.SkillUpdatePreviewAnswer, error) {
	place, err := d.skillPlace(r.Destination)
	if err != nil {
		return wire.SkillUpdatePreviewAnswer{}, catalogRefusal(err)
	}
	in := d.skillInstaller()
	m, ok := in.Managed(place)[r.Name]
	owner, repo, okSource := skillcatalog.GitHubSource(m.Source)
	if !ok || !okSource {
		return wire.SkillUpdatePreviewAnswer{}, catalogRefusal(skillcatalog.NotManaged(r.Name))
	}
	folderPath := ""
	if m.SkillPath != nil {
		folderPath = strings.TrimSuffix(*m.SkillPath, "SKILL.md")
	}
	parts := strings.Split(strings.Trim(folderPath, "/"), "/")
	skillID := r.Name
	if last := parts[len(parts)-1]; last != "" {
		skillID = last
	}
	result := wire.CatalogResult{ID: owner + "/" + repo + "/" + skillID, Name: r.Name, Owner: owner, Repo: repo,
		SkillID: skillID, Known: skillcatalog.KnownOwner(owner)}
	staging := d.catalog().staging
	id := store.NewUUID()
	p := skillcatalog.Previewer{Catalog: &skillcatalog.SkillsSh{Client: catalogHTTP, Base: d.catalogEndpoints().Catalog},
		GitHub: d.catalogGitHub()}
	st, err := p.Stage(ctx, result, staging.FolderFor(id), id, nowFunc())
	if err != nil {
		return wire.SkillUpdatePreviewAnswer{}, catalogRefusal(err)
	}
	st.Preview.DestinationState = in.State(st.Preview, place)
	staging.Put(st)
	changes := skillcatalog.Changes(filepath.Join(place.Skills, r.Name), st.Folder)
	log.Printf("catalog: update-preview %s @ %.7s", r.Name, st.Preview.Commit)
	return wire.SkillUpdatePreviewAnswer{Preview: st.Preview, Changes: changes, Edited: m.Edited}, nil
}

// MARK: marketplaces

func (d *Daemon) marketplacesList(kind *wire.CatalogKind, dest *wire.SkillDestination) wire.MarketplacesListAnswer {
	var problem *string
	var personal skillcatalog.MarketplaceFile
	home := d.personalHome()
	if home != "" {
		f, err := skillcatalog.LoadMarketplaces(skillcatalog.PersonalMarketplaces(home))
		if err != nil {
			s := err.Error()
			problem = &s
		}
		personal = f
	}
	var folder *skillcatalog.MarketplaceFile
	if dest != nil && dest.Kind == wire.SkillDestinationKindFolder {
		if place, err := d.skillPlace(*dest); err == nil {
			f, err := skillcatalog.LoadMarketplaces(skillcatalog.FolderMarketplaces(place.Folder))
			if err != nil && problem == nil {
				s := err.Error()
				problem = &s
			}
			folder = &f
		}
	}
	secrets := skillcatalog.Secrets{}
	if home != "" {
		secrets = skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home))
	}
	// A marketplace the organisation does not allow is not listed (#998, US3 scenario 1),
	// so nothing is searched, previewed or added from it.
	listed := slices.DeleteFunc(skillcatalog.ListMarketplaces(kind, personal, folder, secrets.IsSet, os.Getenv),
		func(m wire.Marketplace) bool { return !d.marketplaceAllowed(m.ID, m.URL) })
	return wire.MarketplacesListAnswer{Marketplaces: listed, Problem: problem}
}

// marketplace is the one a search names, if it is on; else the first on for the kind.
func (d *Daemon) marketplace(id *string, kind wire.CatalogKind, dest *wire.SkillDestination) (wire.Marketplace, bool) {
	for _, m := range d.marketplacesList(&kind, dest).Marketplaces {
		if m.Enabled && (id == nil || m.ID == *id) {
			return m, true
		}
	}
	return wire.Marketplace{}, false
}

func marketplaceRefusal(message string) error {
	return &Error{Code: wire.FailureCatalogRefused, Message: message, Data: skillcatalog.Failed(message).Why}
}

func (d *Daemon) marketplaceFile() (string, skillcatalog.MarketplaceFile, error) {
	home := d.personalHome()
	if home == "" {
		return "", skillcatalog.MarketplaceFile{}, marketplaceRefusal("This copy of the app has no ~/.agents of its own.")
	}
	path := skillcatalog.PersonalMarketplaces(home)
	f, err := skillcatalog.LoadMarketplaces(path)
	if err != nil {
		return "", f, marketplaceRefusal(err.Error())
	}
	return path, f, nil
}

func (d *Daemon) marketplacesAdd(r wire.MarketplaceAddRequest) (wire.MarketplacesListAnswer, error) {
	if url := skillcatalog.Normalized(r.URL); !d.marketplaceAllowed(skillcatalog.MarketplaceID(wire.MarketplaceOriginPersonal, url), url) {
		return wire.MarketplacesListAnswer{}, policyRefusal("policy", "marketplaces", marketplaceRefusalWords(), nil)
	}
	path, f, err := d.marketplaceFile()
	if err != nil {
		return wire.MarketplacesListAnswer{}, err
	}
	if problem := skillcatalog.MarketplaceProblem(r); problem != "" {
		return wire.MarketplacesListAnswer{}, marketplaceRefusal(problem)
	}
	address := skillcatalog.Normalized(r.URL)
	for _, e := range f.Marketplaces {
		if skillcatalog.Normalized(e.URL) == address {
			return wire.MarketplacesListAnswer{}, marketplaceRefusal("You have a marketplace at " + address + " already.")
		}
	}
	var token *string
	if r.Token != nil && strings.TrimSpace(*r.Token) != "" {
		t := strings.TrimSpace(*r.Token)
		token = &t
		if r.TokenValue != nil && *r.TokenValue != "" {
			secretsPath := skillcatalog.SecretsPath(d.personalHome())
			secrets, err := skillcatalog.LoadSecretsForChange(secretsPath)
			if err != nil {
				return wire.MarketplacesListAnswer{}, marketplaceRefusal(err.Error())
			}
			secrets.Set(t, *r.TokenValue)
			if err := secrets.Save(secretsPath); err != nil {
				return wire.MarketplacesListAnswer{}, marketplaceRefusal("secrets.env could not be written: " + err.Error())
			}
		}
	}
	f.Marketplaces = append(f.Marketplaces, skillcatalog.MarketplaceEntry{Name: strings.TrimSpace(r.Name), Format: r.Format,
		URL: address, Token: token})
	if err := skillcatalog.SaveMarketplaces(f, path); err != nil {
		return wire.MarketplacesListAnswer{}, marketplaceRefusal("marketplaces.json could not be written: " + err.Error())
	}
	log.Printf("marketplaces: added %s %s", r.Format, address)
	kind := skillcatalog.KindOf(r.Format)
	return d.marketplacesList(&kind, nil), nil
}

// marketplacesRemove takes out one of the person's own; the token's value stays in
// secrets.env, where something else may use it.
func (d *Daemon) marketplacesRemove(id string) (wire.MarketplacesListAnswer, error) {
	path, f, err := d.marketplaceFile()
	if err != nil {
		return wire.MarketplacesListAnswer{}, err
	}
	var kept []skillcatalog.MarketplaceEntry
	for _, e := range f.Marketplaces {
		if skillcatalog.MarketplaceID(wire.MarketplaceOriginPersonal, e.URL) != id {
			kept = append(kept, e)
		}
	}
	if len(kept) == len(f.Marketplaces) {
		return wire.MarketplacesListAnswer{}, marketplaceRefusal("Only a marketplace of your own can be removed; the others can be turned off.")
	}
	f.Marketplaces = kept
	skillcatalog.SetEnabled(id, false, true, &f)
	if err := skillcatalog.SaveMarketplaces(f, path); err != nil {
		return wire.MarketplacesListAnswer{}, marketplaceRefusal("marketplaces.json could not be written: " + err.Error())
	}
	log.Printf("marketplaces: removed one")
	return d.marketplacesList(nil, nil), nil
}

func (d *Daemon) marketplacesSetEnabled(r wire.MarketplaceSetEnabledRequest) (wire.MarketplacesListAnswer, error) {
	if r.Enabled && !d.marketplaceAllowed(r.ID, "") {
		return wire.MarketplacesListAnswer{}, policyRefusal("policy", "marketplaces", marketplaceRefusalWords(), nil)
	}
	path, f, err := d.marketplaceFile()
	if err != nil {
		return wire.MarketplacesListAnswer{}, err
	}
	// A folder's is known by its id alone: the person turns on what the list showed them.
	skillcatalog.SetEnabled(r.ID, strings.HasPrefix(r.ID, "folder:"), r.Enabled, &f)
	if err := skillcatalog.SaveMarketplaces(f, path); err != nil {
		return wire.MarketplacesListAnswer{}, marketplaceRefusal("marketplaces.json could not be written: " + err.Error())
	}
	state := "off"
	if r.Enabled {
		state = "on"
	}
	log.Printf("marketplaces: %s %s", state, r.ID)
	return d.marketplacesList(nil, nil), nil
}
