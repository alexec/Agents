package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// Which of a person's MCP servers a view may come from, and what views it has
// (DaemonCore+ThirdPartyViews, ServerViewCatalog). The app reaches the server over a
// connection of its own, here one for each request. http servers show views, and hosted
// ones through the host's one copy (#1341, hostedviews.go). Any other stdio server's would
// need a second copy of it (Q5), so they say so instead. A server waiting for approval,
// missing a secret, or wanting a sign-in shows nothing.
// Logged: names, ui:// addresses and words; never a command, URL, header or body.

// viewServer is a server a view may come from, set up and approved here.
type viewServer struct {
	name string
	// scope is where its entry is, for its view answers: the folder, or personal.
	scope  string
	filled sdk.McpServer
	// entry is the catalog's key: a digest of the entry as written, ${NAME} and all.
	entry string
	// connect is the way to a hosted server's one copy; nil for an http server.
	connect func() (mcpConn, error)
}

// viewTrouble is why a server's views are not shown here.
type viewTrouble int

const (
	viewNotSetUp viewTrouble = iota + 1
	viewWaiting
	viewLocalServer
	viewOldTransport
	viewMissingSecret
	viewSignIn
)

func (p viewTrouble) words(server string) string {
	switch p {
	case viewWaiting:
		return server + " is waiting for approval, so its views are not shown."
	case viewLocalServer:
		return "Views from local servers aren't shown yet: " + server + " runs on this machine (stdio). " +
			"Only servers reached over http show their views."
	case viewOldTransport:
		return server + " uses the old sse transport, which can't show views."
	case viewMissingSecret:
		return server + " needs a secret that isn't set here, so its views are not shown."
	case viewSignIn:
		return server + " wants a sign-in first, so its views are not shown."
	}
	return server + " is not set up here."
}

// pinReason is PinMissing: why a pinned view can't be drawn here.
func (p viewTrouble) pinReason() string {
	switch p {
	case viewWaiting:
		return "waiting for approval"
	case viewLocalServer, viewOldTransport:
		return "views from local servers aren't shown yet"
	case viewMissingSecret:
		return "a secret is missing"
	case viewSignIn:
		return "needs a sign-in"
	}
	return "server not set up here"
}

// viewScope is MCPApprovals.viewScope: the folder, or personal.
func viewScope(folder string) string {
	if folder == "" {
		return "personal"
	}
	return filepath.Clean(folder)
}

// viewServerFor is name as a session in folder is given it: the folder's approved
// entries, then the person's (the first of a name wins, as for sessions), secrets filled.
func (d *Daemon) viewServerFor(name, folder string) (viewServer, viewTrouble) {
	if name == appServerName {
		return viewServer{}, viewNotSetUp
	}
	folder = filepath.Clean(folder)
	ready := func(e mcpEntry, scope string) (viewServer, viewTrouble) {
		switch {
		case e.server.Stdio != nil && !e.hosted:
			return viewServer{}, viewLocalServer
		case e.server.Sse != nil:
			return viewServer{}, viewOldTransport
		}
		filled, missing := filledServer(e.server, d.secrets())
		if len(missing) > 0 {
			return viewServer{}, viewMissingSecret
		}
		if filled.Stdio != nil {
			// Hosted: as a session in this scope is given it, so it is the same copy.
			var in *string
			cwd := d.personalHome()
			if scope != viewScope("") {
				in, cwd = &folder, folder
			}
			return viewServer{name: name, scope: scope, filled: filled, entry: entryDigest(e.raw),
				connect: d.hostedViewConnect(*filled.Stdio, in, cwd)}, 0
		}
		signed := d.withSignIns([]sdk.McpServer{filled})
		if len(signed) == 0 {
			return viewServer{}, viewSignIn
		}
		return viewServer{name: name, scope: scope, filled: signed[0], entry: entryDigest(e.raw)}, 0
	}
	entries, _ := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
	for _, e := range entries {
		if e.name != name {
			continue
		}
		d.mcpMu.Lock()
		approved, _, _ := d.mcpApprovalsLocked()
		d.mcpMu.Unlock()
		if approved == nil || approved[mcpApprovalKey(folder, name)] != entryDigest(e.raw) {
			return viewServer{}, viewWaiting
		}
		return ready(e, viewScope(folder))
	}
	if home := d.personalHome(); home != "" {
		entries, _ := readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
		for _, e := range entries {
			if e.name == name {
				return ready(e, viewScope(""))
			}
		}
	}
	return viewServer{}, viewNotSetUp
}

// viewServerNames is every server name a session in folder could have been given, but
// the app's own.
func (d *Daemon) viewServerNames(folder string) []string {
	var names []string
	entries, _ := readMCPFile(filepath.Join(folder, ".agents", "mcp.json"))
	for _, e := range entries {
		names = append(names, e.name)
	}
	if home := d.personalHome(); home != "" {
		entries, _ := readMCPFile(filepath.Join(home, ".agents", "mcp.json"))
		for _, e := range entries {
			names = append(names, e.name)
		}
	}
	seen := map[string]bool{appServerName: true}
	out := []string{}
	for _, n := range names {
		if !seen[n] {
			seen[n] = true
			out = append(out, n)
		}
	}
	return out
}

// MARK: The catalog

// viewCatalog is ServerViewCatalog: a server's tools that name a ui:// resource, who may
// call each, and the resources' addresses. Kept at <root>/mcp-views/<key>.json, keyed by
// the entry, so a changed entry is a new catalog, and the old one is removed (#3128).
// Never a secret, a URL or a header.
type viewCatalog struct {
	// Version is viewCatalogVersion when it was made; an older one is read again.
	Version int    `json:"version"`
	Server  string `json:"server"`
	// Scope is the server's viewScope: with Server, which entry the catalog is of.
	Scope string `json:"scope,omitempty"`
	// Title is the server's own title (initialize's serverInfo.title), when it gives one.
	Title     string         `json:"title,omitempty"`
	MadeAt    time.Time      `json:"madeAt"`
	Tools     []viewTool     `json:"tools"`
	AppTools  []string       `json:"appTools"`
	Resources []viewResource `json:"resources"`
}

type viewTool struct {
	Name        string   `json:"name"`
	ResourceURI string   `json:"resourceURI"`
	Visibility  []string `json:"visibility"`
	ReadOnly    bool     `json:"readOnly"`
	// NeedsArguments: its input schema requires an argument, so it feeds no list (#2032).
	NeedsArguments bool `json:"needsArguments,omitempty"`
}

type viewResource struct {
	URI      string  `json:"uri"`
	Name     *string `json:"name,omitempty"`
	MimeType *string `json:"mimeType,omitempty"`
	Title    *string `json:"title,omitempty"`
}

// feedsPins: opening a pin calls it, so a view may call it and it changes nothing.
func (t viewTool) feedsPins() bool {
	app := false
	for _, v := range t.Visibility {
		app = app || v == "app"
	}
	return app && t.ReadOnly
}

func (c *viewCatalog) tool(name string) *viewTool {
	for i := range c.Tools {
		if c.Tools[i].Name == name {
			return &c.Tools[i]
		}
	}
	return nil
}

func (c *viewCatalog) resource(uri string) *viewResource {
	for i := range c.Resources {
		if c.Resources[i].URI == uri {
			return &c.Resources[i]
		}
	}
	return nil
}

func (c *viewCatalog) appTool(name string) bool {
	for _, t := range c.AppTools {
		if t == name {
			return true
		}
	}
	return false
}

// viewCatalogVersion is what a catalog made now holds: 3 requires a listed resource for each view tool.
const viewCatalogVersion = 3

// viewCatalogFresh is how long a catalog is kept: a server's tools can change without its
// entry changing.
const viewCatalogFresh = 24 * time.Hour

// A missing tool triggers a refresh, but a bad view cannot force one network read per call.
const viewCatalogMissRefreshCooldown = 5 * time.Second

// makeViewCatalog is ServerViewCatalog.make, from tools/list and resources/list.
func makeViewCatalog(server string, tools, resources []json.RawMessage, at time.Time) viewCatalog {
	c := viewCatalog{Version: viewCatalogVersion, Server: server, MadeAt: at, Tools: []viewTool{}, AppTools: []string{}, Resources: []viewResource{}}
	resourceURIs := make(map[string]struct{}, len(resources))
	for _, raw := range resources {
		var r struct {
			URI      string  `json:"uri"`
			Name     *string `json:"name"`
			Title    *string `json:"title"`
			MimeType *string `json:"mimeType"`
		}
		if json.Unmarshal(raw, &r) != nil || !strings.HasPrefix(r.URI, "ui://") {
			continue
		}
		resourceURIs[r.URI] = struct{}{}
		name := r.Name
		if name == nil {
			name = r.Title
		}
		c.Resources = append(c.Resources, viewResource{URI: r.URI, Name: name, MimeType: r.MimeType, Title: r.Title})
	}
	for _, raw := range tools {
		var t struct {
			Name string `json:"name"`
			Meta struct {
				UI struct {
					ResourceURI string   `json:"resourceUri"`
					Visibility  []string `json:"visibility"`
				} `json:"ui"`
				ResourceURI string `json:"ui/resourceUri"`
			} `json:"_meta"`
			Annotations struct {
				ReadOnlyHint bool `json:"readOnlyHint"`
			} `json:"annotations"`
			InputSchema struct {
				Required []string `json:"required"`
			} `json:"inputSchema"`
		}
		if json.Unmarshal(raw, &t) != nil || t.Name == "" {
			continue
		}
		seen := t.Meta.UI.Visibility
		if len(seen) == 0 {
			seen = []string{"model", "app"}
		}
		for _, v := range seen {
			if v == "app" {
				c.AppTools = append(c.AppTools, t.Name)
				break
			}
		}
		uri := t.Meta.UI.ResourceURI
		if uri == "" {
			uri = t.Meta.ResourceURI
		}
		if !strings.HasPrefix(uri, "ui://") {
			continue
		}
		// A tool's metadata alone does not make it a view. Require the server to list the
		// resource too, or a successful ordinary tool call can become an unreadable view.
		if _, listed := resourceURIs[uri]; !listed {
			continue
		}
		c.Tools = append(c.Tools, viewTool{Name: t.Name, ResourceURI: uri, Visibility: seen, ReadOnly: t.Annotations.ReadOnlyHint,
			NeedsArguments: len(t.InputSchema.Required) > 0})
	}
	return c
}

func (d *Daemon) viewCatalogPath(key string) string {
	return filepath.Join(d.Store.Loc.Root, "mcp-views", key+".json")
}

// cachedViewCatalog is the server's views as last read, without connecting.
func (d *Daemon) cachedViewCatalog(s viewServer) *viewCatalog {
	d.viewMu.Lock()
	held, ok := d.viewCatalogs[s.entry]
	d.viewMu.Unlock()
	if ok && held.Version == viewCatalogVersion && nowFunc().Sub(held.MadeAt) < viewCatalogFresh {
		return &held
	}
	b, err := os.ReadFile(d.viewCatalogPath(s.entry))
	if err != nil {
		return nil
	}
	var c viewCatalog
	if json.Unmarshal(b, &c) != nil || c.Version != viewCatalogVersion || nowFunc().Sub(c.MadeAt) >= viewCatalogFresh {
		return nil
	}
	d.keepViewCatalog(s.entry, c)
	return &c
}

func (d *Daemon) keepViewCatalog(key string, c viewCatalog) {
	d.viewMu.Lock()
	defer d.viewMu.Unlock()
	if d.viewCatalogs == nil {
		d.viewCatalogs = map[string]viewCatalog{}
	}
	d.viewCatalogs[key] = c
	if len(d.viewCatalogs) > 32 {
		oldest := ""
		for k, v := range d.viewCatalogs {
			if oldest == "" || v.MadeAt.Before(d.viewCatalogs[oldest].MadeAt) {
				oldest = k
			}
		}
		delete(d.viewCatalogs, oldest)
	}
}

// pruneViewCatalogs removes, after kept was written as key, each catalog no read can use:
// one of the same server and scope from an entry since changed, and one too old to be read
// (an entry removed, or a catalog from before Scope). So mcp-views/ holds about one file for
// each entry read in the last viewCatalogFresh (#3128).
func (d *Daemon) pruneViewCatalogs(key string, kept viewCatalog) {
	dir := filepath.Dir(d.viewCatalogPath(key))
	names, err := os.ReadDir(dir)
	if err != nil {
		return
	}
	removed := 0
	for _, n := range names {
		name := n.Name()
		if n.IsDir() || !strings.HasSuffix(name, ".json") || name == key+".json" {
			continue
		}
		path := filepath.Join(dir, name)
		stale := false
		var c viewCatalog
		if b, err := os.ReadFile(path); err != nil || json.Unmarshal(b, &c) != nil {
			info, err := n.Info()
			stale = err == nil && nowFunc().Sub(info.ModTime()) >= viewCatalogFresh
		} else {
			stale = nowFunc().Sub(c.MadeAt) >= viewCatalogFresh ||
				(c.Server == kept.Server && c.Scope == kept.Scope && c.Scope != "")
		}
		if stale && os.Remove(path) == nil {
			removed++
		}
	}
	if removed > 0 {
		log.Printf("mcp views: %d old catalog(s) removed", removed)
	}
}

// loadViewCatalog is the server's views, read from it when none is kept; nil when it
// could not be read. A server that failed is not asked again for five minutes, and two
// asking at once share one read.
func (d *Daemon) loadViewCatalog(ctx context.Context, s viewServer) *viewCatalog {
	return d.readViewCatalog(ctx, s, false)
}

// refreshViewCatalog reads the server's tool list again when a view asks for a tool
// missing from the cache. A server can add an app-visible tool while the cache is fresh.
func (d *Daemon) refreshViewCatalog(ctx context.Context, s viewServer) *viewCatalog {
	if c := d.cachedViewCatalog(s); c != nil && nowFunc().Sub(c.MadeAt) < viewCatalogMissRefreshCooldown {
		return c
	}
	return d.readViewCatalog(ctx, s, true)
}

func (d *Daemon) readViewCatalog(ctx context.Context, s viewServer, refresh bool) *viewCatalog {
	cached := d.cachedViewCatalog(s)
	if cached != nil && !refresh {
		return cached
	}
	d.viewMu.Lock()
	// A read that ended after the look above is kept by now: read again only when it is
	// too old, or two asking one after the other read twice (#2673).
	enough := viewCatalogFresh
	if refresh {
		enough = viewCatalogMissRefreshCooldown
	}
	if held, ok := d.viewCatalogs[s.entry]; ok && held.Version == viewCatalogVersion && nowFunc().Sub(held.MadeAt) < enough {
		d.viewMu.Unlock()
		return &held
	}
	if failed, ok := d.viewFailures[s.entry]; ok && nowFunc().Sub(failed) < 5*time.Minute {
		d.viewMu.Unlock()
		return cached
	}
	if loading, ok := d.viewLoads[s.entry]; ok {
		d.viewMu.Unlock()
		<-loading
		return d.cachedViewCatalog(s)
	}
	if d.viewLoads == nil {
		d.viewLoads, d.viewFailures = map[string]chan struct{}{}, map[string]time.Time{}
	}
	done := make(chan struct{})
	d.viewLoads[s.entry] = done
	d.viewMu.Unlock()
	defer func() {
		d.viewMu.Lock()
		delete(d.viewLoads, s.entry)
		d.viewMu.Unlock()
		close(done)
	}()

	var c viewCatalog
	err := withViewSession(ctx, s, func(m *viewSession) error {
		tools, err := m.list("tools/list", "tools")
		if err != nil {
			return err
		}
		resources, err := m.list("resources/list", "resources")
		if err != nil {
			return err
		}
		c = makeViewCatalog(s.name, tools, resources, nowFunc())
		c.Title = m.serverTitle
		c.Scope = s.scope
		return nil
	})
	if err != nil {
		log.Printf("mcp views: %s's views could not be read (%s)", s.name, mcpFailureOf(err).kind)
		d.viewMu.Lock()
		d.viewFailures[s.entry] = nowFunc()
		d.viewMu.Unlock()
		return cached
	}
	if b, err := json.MarshalIndent(c, "", "  "); err == nil {
		if store.WriteAtomically(d.viewCatalogPath(s.entry), b, 0o644) != nil {
			log.Printf("mcp views: the catalog of %s could not be kept", s.name)
		}
		d.pruneViewCatalogs(s.entry, c)
	}
	d.keepViewCatalog(s.entry, c)
	d.viewMu.Lock()
	delete(d.viewFailures, s.entry)
	d.viewMu.Unlock()
	log.Printf("mcp views: %s has %d tool(s) with a view", s.name, len(c.Tools))
	return &c
}

// MARK: A connection of the app's own

// viewTimeout is how long one request of a view's server may take, connecting and all.
var viewTimeout = 60 * time.Second

// viewSession is MCPClient over one connection: initialized, then asked.
type viewSession struct {
	ctx  context.Context
	conn mcpConn
	next int
	// serverTitle is initialize's serverInfo.title, or "".
	serverTitle string
}

// withViewSession connects to s, initializes, runs body, and ends the session.
func withViewSession(ctx context.Context, s viewServer, body func(*viewSession) error) error {
	var conn mcpConn
	switch {
	case s.connect != nil:
		c, err := s.connect()
		if err != nil {
			return err
		}
		conn = c
	case s.filled.Http != nil:
		conn = &httpMCP{url: s.filled.Http.Url, headers: s.filled.Http.Headers}
	default:
		return &mcpCheckFailure{kind: "notMCP"}
	}
	ctx, cancel := context.WithTimeout(ctx, viewTimeout)
	defer cancel()
	defer conn.end()
	m := &viewSession{ctx: ctx, conn: conn, next: 1}
	timedOut := func(err error) error {
		if ctx.Err() != nil {
			return &mcpCheckFailure{kind: "timedOut"}
		}
		return err
	}
	init, err := m.call("initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agents", "version": "1"}})
	if err != nil {
		return timedOut(err)
	}
	var info struct {
		ServerInfo struct {
			Title string `json:"title"`
		} `json:"serverInfo"`
	}
	if json.Unmarshal(init, &info) == nil {
		m.serverTitle = strings.TrimSpace(info.ServerInfo.Title)
	}
	if err := conn.notify(ctx, "notifications/initialized"); err != nil {
		return timedOut(err)
	}
	return timedOut(body(m))
}

func (m *viewSession) call(method string, params any) (json.RawMessage, error) {
	id := m.next
	m.next++
	return m.conn.call(m.ctx, id, method, params)
}

// list is every page of a list method: at most 50 pages.
func (m *viewSession) list(method, key string) ([]json.RawMessage, error) {
	var all []json.RawMessage
	cursor := ""
	for page := 0; page < 50; page++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := m.call(method, params)
		if err != nil {
			return nil, err
		}
		var p map[string]json.RawMessage
		if json.Unmarshal(raw, &p) != nil {
			return nil, &mcpCheckFailure{kind: "notMCP"}
		}
		var items []json.RawMessage
		json.Unmarshal(p[key], &items)
		all = append(all, items...)
		cursor, _ = stringOf(p["nextCursor"])
		if cursor == "" {
			break
		}
	}
	return all, nil
}
