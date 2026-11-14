package agentsd

import (
	"encoding/json"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/internal/azuredevopsmcp"
	"github.com/agentloops-dev/agents/Go/internal/bitbucketmcp"
	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/wire"
)

// Docs in the lineage (#3308): the requirement or design behind a change. An agent reads the
// docs behind an issue before it works on it (#3248), so a doc that a session reads or links
// to is a node, and the issue's and the pull request's Lineage section names it.
//
//   - A tool call that reads a *.md file under specs/ or docs/ of the session's folder (or its
//     worktree): session reads the doc. A tool call whose input is a docs page's address (a
//     docs connector's fetch, or a web fetch): session reads the page.
//   - What the agent says names such a file, or a docs page's address: session links-to it.
//
// A file of the folder's forge repo is github:<owner>/<repo>/doc/<path>, so the same doc is
// one node from every worktree and machine; in a folder with no forge it is file:<path>. A
// docs page is its own address. The links end with the session's other links, when it is
// archived.

// docMentions bounds the docs one message or tool call links, so a long list costs little.
const docMentions = 20

var (
	// docPathSaid is a doc's path as an agent writes it: specs/x/spec.md, docs/how-to/y.md.
	docPathSaid = regexp.MustCompile("(?:^|[\\s(\\[`\"'])((?:specs|docs)/[A-Za-z0-9._/-]+\\.md)\\b")
	urlSaid     = regexp.MustCompile(`https?://[^\s<>()\[\]"'` + "`" + `]+`)
)

// isDocsPage says an address is a docs page: Notion, Confluence (on Atlassian, under /wiki/),
// and Google Docs and Drive.
func isDocsPage(u *url.URL) bool {
	host := strings.ToLower(u.Hostname())
	switch {
	case host == "notion.so" || host == "www.notion.so" || strings.HasSuffix(host, ".notion.site"):
		return true
	case host == "docs.google.com" || host == "drive.google.com":
		return true
	case strings.Contains(host, "confluence"):
		return true
	case strings.HasSuffix(host, ".atlassian.net"):
		return strings.HasPrefix(u.Path, "/wiki/")
	}
	return false
}

// docsPage is the node for a docs page's address: the address without its query or fragment.
func docsPage(raw string) (wire.LineageNode, bool) {
	u, err := url.Parse(strings.TrimRight(raw, ".,;:!?"))
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || !isDocsPage(u) {
		return wire.LineageNode{}, false
	}
	path := strings.TrimSuffix(u.EscapedPath(), "/")
	if path == "" {
		path = "/"
	}
	n := lineage.NodeOf(lineage.KindDoc, wire.Ref{Provider: "web", Type: "doc", Topic: strings.ToLower(u.Host), ID: path})
	return n, len(n.Ref) <= 512
}

// doc is a file of the repo, by its path in it.
func (r forgeRepo) doc(rel string) wire.LineageNode {
	return r.node(lineage.KindDoc, "doc", rel)
}

// sessionRoots is where a session's files are: its working folder (a worktree's own), and
// the folder it belongs to. The repo is the folder's.
func sessionRoots(a *wire.Agent) (folder string, roots []string) {
	folder = folderPath(a)
	roots = []string{folder}
	if cwd := store.FolderPath(a.Cwd); cwd != folder {
		roots = append(roots, cwd)
	}
	return folder, roots
}

// docRel is path's place under a root, when it is a *.md file under specs/ or docs/.
func docRel(roots []string, path string) (string, bool) {
	if !strings.EqualFold(filepath.Ext(path), ".md") {
		return "", false
	}
	path = filepath.Clean(path)
	for _, root := range roots {
		for _, r := range []string{root, resolvedPath(root)} {
			rel, err := filepath.Rel(r, path)
			if err != nil {
				continue
			}
			rel = filepath.ToSlash(rel)
			if strings.HasPrefix(rel, "specs/") || strings.HasPrefix(rel, "docs/") {
				return rel, true
			}
		}
	}
	return "", false
}

func resolvedPath(p string) string {
	if r, err := store.Resolve(p); err == nil {
		return filepath.Clean(r)
	}
	return p
}

// docOfFile is the node for a doc file of the session, when it is one and is there.
func (d *Daemon) docOfFile(folder string, roots []string, rel string) (wire.LineageNode, bool) {
	if strings.Contains(rel, "..") {
		return wire.LineageNode{}, false
	}
	for _, root := range roots {
		info, err := os.Stat(filepath.Join(root, filepath.FromSlash(rel)))
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		var n wire.LineageNode
		if repo := d.folderRepo(folder); repo.forge != "" {
			n = repo.doc(rel)
		} else {
			n = lineage.NodeOf(lineage.KindDoc, wire.Ref{Provider: "file", Type: "doc", ID: filepath.ToSlash(filepath.Join(folder, rel))})
		}
		return n, len(n.Ref) <= 512
	}
	return wire.LineageNode{}, false
}

// noteDocRead links a session to the docs a tool call of its reads: a read of a doc file,
// or a call whose input is a docs page's address.
func (d *Daemon) noteDocRead(id wire.UUID, call wire.ToolCall) {
	var paths []string
	if call.Kind != nil && *call.Kind == "read" {
		for _, l := range call.Locations {
			if strings.HasSuffix(strings.ToLower(l.Path), ".md") {
				paths = append(paths, l.Path)
			}
		}
	}
	pages := pagesIn(call.RawInput)
	if len(paths) == 0 && len(pages) == 0 {
		return
	}
	d.noteDocs(id, lineage.RelReads, paths, nil, pages)
}

// pagesIn is the docs pages' addresses among a tool call's input's own strings.
func pagesIn(raw json.RawMessage) []wire.LineageNode {
	if len(raw) == 0 || !strings.Contains(string(raw), "http") {
		return nil
	}
	var in map[string]json.RawMessage
	if json.Unmarshal(raw, &in) != nil {
		return nil
	}
	var out []wire.LineageNode
	for _, v := range in {
		var s string
		if json.Unmarshal(v, &s) != nil {
			continue
		}
		if n, ok := docsPage(strings.TrimSpace(s)); ok && len(out) < docMentions {
			out = append(out, n)
		}
	}
	return out
}

// noteDocLinks links a session to the docs that what it said names: a doc's path, or a
// docs page's address.
func (d *Daemon) noteDocLinks(id wire.UUID, said string) {
	if !strings.Contains(said, "specs/") && !strings.Contains(said, "docs/") && !strings.Contains(said, "http") {
		return
	}
	var rels []string
	for _, m := range docPathSaid.FindAllStringSubmatch(said, docMentions) {
		rels = append(rels, m[1])
	}
	var pages []wire.LineageNode
	for _, raw := range urlSaid.FindAllString(said, docMentions) {
		if n, ok := docsPage(raw); ok {
			pages = append(pages, n)
		}
	}
	if len(rels) == 0 && len(pages) == 0 {
		return
	}
	d.noteDocs(id, lineage.RelLinksTo, nil, rels, pages)
}

// noteDocs links session id to its docs by rel, on the linker's goroutine: the files by
// their paths (absolute) or by their places under its folder (rels), and the pages.
func (d *Daemon) noteDocs(id wire.UUID, rel string, paths, rels []string, pages []wire.LineageNode) {
	a := d.Store.Agent(id)
	if a == nil || a.Purpose != nil {
		return
	}
	folder, roots := sessionRoots(a)
	d.lineageDo(func() {
		s := d.sessionNode(id)
		seen := map[wire.LineageNode]bool{}
		link := func(n wire.LineageNode) {
			if !seen[n] {
				seen[n] = true
				d.link(s, n, rel, lineage.SourceAgent)
			}
		}
		for _, p := range paths {
			if r, ok := docRel(roots, p); ok {
				rels = append(rels, r)
			}
		}
		for _, r := range rels {
			if n, ok := d.docOfFile(folder, roots, r); ok {
				link(n)
			}
		}
		for _, n := range pages {
			link(n)
		}
	})
}

// docName is a doc as the Lineage section names it: its path in the repo, or the page's
// host and path.
func docName(ref string) string {
	r, ok := lineage.RefOf(wire.LineageNode{Kind: lineage.KindDoc, Ref: ref})
	if !ok {
		return ref
	}
	switch r.Provider {
	case "web":
		break
	case "file":
		for _, top := range []string{"/specs/", "/docs/"} {
			if i := strings.LastIndex(r.ID, top); i >= 0 {
				return r.ID[i+1:]
			}
		}
		return r.ID
	default:
		return r.ID
	}
	name := r.Topic + strings.TrimSuffix(r.ID, "/")
	if r := []rune(name); len(r) > 80 {
		name = string(r[:80]) + "…"
	}
	return name
}

// docURL is a doc's web address: the page's own, or the file's on GitHub or Bitbucket, or on
// the GitLab, Forgejo or Azure DevOps (dev.azure.com without one) of the page, on its default
// branch.
func docURL(ref, base string) string {
	r, ok := lineage.RefOf(wire.LineageNode{Kind: lineage.KindDoc, Ref: ref})
	if !ok || r.Type != "doc" {
		return ""
	}
	scheme, repo, rel := r.Provider, r.Topic, r.ID
	switch scheme {
	case "web":
		return "https://" + repo + strings.TrimSuffix(rel, "/")
	case "github":
		return "https://github.com/" + repo + "/blob/HEAD/" + rel
	case "gitlab":
		if base == "" || strings.EqualFold(base, "https://linear.app") {
			base = "https://gitlab.com"
		}
		return base + "/" + repo + "/-/blob/HEAD/" + rel
	case "forgejo":
		// A Forgejo's node does not say its host: only the page's. /src/HEAD/ sends the reader
		// on to /src/branch/<default>/.
		if base == "" || strings.EqualFold(base, "https://linear.app") {
			return ""
		}
		return base + "/" + repo + "/src/HEAD/" + rel
	case "bitbucket":
		return "https://" + bitbucketmcp.Host + "/" + repo + "/src/HEAD/" + rel
	case "azuredevops":
		if base == "" || strings.EqualFold(base, "https://linear.app") {
			base = azuredevopsmcp.DefaultBase
		}
		return azuredevopsmcp.WebURL(base, repo) + "?path=" + url.QueryEscape("/"+rel)
	}
	return ""
}
