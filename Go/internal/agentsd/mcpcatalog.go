package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// MCP servers from a registry, and the person's and a folder's mcp.json as the pane shows
// them: listed with their approval and missing secrets, approved, added, taken out, a secret
// set, and a server's view answers forgotten (DaemonCore+MCPCatalog).

func (d *Daemon) registerMCPCatalog() {
	On(d, wire.CallMCPPreview, func(ctx context.Context, c *Client, r wire.MCPPreviewRequest) (wire.MCPPreviewAnswer, error) {
		return d.mcpPreview(ctx, r), nil
	})
	On(d, wire.CallMCPAdd, func(ctx context.Context, c *Client, r wire.MCPAddRequest) (wire.MCPAddAnswer, error) {
		return d.mcpAdd(r)
	})
	On(d, wire.CallMCPList, func(ctx context.Context, c *Client, r wire.MCPListRequest) (wire.MCPListAnswer, error) {
		return d.mcpList(r.Destination)
	})
	On(d, wire.CallMCPApprove, func(ctx context.Context, c *Client, r wire.MCPApproveRequest) (wire.MCPListAnswer, error) {
		return d.mcpApprove(r)
	})
	On(d, wire.CallMCPForgetViews, func(ctx context.Context, c *Client, r wire.MCPViewsForgetRequest) (wire.Empty, error) {
		return wire.Empty{}, d.mcpForgetViews(r)
	})
	On(d, wire.CallMCPSetSecret, func(ctx context.Context, c *Client, r wire.MCPSetSecretRequest) (wire.MCPSetSecretAnswer, error) {
		return d.mcpSetSecret(r)
	})
	On(d, wire.CallMCPRemove, func(ctx context.Context, c *Client, r wire.MCPRemoveRequest) (wire.MCPRemoveAnswer, error) {
		return d.mcpRemove(r)
	})
}

// mcpRefusal is -32080 with the reason, as the sheet reads it.
func mcpRefusal(err error) error {
	var me *mcpcatalog.Error
	if !errors.As(err, &me) {
		me = mcpcatalog.Failed(err.Error())
	}
	return &Error{Code: wire.FailureCatalogRefused, Message: me.Error(), Data: me.Why}
}

func mcpWhy(err error) wire.MCPCatalogError {
	var me *mcpcatalog.Error
	if errors.As(err, &me) {
		return me.Why
	}
	return mcpcatalog.Failed(err.Error()).Why
}

// mcpChanged has the health checks look again, as a change to mcp.json or a secret can
// make a server answer or stop, and says every folder's pins again, whose server views
// (#2032) may have come or gone.
func (d *Daemon) mcpChanged() {
	safe.Go("mcp health", d.reconcileMCPHealth)
	for _, s := range d.folders(false) {
		d.pinsChanged(store.FolderPath(s.Folder.Folder))
	}
}

func (d *Daemon) mcpSidecarPath() string { return filepath.Join(d.Store.Loc.Root, "catalog-mcp.json") }

// mcpFile is where a destination's mcp.json is.
func (d *Daemon) mcpFile(dest wire.SkillDestination) (string, error) {
	if dest.Kind == wire.SkillDestinationKindFolder && dest.Folder != nil {
		return mcpcatalog.FolderFile(*dest.Folder), nil
	}
	home := d.personalHome()
	if home == "" {
		return "", mcpcatalog.NoPersonalHome()
	}
	return mcpcatalog.PersonalFile(home), nil
}

// requireMCPFolder: a folder destination has to be a folder here. Personal is fine.
func (d *Daemon) requireMCPFolder(dest wire.SkillDestination) error {
	if dest.Kind != wire.SkillDestinationKindFolder {
		return nil
	}
	path := ""
	if dest.Folder != nil {
		path = *dest.Folder
	}
	if info, err := os.Stat(path); path == "" || err != nil || !info.IsDir() || !d.isFolderPath(path) {
		return mcpcatalog.NotAFolder(path)
	}
	return nil
}

// whichTool is whether a program is on this host's PATH, for the ways a server can run.
func whichTool(name string) bool {
	for _, dir := range searchPaths() {
		if info, err := os.Stat(filepath.Join(dir, name)); err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
			return true
		}
	}
	return false
}

func mcpTools() mcpcatalog.Tools {
	return mcpcatalog.Tools{Npx: whichTool("npx"), Uvx: whichTool("uvx"), Docker: whichTool("docker")}
}

// mcpRegistry is a marketplace's registry, its token filled from secrets.env.
func (d *Daemon) mcpRegistry(m *wire.Marketplace) mcpcatalog.Registry {
	r := mcpcatalog.Registry{Client: catalogHTTPLong, Base: os.Getenv(skillcatalog.RegistryVariable)}
	if m == nil {
		return r
	}
	r.Base = m.URL
	if m.Token != nil && d.personalHome() != "" {
		r.Token, _ = skillcatalog.LoadSecrets(skillcatalog.SecretsPath(d.personalHome())).Value(*m.Token)
	}
	return r
}

// catalogHTTPLong is for a registry, which waits a minute (its own deadline) over a search.
var catalogHTTPLong = &http.Client{}

// mcpCatalogSearch is catalog/search for MCP servers, in the marketplace named or the first
// one on.
func (d *Daemon) mcpCatalogSearch(ctx context.Context, r wire.CatalogSearchRequest) wire.MCPSearchAnswer {
	none := []wire.MCPCatalogResult{}
	m, ok := d.marketplace(r.Marketplace, wire.CatalogKindMCP, r.Destination)
	if !ok {
		why := "That marketplace is turned off, or no longer listed."
		if r.Marketplace == nil {
			why = "Every MCP marketplace is turned off."
		}
		return wire.MCPSearchAnswer{Results: none, Error: &mcpcatalog.Failed(why).Why}
	}
	var results []wire.MCPCatalogResult
	var err error
	if m.Format == wire.MarketplaceFormatFile {
		results, err = d.fileMarketplace(m, r.Destination).Search(r.Query, mcpTools(), d.declaredBy)
	} else {
		results, err = d.mcpRegistry(&m).Search(ctx, r.Query, mcpTools())
	}
	if err != nil {
		log.Printf("mcp: search %q failed: %v", r.Query, err)
		why := mcpWhy(err)
		return wire.MCPSearchAnswer{Results: none, Error: &why}
	}
	for i := range results {
		id := m.ID
		results[i].Marketplace = &id
	}
	log.Printf("mcp: search %q in %s → %d", r.Query, m.ID, len(results))
	return wire.MCPSearchAnswer{Results: results}
}

// fileMarketplace is a marketplace of the format file (#2155): the Agents one inside agentsd,
// or a path, from ~/ or, when relative, from the home (a person's) or the folder.
func (d *Daemon) fileMarketplace(m wire.Marketplace, dest *wire.SkillDestination) mcpcatalog.FileMarketplace {
	if m.Origin == wire.MarketplaceOriginProvided && m.URL == skillcatalog.AgentsMarketplaceFile {
		return mcpcatalog.FileMarketplace{Builtin: true}
	}
	path, home := m.URL, d.personalHome()
	switch {
	case strings.HasPrefix(path, "~/") && home != "":
		path = filepath.Join(home, path[2:])
	case filepath.IsAbs(path):
	case m.Origin == wire.MarketplaceOriginFolder && dest != nil:
		if place, err := d.skillPlace(*dest); err == nil {
			path = filepath.Join(place.Folder, path)
		}
	case home != "":
		path = filepath.Join(home, path)
	}
	return mcpcatalog.FileMarketplace{Path: path}
}

// declaredBy is what a checked copy of one of ours declared, or what it is written to declare.
func (d *Daemon) declaredBy(o mcpcatalog.Ours) mcpcatalog.Declared {
	d.healthMu.Lock()
	defer d.healthMu.Unlock()
	for _, kept := range d.results {
		if kept.ours == o.ID && kept.check == wire.MCPCheckStateAnswered {
			return kept.declared
		}
	}
	return o.Declares
}

// mcpStaged is a preview waiting to be added, for half an hour.
type mcpStaged struct {
	preview      wire.MCPPreview
	entry        skillcatalog.Value
	registryName string
	version      string
	until        time.Time
}

var mcpPreviews = struct {
	sync.Mutex
	m map[wire.UUID]mcpStaged
}{m: map[wire.UUID]mcpStaged{}}

func (d *Daemon) mcpPreview(ctx context.Context, r wire.MCPPreviewRequest) wire.MCPPreviewAnswer {
	fail := func(err error) wire.MCPPreviewAnswer {
		log.Printf("mcp: preview %s failed: %v", r.Result.ID, err)
		why := mcpWhy(err)
		return wire.MCPPreviewAnswer{Error: &why}
	}
	if r.Destination.Kind == wire.SkillDestinationKindPersonal && d.personalHome() == "" {
		return fail(mcpcatalog.NoPersonalHome())
	}
	if _, ours := mcpcatalog.OursByID(r.Result.ID); !ours && r.Result.Marketplace == nil && !d.marketplaceAllowed("", "") {
		return fail(errors.New(orgSetBy + " " + marketplaceRefusalWords()))
	}
	var market *wire.Marketplace
	if r.Result.Marketplace != nil {
		if m, ok := d.marketplace(r.Result.Marketplace, wire.CatalogKindMCP, &r.Destination); ok {
			market = &m
		}
	}
	secrets := skillcatalog.Secrets{}
	if home := d.personalHome(); home != "" {
		secrets = skillcatalog.LoadSecrets(skillcatalog.SecretsPath(home))
	}
	if o, ours := mcpcatalog.OursByID(r.Result.ID); ours && (market == nil || market.ID == mcpcatalog.AgentsMarketplace) {
		return d.stageMCPPreview(r, mcpcatalog.BuildOurs(o, secrets.IsSet), o.ID, "")
	}
	var server mcpcatalog.Server
	var err error
	if market != nil && market.Format == wire.MarketplaceFormatFile {
		var ours *mcpcatalog.Ours
		server, ours, err = d.fileMarketplace(*market, &r.Destination).Detail(r.Result.ID)
		if err == nil && ours != nil {
			return d.stageMCPPreview(r, mcpcatalog.BuildOurs(*ours, secrets.IsSet), ours.ID, "")
		}
	} else {
		server, err = d.mcpRegistry(market).Detail(ctx, r.Result.ID)
	}
	if err != nil {
		return fail(err)
	}
	runs := mcpcatalog.AvailableRuns(server, mcpTools())
	var chosen wire.MCPRunKind
	switch {
	case r.Run != nil:
		chosen = *r.Run
	case len(runs.Available) > 0:
		chosen = runs.Available[0]
	default:
		return fail(mcpcatalog.NoRunnableWay())
	}
	built, err := mcpcatalog.Build(server, chosen, secrets.IsSet)
	if err != nil {
		return fail(err)
	}
	version := r.Result.Version
	if server.Version != nil {
		version = *server.Version
	}
	return d.stageMCPPreview(r, built, server.Name, version)
}

// stageMCPPreview keeps a built entry for half an hour, for mcp/add.
func (d *Daemon) stageMCPPreview(r wire.MCPPreviewRequest, built mcpcatalog.Built, registryName, version string) wire.MCPPreviewAnswer {
	fail := func(err error) wire.MCPPreviewAnswer {
		log.Printf("mcp: preview %s failed: %v", r.Result.ID, err)
		why := mcpWhy(err)
		return wire.MCPPreviewAnswer{Error: &why}
	}
	state, err := d.mcpDestinationState(built.NameHere, registryName, r.Destination)
	if err != nil {
		return fail(err)
	}
	problems := []wire.MCPPreviewProblem{}
	if state.Unmanaged != nil {
		problems = append(problems, wire.MCPPreviewProblem{NameTakenUnmanaged: &struct{}{}})
	}
	entry := map[string]wire.JSONValue{}
	for _, p := range built.Entry.Pairs {
		entry[p.Key] = wire.JSONValue(p.Value.Stringified())
	}
	preview := wire.MCPPreview{PreviewID: store.NewUUID(), Result: r.Result, NameHere: built.NameHere, ChosenRun: built.ChosenRun,
		CommandOrURL: built.CommandOrURL, Host: built.Host, Entry: entry, Variables: built.Variables,
		Reach: map[string]wire.JSONValue{}, DestinationState: state, Problems: problems}
	mcpPreviews.Lock()
	for id, s := range mcpPreviews.m {
		if time.Now().After(s.until) {
			delete(mcpPreviews.m, id)
		}
	}
	mcpPreviews.m[preview.PreviewID] = mcpStaged{preview: preview, entry: built.Entry, registryName: registryName,
		version: version, until: time.Now().Add(30 * time.Minute)}
	mcpPreviews.Unlock()
	log.Printf("mcp: preview %s as %s via %s", registryName, built.NameHere, built.ChosenRun)
	return wire.MCPPreviewAnswer{Preview: &preview}
}

// mcpDestinationState is what is at the destination already under the name.
func (d *Daemon) mcpDestinationState(nameHere, registryName string, dest wire.SkillDestination) (wire.MCPDestinationState, error) {
	path, err := d.mcpFile(dest)
	if err != nil {
		return wire.MCPDestinationState{}, err
	}
	record, managed := mcpcatalog.LoadSidecar(d.mcpSidecarPath()).Servers[mcpcatalog.Key(dest, nameHere)]
	_, there, err := mcpcatalog.Entry(path, nameHere)
	if err != nil {
		return wire.MCPDestinationState{}, mcpcatalog.Unreadable(path)
	}
	switch {
	case managed && record.RegistryName == registryName:
		return wire.MCPDestinationState{ManagedSame: &struct{}{}}, nil
	case managed:
		return wire.MCPDestinationState{ManagedOther: &wire.MCPDestinationStateManagedOther{RegistryName: record.RegistryName}}, nil
	case there:
		return wire.MCPDestinationState{Unmanaged: &wire.MCPDestinationStateUnmanaged{Path: path}}, nil
	}
	return wire.MCPDestinationState{Free: &struct{}{}}, nil
}

func (d *Daemon) mcpAdd(r wire.MCPAddRequest) (wire.MCPAddAnswer, error) {
	if err := d.requireMCPFolder(r.Destination); err != nil {
		return wire.MCPAddAnswer{}, mcpRefusal(err)
	}
	mcpPreviews.Lock()
	st, ok := mcpPreviews.m[r.PreviewID]
	delete(mcpPreviews.m, r.PreviewID)
	mcpPreviews.Unlock()
	if !ok || time.Now().After(st.until) {
		return wire.MCPAddAnswer{}, mcpRefusal(mcpcatalog.PreviewExpired())
	}
	server, err := d.mcpInstall(st, r)
	if err != nil {
		log.Printf("mcp: add refused: %v", err)
		return wire.MCPAddAnswer{}, mcpRefusal(err)
	}
	log.Printf("mcp: add %s from %s @ %s", server.Name, server.RegistryName, server.Version)
	d.mcpChanged()
	return wire.MCPAddAnswer{Server: &server}, nil
}

// mcpInstall is MCPInstaller.add: its secrets into secrets.env, the entry into mcp.json, the
// sidecar's record, and for a folder, the entry approved as it was written.
func (d *Daemon) mcpInstall(st mcpStaged, r wire.MCPAddRequest) (wire.ManagedMCPServer, error) {
	home := d.personalHome()
	if home == "" {
		return wire.ManagedMCPServer{}, mcpcatalog.NoPersonalHome()
	}
	path, err := d.mcpFile(r.Destination)
	if err != nil {
		return wire.ManagedMCPServer{}, err
	}
	name := st.preview.NameHere
	state, err := d.mcpDestinationState(name, st.registryName, r.Destination)
	if err != nil {
		return wire.ManagedMCPServer{}, err
	}
	switch {
	case state.Unmanaged != nil:
		return wire.ManagedMCPServer{}, mcpcatalog.Unmanaged(state.Unmanaged.Path)
	case (state.ManagedSame != nil || state.ManagedOther != nil) && !r.Replace:
		return wire.ManagedMCPServer{}, mcpcatalog.ReplaceMismatch()
	}
	secretsPath := skillcatalog.SecretsPath(home)
	env, err := skillcatalog.LoadSecretsForChange(secretsPath)
	if err != nil {
		return wire.ManagedMCPServer{}, mcpcatalog.Failed(err.Error())
	}
	for _, v := range st.preview.Variables {
		if v.Kind != wire.MCPVariableKindSecret || !v.Required {
			continue
		}
		if value := r.Secrets[v.Name]; value != "" {
			env.Set(v.Name, value)
		} else if !env.IsSet(v.Name) {
			return wire.ManagedMCPServer{}, mcpcatalog.MissingSecret(v.Name)
		}
	}
	names := make([]string, 0, len(r.Secrets))
	for n := range r.Secrets {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		if r.Secrets[n] != "" {
			env.Set(n, r.Secrets[n])
		}
	}
	if err := env.Save(secretsPath); err != nil {
		return wire.ManagedMCPServer{}, mcpcatalog.Failed("secrets.env could not be written")
	}
	entry := st.entry
	if len(r.Plain) > 0 {
		envObj, ok := entry.Get("env")
		if !ok {
			envObj = skillcatalog.Object()
		}
		keys := make([]string, 0, len(r.Plain))
		for k := range r.Plain {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			envObj.Set(k, skillcatalog.String(r.Plain[k]))
		}
		entry.Set("env", envObj)
	}
	if err := mcpcatalog.Upsert(path, name, entry); err != nil {
		return wire.ManagedMCPServer{}, mcpcatalog.Unreadable(path)
	}
	addedAt := nowFunc()
	side := mcpcatalog.LoadSidecar(d.mcpSidecarPath())
	side.Servers[mcpcatalog.Key(r.Destination, name)] = mcpcatalog.Record{RegistryName: st.registryName, Version: st.version,
		Run: string(st.preview.ChosenRun), AddedAt: addedAt}
	if err := side.Save(d.mcpSidecarPath()); err != nil {
		return wire.ManagedMCPServer{}, mcpcatalog.Failed("catalog-mcp.json could not be written")
	}
	if r.Destination.Kind == wire.SkillDestinationKindFolder {
		d.recordMCPApproval(*r.Destination.Folder, name, json.RawMessage(entry.Stringified()))
	}
	byHand := false
	return wire.ManagedMCPServer{Name: name, RegistryName: st.registryName, Version: st.version, Run: st.preview.ChosenRun,
		AddedAt: wire.DateOf(addedAt), Destination: r.Destination, ByHand: &byHand}, nil
}

// MARK: The approvals file, kept with mcpservers.go's reading of it

// saveMCPApprovalsLocked writes mcp-approvals.json. Over one that could not be read, only
// the person's own act writes (replacing), and the old one is kept aside first.
func (d *Daemon) saveMCPApprovalsLocked(replacing bool) error {
	if d.mcpApprovals == nil {
		if !replacing {
			return nil
		}
		if b, err := os.ReadFile(d.mcpApprovalsPath()); err == nil {
			os.WriteFile(fmt.Sprintf("%s.unreadable-%d", d.mcpApprovalsPath(), time.Now().Unix()), b, 0o644)
			store.TrimSetAsides(d.mcpApprovalsPath())
		}
		began, _ := json.Marshal(now())
		d.mcpApprovals = map[string]json.RawMessage{"approvalsBegan": began, "approved": json.RawMessage("{}")}
	}
	b, err := json.Marshal(d.mcpApprovals)
	if err != nil {
		return err
	}
	return store.WriteAtomically(d.mcpApprovalsPath(), b, 0o644)
}

// changeMCPApprovals edits the approved map, or the views map, and writes the file.
func (d *Daemon) changeMCPApprovals(replacing bool, change func(approved, views map[string]string)) error {
	d.mcpMu.Lock()
	defer d.mcpMu.Unlock()
	d.mcpApprovalsLocked()
	if d.mcpApprovals == nil && !replacing {
		return nil
	}
	if d.mcpApprovals == nil {
		d.saveMCPApprovalsLocked(true)
	}
	approved, views := map[string]string{}, map[string]string{}
	json.Unmarshal(d.mcpApprovals["approved"], &approved)
	json.Unmarshal(d.mcpApprovals["views"], &views)
	change(approved, views)
	d.mcpApprovals["approved"], _ = json.Marshal(approved)
	if len(views) > 0 || d.mcpApprovals["views"] != nil {
		d.mcpApprovals["views"], _ = json.Marshal(views)
	}
	return d.saveMCPApprovalsLocked(replacing)
}

// recordMCPApproval: the sheet wrote this entry, so it is the one approved from now.
func (d *Daemon) recordMCPApproval(folder, name string, raw json.RawMessage) {
	if err := d.changeMCPApprovals(true, func(approved, _ map[string]string) {
		approved[mcpApprovalKey(folder, name)] = entryDigest(raw)
	}); err != nil {
		log.Printf("mcp: could not record the approval of %s: %v", name, err)
	}
}

// MARK: mcp/list and mcp/approve

func (d *Daemon) mcpList(dest wire.SkillDestination) (wire.MCPListAnswer, error) {
	if err := d.requireMCPFolder(dest); err != nil {
		return wire.MCPListAnswer{}, mcpRefusal(err)
	}
	answer := wire.MCPListAnswer{Servers: []wire.FolderMCPServer{}}
	path, err := d.mcpFile(dest)
	if err != nil {
		return answer, nil
	}
	folder := dest.Kind == wire.SkillDestinationKindFolder
	d.mcpMu.Lock()
	approved, _, unreadable := d.mcpApprovalsLocked()
	views := map[string]string{}
	if d.mcpApprovals != nil {
		json.Unmarshal(d.mcpApprovals["views"], &views)
	}
	d.mcpMu.Unlock()
	if folder && unreadable {
		note := "mcp-approvals.json could not be read, so nothing is approved until you approve it again."
		answer.ApprovalsProblem = &note
	}
	if _, err := mcpcatalog.LoadFile(path); err != nil {
		problem := err.Error()
		answer.Problem = &problem
		return answer, nil
	}
	entries, problem := readMCPFile(path)
	if problem != "" {
		answer.Problem = &problem
		return answer, nil
	}
	secrets := d.secrets()
	side := mcpcatalog.LoadSidecar(d.mcpSidecarPath())
	scope := "personal"
	if folder {
		scope = filepath.Clean(*dest.Folder)
	}
	var waiting, ready []wire.FolderMCPServer
	for _, e := range entries {
		digest := entryDigest(e.raw)
		row := wire.FolderMCPServer{Name: e.name, Summary: mcpSummary(e), EntryDigest: digest,
			Approval: wire.MCPApprovalState{Approved: &struct{}{}}, MissingSecrets: []string{}, SecretNames: []string{}}
		if folder {
			stored, had := approved[mcpApprovalKey(*dest.Folder, e.name)]
			if approved == nil || stored != digest {
				row.Approval = wire.MCPApprovalState{Waiting: &wire.MCPApprovalStateWaiting{Digest: digest, IsNew: !had}}
			}
		}
		if record, ok := side.Servers[mcpcatalog.Key(dest, e.name)]; ok {
			byHand := record.ByHand != nil && *record.ByHand
			row.Managed = &wire.ManagedMCPServer{Name: e.name, RegistryName: record.RegistryName, Version: record.Version,
				Run: wire.MCPRunKind(record.Run), AddedAt: wire.DateOf(record.AddedAt), Destination: dest, ByHand: &byHand}
		}
		seen := map[string]bool{}
		for _, n := range mcpSecretNames(e) {
			if !seen[n] {
				seen[n] = true
				row.SecretNames = append(row.SecretNames, n)
				if _, ok := secrets[n]; !ok {
					row.MissingSecrets = append(row.MissingSecrets, n)
				}
			}
		}
		row.Views = viewsWord(views, scope, e.name)
		if row.Approval.Waiting != nil {
			waiting = append(waiting, row)
		} else {
			ready = append(ready, row)
		}
	}
	answer.Servers = d.mcpSignInStates(append(append(answer.Servers, waiting...), ready...), dest)
	log.Printf("mcp: list %s → %d", dest.Kind, len(answer.Servers))
	return answer, nil
}

// mcpSummary is the command line or URL, with ${NAME} still visible.
func mcpSummary(e mcpEntry) string {
	switch {
	case e.server.Stdio != nil:
		return strings.Join(append([]string{e.server.Stdio.Command}, e.server.Stdio.Args...), " ")
	case e.server.Http != nil:
		return e.server.Http.Url
	case e.server.Sse != nil:
		return e.server.Sse.Url
	}
	return ""
}

var secretRefName = regexp.MustCompile(`\$\{([^}]*)\}`)

// mcpSecretNames is every ${NAME} the entry names, in the order they come.
func mcpSecretNames(e mcpEntry) []string {
	var texts []string
	switch {
	case e.server.Stdio != nil:
		texts = append(append(texts, e.server.Stdio.Command), e.server.Stdio.Args...)
		for _, v := range e.server.Stdio.Env {
			texts = append(texts, v.Value)
		}
	case e.server.Http != nil:
		texts = append(texts, e.server.Http.Url)
		for _, h := range e.server.Http.Headers {
			texts = append(texts, h.Value)
		}
	case e.server.Sse != nil:
		texts = append(texts, e.server.Sse.Url)
		for _, h := range e.server.Sse.Headers {
			texts = append(texts, h.Value)
		}
	}
	var out []string
	for _, t := range texts {
		for _, m := range secretRefName.FindAllStringSubmatch(t, -1) {
			out = append(out, m[1])
		}
	}
	return out
}

// viewsWord is what the person last said about a server's views: shown, hidden or mixed.
func viewsWord(views map[string]string, scope, server string) *string {
	prefix := scope + "|" + server + "|"
	shown, hidden := false, false
	for k, v := range views {
		if strings.HasPrefix(k, prefix) {
			if strings.HasPrefix(v, "show:") {
				shown = true
			} else {
				hidden = true
			}
		}
	}
	word := ""
	switch {
	case shown && hidden:
		word = "mixed"
	case shown:
		word = "shown"
	case hidden:
		word = "hidden"
	default:
		return nil
	}
	return &word
}

func (d *Daemon) mcpApprove(r wire.MCPApproveRequest) (wire.MCPListAnswer, error) {
	if r.Destination.Kind != wire.SkillDestinationKindFolder || r.Destination.Folder == nil {
		return wire.MCPListAnswer{}, mcpRefusal(mcpcatalog.Failed("Only a folder's server waits for approval."))
	}
	if err := d.requireMCPFolder(r.Destination); err != nil {
		return wire.MCPListAnswer{}, mcpRefusal(err)
	}
	folder := *r.Destination.Folder
	path := mcpcatalog.FolderFile(folder)
	entries, problem := readMCPFile(path)
	if problem != "" {
		return wire.MCPListAnswer{}, mcpRefusal(mcpcatalog.Unreadable(path))
	}
	var raw json.RawMessage
	for _, e := range entries {
		if e.name == r.Name {
			raw = e.raw
		}
	}
	if raw == nil || entryDigest(raw) != r.Digest {
		return wire.MCPListAnswer{}, mcpRefusal(mcpcatalog.StaleDigest())
	}
	if err := d.changeMCPApprovals(true, func(approved, _ map[string]string) {
		approved[mcpApprovalKey(folder, r.Name)] = r.Digest
	}); err != nil {
		return wire.MCPListAnswer{}, mcpRefusal(mcpcatalog.Failed("mcp-approvals.json could not be written"))
	}
	log.Printf("mcp: approve %s in folder", r.Name)
	d.mcpChanged()
	// A pinned page of this server waited for the approval: its clients draw it now (#1780).
	d.pinsChanged(folder)
	return d.mcpList(r.Destination)
}

// mcpForgetViews forgets every Show or Don't Show for one server, so its views ask again.
func (d *Daemon) mcpForgetViews(r wire.MCPViewsForgetRequest) error {
	scope := "personal"
	if r.Destination.Kind == wire.SkillDestinationKindFolder && r.Destination.Folder != nil {
		scope = filepath.Clean(*r.Destination.Folder)
	}
	prefix := scope + "|" + r.Name + "|"
	return d.changeMCPApprovals(true, func(_, views map[string]string) {
		for k := range views {
			if strings.HasPrefix(k, prefix) {
				delete(views, k)
			}
		}
	})
}

// MARK: secrets and removal

func (d *Daemon) mcpSetSecret(r wire.MCPSetSecretRequest) (wire.MCPSetSecretAnswer, error) {
	home := d.personalHome()
	switch {
	case home == "":
		return wire.MCPSetSecretAnswer{}, mcpRefusal(mcpcatalog.NoPersonalHome())
	case !regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`).MatchString(r.Name):
		return wire.MCPSetSecretAnswer{}, mcpRefusal(mcpcatalog.Failed("A secret's name is letters, digits and underscores."))
	case r.Value == "":
		return wire.MCPSetSecretAnswer{}, mcpRefusal(mcpcatalog.Failed("A secret needs a value."))
	}
	if err := d.saveSecret(r.Name, r.Value); err != nil {
		return wire.MCPSetSecretAnswer{}, mcpRefusal(mcpcatalog.Failed(err.Error()))
	}
	log.Printf("mcp: set-secret %s", r.Name)
	return wire.MCPSetSecretAnswer{Set: true}, nil
}

// mcpRemove takes a server out of mcp.json, one the app added or one written by hand
// (#2154): the person asked for it, so only add leaves a hand-written entry alone. The rest
// of the file stays as it is; a personal entry is kept in mcp.removed.json (#2195). forgetSecret goes only when no other server, personal or a
// folder's, still names it.
func (d *Daemon) mcpRemove(r wire.MCPRemoveRequest) (wire.MCPRemoveAnswer, error) {
	if err := d.requireMCPFolder(r.Destination); err != nil {
		return wire.MCPRemoveAnswer{}, mcpRefusal(err)
	}
	home := d.personalHome()
	if home == "" {
		return wire.MCPRemoveAnswer{}, mcpRefusal(mcpcatalog.NoPersonalHome())
	}
	path, err := d.mcpFile(r.Destination)
	if err != nil {
		return wire.MCPRemoveAnswer{}, mcpRefusal(err)
	}
	entries, problem := readMCPFile(path)
	if problem != "" {
		return wire.MCPRemoveAnswer{}, mcpRefusal(mcpcatalog.Unreadable(path))
	}
	if !slices.ContainsFunc(entries, func(e mcpEntry) bool { return e.name == r.Name }) {
		return wire.MCPRemoveAnswer{}, mcpRefusal(mcpcatalog.Failed("There is no " + r.Name + " in " + path + "."))
	}
	side := mcpcatalog.LoadSidecar(d.mcpSidecarPath())
	key := mcpcatalog.Key(r.Destination, r.Name)
	forget := ""
	if r.ForgetSecret != nil {
		forget = *r.ForgetSecret
	}
	var env skillcatalog.Secrets
	if forget != "" {
		if d.secretNamedElsewhere(forget, r.Name, path, home) {
			return wire.MCPRemoveAnswer{}, mcpRefusal(mcpcatalog.SecretStillInUse(forget))
		}
		if env, err = skillcatalog.LoadSecretsForChange(skillcatalog.SecretsPath(home)); err != nil {
			return wire.MCPRemoveAnswer{}, mcpRefusal(mcpcatalog.Failed(err.Error()))
		}
	}
	entry, _, _ := mcpcatalog.Entry(path, r.Name)
	if err := mcpcatalog.Remove(path, r.Name); err != nil {
		return wire.MCPRemoveAnswer{}, mcpRefusal(mcpcatalog.Unreadable(path))
	}
	// The personal file is in no git: keep a copy of what went (#2195). A folder's is committed.
	if r.Destination.Kind == wire.SkillDestinationKindPersonal {
		if err := mcpcatalog.KeepRemoved(home, r.Name, entry); err != nil {
			log.Printf("mcp: remove %s: no copy kept in %s: %v", r.Name, mcpcatalog.RemovedFile(home), err)
		}
	}
	delete(side.Servers, key)
	side.Save(d.mcpSidecarPath())
	if r.Destination.Kind == wire.SkillDestinationKindFolder {
		folder := *r.Destination.Folder
		d.changeMCPApprovals(true, func(approved, _ map[string]string) { delete(approved, mcpApprovalKey(folder, r.Name)) })
	}
	if forget != "" {
		env.Remove(forget)
		env.Save(skillcatalog.SecretsPath(home))
	}
	log.Printf("mcp: remove %s", r.Name)
	d.mcpChanged()
	return wire.MCPRemoveAnswer{Ok: true}, nil
}

// secretNamedElsewhere is whether a server other than the one going still names ${secret}.
func (d *Daemon) secretNamedElsewhere(secret, name, dropping, home string) bool {
	paths := []string{}
	for _, p := range d.folders(true) {
		paths = append(paths, mcpcatalog.FolderFile(store.FolderPath(p.Folder.Folder)))
	}
	paths = append(paths, mcpcatalog.PersonalFile(home), dropping)
	seen := map[string]bool{}
	for _, path := range paths {
		path = filepath.Clean(path)
		if seen[path] {
			continue
		}
		seen[path] = true
		entries, _ := readMCPFile(path)
		for _, e := range entries {
			if path == filepath.Clean(dropping) && e.name == name {
				continue
			}
			for _, n := range mcpSecretNames(e) {
				if n == secret {
					return true
				}
			}
		}
	}
	return false
}
