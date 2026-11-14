package agentsd

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/agentloops-dev/agent-loops/Go/internal/lineage"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Docs (#3319): docs/list, docs/search and docs/read over this machine's docs, beside Work.
// A doc comes from one source: a folder (its *.md files at the top and under specs/ and docs/,
// with the Docs slot's bounded walk) or a docs connector in the folder's Docs slot, through its
// map in .agents/docs-maps.json (#3307). A folder whose Docs slot is None (skipped) gives no
// source, nor do its connectors. A connector with no map is a source that is not mapped.
//
// A doc's ref is a lineage ref, kind doc (#2348): <forge>:<owner>/<repo>/doc/<path> for a folder
// in a repo (the repo in lower case, the path as it is), folder:<machine>/<folder name>/doc/<path>
// for one with no forge remote, and confluence:<site>/<id>, notion:<id>, gdrive:<id> or
// mcp:<server>/<id> for a connector's. Every method is bounded: a result limit, a byte and line
// limit for each read, a time limit for each connector. A source that fails is named in the
// result, and the others still answer. Logged: a server's name and a word, never a doc.

const (
	// docsListDefault and docsListMost are docs/list's page sizes.
	docsListDefault = 200
	docsListMost    = 500
	// docsSearchDefault and docsSearchMost are how many docs docs/search gives.
	docsSearchDefault = 20
	docsSearchMost    = 100
	// docsMatchesShown is the most matches one search result shows.
	docsMatchesShown = 5
	// docsSnippetLimit is the most a match's snippet holds, in characters.
	docsSnippetLimit = 200
	// docsReadLines and docsReadBytes bound one docs/read.
	docsReadLines = 2000
	docsReadBytes = 256 << 10
	// docsFileBytes is the most of one file a search or a read looks at.
	docsFileBytes = 4 << 20
	// docsTitleBytes is how far into a file its # heading is looked for.
	docsTitleBytes = 8 << 10
	// docsConnectorTimeout is how long one connector has for one call, start-up included.
	docsConnectorTimeout = 20 * time.Second
	// docsConnectorDocs is the most docs one connector call gives.
	docsConnectorDocs = 100
)

func (d *Daemon) registerDocs() {
	On(d, wire.CallDocsList, func(ctx context.Context, _ *Client, r wire.DocsListRequest) (wire.DocsList, error) {
		return d.docsList(ctx, r)
	})
	On(d, wire.CallDocsSearch, func(ctx context.Context, _ *Client, r wire.DocsSearchRequest) (wire.DocsSearch, error) {
		return d.docsSearch(ctx, r)
	})
	On(d, wire.CallDocsRead, func(ctx context.Context, _ *Client, r wire.DocsReadRequest) (wire.DocsReading, error) {
		return d.docsRead(ctx, r)
	})
}

// docsConnector is a docs connector that a folder's Docs slot reaches.
type docsConnector struct {
	name, folder string
	// scheme is its refs' scheme: confluence, notion, gdrive, or mcp.
	scheme string
	m      docsMap
	mapped bool
}

func (c docsConnector) source() wire.DocsSource {
	s := wire.DocsSource{ID: "mcp:" + c.name, Kind: wire.DocsSourceKindConnector, Name: c.name, Folder: &c.folder, State: wire.DocsSourceStateRead}
	if !c.mapped {
		s.State = wire.DocsSourceStateNotMapped
	}
	return s
}

// docsSources is the folders and connectors docs come from, each once.
type docsSources struct {
	folders    []string
	connectors []docsConnector
}

// docsSourcesOf is the sources of folders (every folder on this machine when empty), narrowed
// to the source ids in only when it has any.
func (d *Daemon) docsSourcesOf(folders []string, only []string) docsSources {
	if len(folders) == 0 {
		folders = d.folderPaths()
	}
	want := func(id string) bool { return len(only) == 0 || slices.Contains(only, id) }
	var out docsSources
	seen := map[string]bool{}
	for _, f := range folders {
		if !isDir(f) || d.skippedSlots(f)[wire.ConnectorSlotKindDocs] {
			continue
		}
		if want(f) {
			out.folders = append(out.folders, f)
		}
		maps := d.docsMaps(f)
		for _, e := range d.docsServerEntries(f, maps) {
			if seen[e.name] || !want("mcp:"+e.name) {
				continue
			}
			seen[e.name] = true
			m, mapped := maps[e.name]
			out.connectors = append(out.connectors, docsConnector{name: e.name, folder: f, scheme: docsScheme(e.word), m: m, mapped: mapped && m.searchesAndReads()})
		}
	}
	return out
}

// docsScheme is the refs' scheme for a connector the slot calls word.
func docsScheme(word string) string {
	switch word {
	case "Confluence":
		return "confluence"
	case "Notion":
		return "notion"
	case "Google Drive":
		return "gdrive"
	}
	return "mcp"
}

// docsMachine is this machine's name in a folder doc's ref: its host name, short, lower case.
func docsMachine() string {
	h, _ := os.Hostname()
	h, _, _ = strings.Cut(strings.ToLower(h), ".")
	if h == "" {
		return "this-machine"
	}
	return strings.ReplaceAll(h, " ", "-")
}

// docRefPrefix is the ref of folder's docs up to their path.
func (d *Daemon) docRefPrefix(folder string) string {
	if r := d.folderRepo(folder); r.path != "" {
		return r.forge + ":doc:" + r.path + "#"
	}
	return "folder:doc:" + strings.ToLower(docsMachine()+"/"+filepath.Base(folder)) + "#"
}

// docFile is a doc of a folder: its path in it, when it changed, and its size.
type docFile struct {
	rel  string
	at   time.Time
	size int64
}

// folderDoc is the Doc of a folder's file.
func (d *Daemon) folderDoc(folder, prefix string, f docFile) wire.Doc {
	at := wire.DateOf(f.at)
	return wire.Doc{Ref: prefix + f.rel, Title: docTitle(filepath.Join(folder, f.rel), f.rel), Source: folder,
		Folder: &folder, Path: &f.rel, Updated: &at}
}

// docTitle is a Markdown file's first # heading, or its file name.
func docTitle(path, rel string) string {
	if fh, err := os.Open(path); err == nil {
		defer fh.Close()
		b, _ := io.ReadAll(io.LimitReader(fh, docsTitleBytes))
		fence := false
		for _, l := range strings.Split(string(b), "\n") {
			l = strings.TrimSpace(l)
			if strings.HasPrefix(l, "```") {
				fence = !fence
			}
			if !fence && strings.HasPrefix(l, "# ") {
				if t := strings.TrimSpace(strings.TrimPrefix(l, "# ")); t != "" {
					return cutTitle(t)
				}
			}
		}
	}
	return filepath.Base(rel)
}

// docsLimit is r's limit, checked: 1 to most, def when not said.
func docsLimit(method string, limit *int64, def, most int) (int, error) {
	if limit == nil {
		return def, nil
	}
	if *limit < 1 || *limit > int64(most) {
		return 0, Invalid("%s: limit is 1 to %d", method, most)
	}
	return int(*limit), nil
}

// docsFolders is the folders a request names: one folder on this machine, or all of them.
func (d *Daemon) docsFoldersOf(method string, folder *string) ([]string, error) {
	f := deref(folder)
	if f == "" {
		return nil, nil
	}
	if !slices.Contains(d.folderPaths(), f) {
		return nil, Invalid("%s: %s is not a folder on this machine", method, f)
	}
	return []string{f}, nil
}

// connectorAnswer is one connector's docs, or why it did not answer.
type connectorAnswer struct {
	source wire.DocsSource
	found  []foundDoc
}

// askConnectors calls each mapped connector side by side, at most docsSearchLimit of them:
// with words, its search; without, its recent tool when its map has one, else the search for
// nothing. Each answers in the order of cs.
func (d *Daemon) askConnectors(ctx context.Context, cs []docsConnector, words string) []connectorAnswer {
	out := make([]connectorAnswer, len(cs))
	var wg sync.WaitGroup
	asked := 0
	for i, c := range cs {
		out[i].source = c.source()
		if !c.mapped {
			continue
		}
		if asked >= docsSearchLimit {
			out[i].source.State = wire.DocsSourceStateFailed
			out[i].source.Message = new("Agent Loops asks at most 6 docs connectors at once.")
			continue
		}
		asked++
		wg.Add(1)
		go func() {
			defer wg.Done()
			found, err := d.askConnector(ctx, c, words)
			if err != nil {
				out[i].source.State, out[i].source.Message = wire.DocsSourceStateFailed, new(err.Error())
				log.Printf("docs: %s failed", c.name)
				return
			}
			out[i].found = found
		}()
	}
	wg.Wait()
	return out
}

func (d *Daemon) askConnector(ctx context.Context, c docsConnector, words string) ([]foundDoc, error) {
	s, cwd, err := d.docsServerFor(c.name, c.folder, d.secrets())
	if err != nil {
		return nil, err
	}
	call, key := c.m.Search, c.m.Search.Query
	if words == "" && c.m.Recent != nil && c.m.Recent.Tool != "" {
		call, key = *c.m.Recent, ""
	}
	args := map[string]any{}
	for k, v := range call.Arguments {
		args[k] = v
	}
	if key != "" {
		args[key] = words
	}
	raw, err := callDocsTool(ctx, s, cwd, c.m, call.Tool, args, docsConnectorTimeout)
	if err != nil {
		return nil, err
	}
	found, _, _, err := docsFound(raw, c.m.Result)
	if len(found) > docsConnectorDocs {
		found = found[:docsConnectorDocs]
	}
	return found, err
}

// connectorDoc is the Doc of what a connector found; false when it has no id to read it by.
func connectorDoc(c docsConnector, f foundDoc) (wire.Doc, bool) {
	if f.id == "" {
		return wire.Doc{}, false
	}
	ref := "mcp:" + c.name + "/" + f.id
	switch c.scheme {
	case "notion", "gdrive":
		ref = c.scheme + ":" + f.id
	case "confluence":
		if f.url != nil {
			if u, err := url.Parse(*f.url); err == nil && u.Host != "" {
				ref = "confluence:" + strings.ToLower(u.Host) + "/" + f.id
			}
		}
	}
	title := f.title
	if title == "" {
		title = f.id
	}
	doc := wire.Doc{Ref: ref, Title: cutTitle(title), Source: "mcp:" + c.name, Folder: &c.folder, URL: f.url}
	if t, err := time.Parse(time.RFC3339, f.updated); err == nil {
		at := wire.DateOf(t)
		doc.Updated = &at
	}
	return doc, true
}

// newerFirst orders docs the last updated first, then by title.
func newerFirst(a, b wire.Doc) int {
	switch {
	case a.Updated != nil && b.Updated == nil:
		return -1
	case a.Updated == nil && b.Updated != nil:
		return 1
	case a.Updated != nil && *a.Updated != *b.Updated:
		if *a.Updated > *b.Updated {
			return -1
		}
		return 1
	}
	return strings.Compare(a.Title, b.Title)
}

func (d *Daemon) docsList(ctx context.Context, r wire.DocsListRequest) (wire.DocsList, error) {
	const method = "docs/list"
	limit, err := docsLimit(method, r.Limit, docsListDefault, docsListMost)
	if err != nil {
		return wire.DocsList{}, err
	}
	offset := 0
	if c := deref(r.Cursor); c != "" {
		if offset, err = strconv.Atoi(c); err != nil || offset < 0 {
			return wire.DocsList{}, Invalid("%s: the cursor is not one a list gave", method)
		}
	}
	folders, err := d.docsFoldersOf(method, r.Folder)
	if err != nil {
		return wire.DocsList{}, err
	}
	var only []string
	if s := deref(r.Source); s != "" {
		only = []string{s}
	}
	src := d.docsSourcesOf(folders, only)
	out := wire.DocsList{Docs: []wire.Doc{}, Sources: []wire.DocsSource{}}
	seen := map[string]bool{}
	add := func(doc wire.Doc) {
		if !seen[doc.Ref] {
			seen[doc.Ref] = true
			out.Docs = append(out.Docs, doc)
		}
	}
	for _, f := range src.folders {
		out.Sources = append(out.Sources, folderSource(f))
		prefix := d.docRefPrefix(f)
		for _, file := range folderDocFiles(f) {
			add(d.folderDoc(f, prefix, file))
		}
	}
	for _, a := range d.askConnectors(ctx, src.connectors, "") {
		out.Sources = append(out.Sources, a.source)
		for _, f := range a.found {
			if doc, ok := connectorDoc(connectorOf(src.connectors, a.source.ID), f); ok {
				add(doc)
			}
		}
	}
	slices.SortStableFunc(out.Docs, newerFirst)
	if offset > len(out.Docs) {
		offset = len(out.Docs)
	}
	out.Docs = out.Docs[offset:]
	if len(out.Docs) > limit {
		out.Docs = out.Docs[:limit]
		out.Cursor = new(strconv.Itoa(offset + limit))
	}
	return out, nil
}

func folderSource(f string) wire.DocsSource {
	return wire.DocsSource{ID: f, Kind: wire.DocsSourceKindFolder, Name: filepath.Base(f), Folder: &f, State: wire.DocsSourceStateRead}
}

func connectorOf(cs []docsConnector, id string) docsConnector {
	for _, c := range cs {
		if "mcp:"+c.name == id {
			return c
		}
	}
	return docsConnector{}
}

func (d *Daemon) docsSearch(ctx context.Context, r wire.DocsSearchRequest) (wire.DocsSearch, error) {
	return d.docsSearchIn(ctx, d.docsSourcesOf(nil, r.Sources), r)
}

// docsSearchIn is docs/search over src: every folder's for the wire, one folder's for the
// docs_search tool (#3317).
func (d *Daemon) docsSearchIn(ctx context.Context, src docsSources, r wire.DocsSearchRequest) (wire.DocsSearch, error) {
	const method = "docs/search"
	limit, err := docsLimit(method, r.Limit, docsSearchDefault, docsSearchMost)
	if err != nil {
		return wire.DocsSearch{}, err
	}
	words := strings.Fields(strings.ToLower(r.Query))
	if len(words) == 0 {
		return wire.DocsSearch{}, Invalid("%s: query has no words", method)
	}
	out := wire.DocsSearch{Results: []wire.DocsSearchResult{}, Sources: []wire.DocsSource{}}
	type hit struct {
		result wire.DocsSearchResult
		count  int
	}
	var hits []hit
	seen := map[string]bool{}
	for _, f := range src.folders {
		out.Sources = append(out.Sources, folderSource(f))
		prefix := d.docRefPrefix(f)
		for _, file := range folderDocFiles(f) {
			if seen[prefix+file.rel] {
				continue
			}
			matches, count := searchDocFile(filepath.Join(f, file.rel), words)
			if count > 0 {
				seen[prefix+file.rel] = true
				hits = append(hits, hit{wire.DocsSearchResult{Doc: d.folderDoc(f, prefix, file), Matches: matches}, count})
			}
		}
	}
	for _, a := range d.askConnectors(ctx, src.connectors, strings.TrimSpace(r.Query)) {
		out.Sources = append(out.Sources, a.source)
		for _, f := range a.found {
			doc, ok := connectorDoc(connectorOf(src.connectors, a.source.ID), f)
			if !ok || seen[doc.Ref] {
				continue
			}
			seen[doc.Ref] = true
			res := wire.DocsSearchResult{Doc: doc, Matches: []wire.DocsMatch{}}
			if f.snippet != "" {
				res.Matches = append(res.Matches, wire.DocsMatch{Snippet: cutSnippet(f.snippet)})
			}
			hits = append(hits, hit{res, 1})
		}
	}
	slices.SortStableFunc(hits, func(a, b hit) int {
		if a.count != b.count {
			return b.count - a.count
		}
		return newerFirst(a.result.Doc, b.result.Doc)
	})
	for i := 0; i < len(hits) && i < limit; i++ {
		out.Results = append(out.Results, hits[i].result)
	}
	return out, nil
}

// searchDocFile is the lines of a file that have every word, in any case: the first few, and
// how many.
func searchDocFile(path string, words []string) ([]wire.DocsMatch, int) {
	fh, err := os.Open(path)
	if err != nil {
		return nil, 0
	}
	defer fh.Close()
	sc := bufio.NewScanner(io.LimitReader(fh, docsFileBytes))
	sc.Buffer(make([]byte, 0, 64<<10), docsReadBytes)
	var matches []wire.DocsMatch
	count := 0
	for n := int64(1); sc.Scan(); n++ {
		line := sc.Text()
		lower := strings.ToLower(line)
		all := true
		for _, w := range words {
			if !strings.Contains(lower, w) {
				all = false
				break
			}
		}
		if !all {
			continue
		}
		count++
		if len(matches) < docsMatchesShown {
			matches = append(matches, wire.DocsMatch{Line: new(n), Snippet: cutSnippet(line)})
		}
	}
	return matches, count
}

func cutSnippet(s string) string {
	s = strings.TrimSpace(s)
	if utf8.RuneCountInString(s) <= docsSnippetLimit {
		return s
	}
	return string([]rune(s)[:docsSnippetLimit-1]) + "…"
}

func (d *Daemon) docsRead(ctx context.Context, r wire.DocsReadRequest) (wire.DocsReading, error) {
	return d.docsReadIn(ctx, d.docsSourcesOf(nil, nil), r)
}

// docsReadIn is docs/read over src: every folder's for the wire, one folder's for the
// docs_read tool (#3317).
func (d *Daemon) docsReadIn(ctx context.Context, src docsSources, r wire.DocsReadRequest) (wire.DocsReading, error) {
	const method = "docs/read"
	from, to := int64(1), int64(0)
	if r.From != nil {
		from = *r.From
	}
	if r.To != nil {
		to = *r.To
	}
	if from < 1 || (r.To != nil && to < from) {
		return wire.DocsReading{}, Invalid("%s: from is 1 or more, and to is from or more", method)
	}
	for _, f := range src.folders {
		prefix := d.docRefPrefix(f)
		// A ref from before #4800 is in the old form, <forge>:<repo>/doc/<path>.
		r.Ref = lineage.FullRefText(lineage.KindDoc, r.Ref, "")
		if len(r.Ref) <= len(prefix) || !strings.EqualFold(r.Ref[:len(prefix)], prefix) {
			continue
		}
		rel := r.Ref[len(prefix):]
		file, ok := folderDocFile(f, rel)
		if !ok {
			continue
		}
		fh, err := os.Open(filepath.Join(f, rel))
		if err != nil {
			continue
		}
		b, err := io.ReadAll(io.LimitReader(fh, docsFileBytes))
		_ = fh.Close()
		if err != nil {
			continue
		}
		return docsWindow(d.folderDoc(f, prefix, file), string(b), from, to)
	}
	c, id, ok := connectorFor(src.connectors, r.Ref)
	if !ok {
		return wire.DocsReading{}, Invalid("%s: no doc on this machine has the ref %s", method, r.Ref)
	}
	if !c.mapped {
		return wire.DocsReading{}, Invalid("%s: %s has no map yet; the map-a-docs-server skill writes one", method, c.name)
	}
	s, cwd, err := d.docsServerFor(c.name, c.folder, d.secrets())
	if err != nil {
		return wire.DocsReading{}, Invalid("%s: %s: %v", method, c.name, err)
	}
	args := map[string]any{}
	for k, v := range c.m.Read.Arguments {
		args[k] = v
	}
	args[c.m.Read.ID] = id
	raw, err := callDocsTool(ctx, s, cwd, c.m, c.m.Read.Tool, args, docsConnectorTimeout)
	if err != nil {
		log.Printf("docs: %s read failed", c.name)
		return wire.DocsReading{}, Invalid("%s: %s: %v", method, c.name, err)
	}
	text, err := docsMarkdown(raw)
	if err != nil {
		return wire.DocsReading{}, Invalid("%s: %s: %v", method, c.name, err)
	}
	doc := wire.Doc{Ref: r.Ref, Title: markdownTitle(text, id), Source: "mcp:" + c.name, Folder: &c.folder}
	return docsWindow(doc, text, from, to)
}

// folderDocFile is the doc at rel in folder, when rel is a doc's path there: a regular *.md
// file at the top or under specs/ or docs/, in no hidden folder or node_modules, and reached
// through no link.
func folderDocFile(folder, rel string) (docFile, bool) {
	if rel == "" || filepath.IsAbs(rel) || filepath.ToSlash(filepath.Clean(rel)) != rel ||
		!strings.EqualFold(filepath.Ext(rel), ".md") {
		return docFile{}, false
	}
	parts := strings.Split(rel, "/")
	if len(parts) > 1 && !slices.Contains(docsFolders, parts[0]) {
		return docFile{}, false
	}
	for _, p := range parts {
		if p == ".." || strings.HasPrefix(p, ".") || p == "node_modules" {
			return docFile{}, false
		}
	}
	path := filepath.Join(folder, rel)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return docFile{}, false
	}
	real, err := filepath.EvalSymlinks(path)
	root, rerr := filepath.EvalSymlinks(folder)
	if err != nil || rerr != nil || real != filepath.Join(root, rel) {
		return docFile{}, false
	}
	return docFile{rel: rel, at: info.ModTime(), size: info.Size()}, true
}

// connectorFor is the connector a connector doc's ref names, and the doc's id there.
func connectorFor(cs []docsConnector, ref string) (docsConnector, string, bool) {
	scheme, rest, ok := strings.Cut(ref, ":")
	if !ok || rest == "" {
		return docsConnector{}, "", false
	}
	switch scheme {
	case "mcp":
		name, id, ok := strings.Cut(rest, "/")
		if !ok || id == "" {
			return docsConnector{}, "", false
		}
		for _, c := range cs {
			if c.name == name {
				return c, id, true
			}
		}
	case "confluence", "notion", "gdrive":
		id := rest
		if scheme == "confluence" {
			if _, after, ok := strings.Cut(rest, "/"); ok && after != "" {
				id = after
			}
		}
		// The first mapped connector of the kind, else the first of it.
		var first *docsConnector
		for i, c := range cs {
			if c.scheme != scheme {
				continue
			}
			if c.mapped {
				return c, id, true
			}
			if first == nil {
				first = &cs[i]
			}
		}
		if first != nil {
			return *first, id, true
		}
	}
	return docsConnector{}, "", false
}

// docsMarkdown is a read tool's answer as Markdown, in one way only: its text (each text and
// each resource's text, a blank line between them); when that is a JSON object, its first
// markdown, content, text or body field that is text; else the JSON in a code block.
func docsMarkdown(raw json.RawMessage) (string, error) {
	var result struct {
		Content []struct {
			Type     string `json:"type"`
			Text     string `json:"text"`
			Resource struct {
				Text string `json:"text"`
			} `json:"resource"`
		} `json:"content"`
		Structured any  `json:"structuredContent"`
		IsError    bool `json:"isError"`
	}
	if json.Unmarshal(raw, &result) != nil {
		return "", errors.New("what came back was not MCP")
	}
	var texts []string
	for _, c := range result.Content {
		switch {
		case c.Type == "text" && c.Text != "":
			texts = append(texts, c.Text)
		case c.Type == "resource" && c.Resource.Text != "":
			texts = append(texts, c.Resource.Text)
		}
	}
	text := strings.Join(texts, "\n\n")
	if result.IsError {
		if why := firstLine(text); why != "" {
			return "", errors.New("its read answered: " + why)
		}
		return "", errors.New("its read answered with an error")
	}
	value := result.Structured
	if value == nil && strings.HasPrefix(strings.TrimSpace(text), "{") {
		var v any
		if json.Unmarshal([]byte(text), &v) == nil {
			value = v
		}
	}
	if o, ok := value.(map[string]any); ok {
		for _, k := range []string{"markdown", "content", "text", "body"} {
			if s, ok := o[k].(string); ok && strings.TrimSpace(s) != "" {
				return s, nil
			}
		}
		b, _ := json.MarshalIndent(o, "", "  ")
		return "```json\n" + string(b) + "\n```\n", nil
	}
	return text, nil
}

// markdownTitle is Markdown's first # heading, or else.
func markdownTitle(text, otherwise string) string {
	for _, l := range strings.Split(text, "\n") {
		if l = strings.TrimSpace(l); strings.HasPrefix(l, "# ") {
			if t := strings.TrimSpace(strings.TrimPrefix(l, "# ")); t != "" {
				return cutTitle(t)
			}
		}
	}
	return cutTitle(otherwise)
}

// docsWindow is lines from to to of text (to 0: as far as the limits allow), at most
// docsReadLines lines and docsReadBytes bytes, at least one line; next is the line after
// when it stopped short of the end.
func docsWindow(doc wire.Doc, text string, from, to int64) (wire.DocsReading, error) {
	lines := strings.Split(strings.TrimSuffix(text, "\n"), "\n")
	if text == "" {
		lines = nil
	}
	total := int64(len(lines))
	out := wire.DocsReading{Doc: doc, From: from, Lines: total}
	if total == 0 {
		out.From, out.To = 1, 0
		return out, nil
	}
	if from > total {
		return wire.DocsReading{}, Invalid("docs/read: from is past the end; the doc has %d lines", total)
	}
	last := total
	if to > 0 && to < last {
		last = to
	}
	if last-from+1 > docsReadLines {
		last = from + docsReadLines - 1
	}
	var b strings.Builder
	end := from - 1
	for i := from; i <= last; i++ {
		l := lines[i-1]
		if b.Len()+len(l)+1 > docsReadBytes {
			if end >= from {
				break
			}
			// One line longer than the limit: its start, on a character's edge.
			cut := docsReadBytes - 1
			for cut > 0 && !utf8.RuneStart(l[cut]) {
				cut--
			}
			l = l[:cut]
		}
		b.WriteString(l)
		b.WriteByte('\n')
		end = i
	}
	out.Text, out.To = b.String(), end
	if end < total {
		out.Next = new(end + 1)
	}
	return out, nil
}
