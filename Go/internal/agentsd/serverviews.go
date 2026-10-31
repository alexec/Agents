package agentsd

import (
	"bufio"
	"context"
	"os"
	"path/filepath"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/mcpcatalog"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// A connected server's list views in the sidebar (#2032): for each server set up and
// approved for a folder, each view that a read-only tool with no required arguments feeds
// is a row of its own, named by the service ("GitHub · Issues"), without a pin. A person
// hides one with pins/hideView; the hidden ones are in pins.json's hidden_views. A view that
// is pinned shows as its pin only. A server that can't show views here shows no row.

// serverViews is folder's list views, the hidden ones marked, in the servers' order. It
// reads only kept catalogs: a server whose views were not read yet is read in the
// background, and pins/changed says the rows once it has been.
func (d *Daemon) serverViews(folder string, f pinsFile) []wire.PinView {
	pinned := map[string]bool{}
	for _, e := range f.pins {
		if e.view != nil {
			pinned[e.view.Server+" "+e.view.URI] = true
		}
	}
	hidden := map[string]bool{}
	for _, h := range f.hiddenViews {
		hidden[h] = true
	}
	host := ""
	hostRead := false
	out := []wire.PinView{}
	for _, name := range d.viewServerNames(folder) {
		s, problem := d.viewServerFor(name, folder)
		if problem != 0 {
			continue
		}
		ours, isOurs := oursForServer(s)
		fits := true
		if isOurs {
			if !hostRead {
				host, hostRead = originHost(folder), true
			}
			fits = oursFits(ours, host)
		}
		catalog := d.cachedViewCatalog(s)
		if catalog == nil {
			if fits || d.projectFills(folder, ours.ID) {
				d.readServerViews(s, folder)
			}
			continue
		}
		title := serverTitle(s, catalog, ours, isOurs)
		seen := map[string]bool{}
		for _, t := range catalog.Tools {
			if !t.feedsPins() || t.NeedsArguments || seen[t.ResourceURI] || pinned[name+" "+t.ResourceURI] {
				continue
			}
			// The folder's project's repository, when its project sets the view's slot
			// (#2669): the page follows the project, whatever the folder's own remote.
			arguments, follows := wire.JSONValue(nil), false
			if isOurs {
				arguments, follows = d.projectViewArguments(folder, ours.ID, t.ResourceURI)
			}
			if !fits && !follows {
				continue
			}
			seen[t.ResourceURI] = true
			pin := wire.ViewPin{Server: name, URI: t.ResourceURI, Tool: t.Name, Arguments: arguments}
			v := wire.PinView{Path: t.ResourceURI, Kind: wire.PinKindView, View: &pin,
				Title:    title + " · " + listViewTitle(catalog, pin, title),
				PinnedBy: wire.PinnerView{Kind: wire.PinnerKindServer, ID: name, Name: title}}
			if hidden[t.ResourceURI] {
				yes := true
				v.Hidden = &yes
			}
			out = append(out, d.withCount(folder, v))
		}
	}
	return out
}

// readServerViews reads s's views in the background, and says folder's pins again once
// they are read. A server that failed is not asked again for five minutes (loadViewCatalog).
func (d *Daemon) readServerViews(s viewServer, folder string) {
	safe.Go("server views", func() {
		if d.pinsHaveStopped() {
			return
		}
		if d.loadViewCatalog(context.Background(), s) != nil {
			d.pinsChanged(folder)
		}
	})
}

// oursForServer is the connector Agents makes that s runs, by its command.
func oursForServer(s viewServer) (mcpcatalog.Ours, bool) {
	if s.filled.Stdio == nil {
		return mcpcatalog.Ours{}, false
	}
	return mcpcatalog.OursByCommand(s.filled.Stdio.Command)
}

// oursFits says ours's views belong in a folder whose origin is on host: GitHub's on
// github.com, GitLab's on any other host, the rest everywhere.
func oursFits(o mcpcatalog.Ours, host string) bool {
	switch o.ID {
	case "agents/github":
		return host == "github.com"
	case "agents/gitlab":
		return host != "" && host != "github.com"
	}
	return true
}

// serverTitle is the catalogue's title for one of ours, the server's own, or its name.
func serverTitle(s viewServer, c *viewCatalog, ours mcpcatalog.Ours, isOurs bool) string {
	switch {
	case isOurs:
		return ours.Title
	case c.Title != "":
		return c.Title
	}
	return s.name
}

// listViewTitle is the view's own title without the server's at its start ("Linear issues"
// is "Issues" under Linear), else one made from its address.
func listViewTitle(c *viewCatalog, v wire.ViewPin, server string) string {
	title := defaultViewTitle(v)
	if r := c.resource(v.URI); r != nil && r.Title != nil && strings.TrimSpace(*r.Title) != "" {
		title = strings.TrimSpace(*r.Title)
	}
	if rest, ok := strings.CutPrefix(strings.ToLower(title), strings.ToLower(server)+" "); ok && rest != "" {
		title = title[len(title)-len(rest):]
		r, n := utf8.DecodeRuneInString(title)
		title = string(unicode.ToUpper(r)) + title[n:]
	}
	if utf8.RuneCountInString(title) > pinTitleLength {
		title = string([]rune(title)[:pinTitleLength])
	}
	return title
}

// originHost is the host of the folder's origin remote, lower case ("github.com"), or "".
// Read from the git config file, without running git.
func originHost(folder string) string {
	gitDir := filepath.Join(folder, ".git")
	if b, err := os.ReadFile(gitDir); err == nil {
		// A worktree: "gitdir: <dir>", whose commondir is the repo's.
		dir, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "gitdir: ")
		if !ok {
			return ""
		}
		if !filepath.IsAbs(dir) {
			dir = filepath.Join(folder, dir)
		}
		gitDir = dir
		if c, err := os.ReadFile(filepath.Join(dir, "commondir")); err == nil {
			common := strings.TrimSpace(string(c))
			if !filepath.IsAbs(common) {
				common = filepath.Join(dir, common)
			}
			gitDir = common
		}
	}
	file, err := os.Open(filepath.Join(gitDir, "config"))
	if err != nil {
		return ""
	}
	defer file.Close()
	inOrigin := false
	lines := bufio.NewScanner(file)
	for lines.Scan() {
		line := strings.TrimSpace(lines.Text())
		if strings.HasPrefix(line, "[") {
			inOrigin = line == `[remote "origin"]`
			continue
		}
		if !inOrigin {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if ok && strings.TrimSpace(key) == "url" {
			return remoteHost(strings.TrimSpace(value))
		}
	}
	return ""
}

// remoteHost is a git remote's host: https://github.com/a/b, git@github.com:a/b and
// ssh://git@github.com/a/b are all github.com.
func remoteHost(remote string) string {
	if _, rest, ok := strings.Cut(remote, "://"); ok {
		remote = rest
	} else if i := strings.Index(remote, ":"); i < 0 {
		return ""
	}
	remote, _, _ = strings.Cut(remote, "/")
	if i := strings.LastIndex(remote, "@"); i >= 0 {
		remote = remote[i+1:]
	}
	remote, _, _ = strings.Cut(remote, ":")
	return strings.ToLower(remote)
}
