package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Docs maps (#3307): a docs connector proves itself with one real search, as the forge slots
// prove themselves with one real read. Docs servers name their tools as they like (Notion's
// notion-search, Atlassian's searchConfluenceUsingCql, a Drive server's search), so there is
// no fixed contract: an agent writes a small map of each server's search and read tools
// (the ready-made map-a-docs-server skill), beside the mcp.json that names the server, in
// .agents/docs-maps.json:
//
//	{"notion": {
//	  "search": {"tool": "notion-search", "query": "query"},
//	  "read": {"tool": "notion-fetch", "id": "id"},
//	  "results": {"list": "results", "title": "title", "id": "id", "url": "url"}}}
//
// The folder's file wins over the person's for a server both map. A server that its map says
// can search and read fills the Docs slot even when its name says nothing about docs. The
// slot's read calls the search tool once and shows the first doc found. Logged: the server's
// name and a word, never what the search found.

// docsMapsFile is the map's place under a folder's or the person's .agents.
const docsMapsFile = "docs-maps.json"

// docsSearchTimeout is how long one server has for its search, start-up included.
const docsSearchTimeout = 30 * time.Second

// docsSearchLimit is the most servers one read searches.
const docsSearchLimit = 6

// docsMap is one server's map.
type docsMap struct {
	Search docsCall `json:"search"`
	Read   docsCall `json:"read"`
	// Recent is a tool that lists the server's recent docs, for docs/list (#3319); without it
	// the list is the search for nothing.
	Recent *docsCall   `json:"recent,omitempty"`
	Result docsResults `json:"results"`
	// Try is the words the slot's search sends; the folder's name when empty.
	Try string `json:"try,omitempty"`
}

// docsCall is a tool, the argument its words or doc id go in, and fixed arguments.
type docsCall struct {
	Tool      string         `json:"tool"`
	Query     string         `json:"query,omitempty"`
	ID        string         `json:"id,omitempty"`
	Arguments map[string]any `json:"arguments,omitempty"`
}

// docsResults says where a search's docs are in its answer, as dotted paths: List to the
// array (empty: the answer is the array), and each doc's Title, ID and URL, and the Snippet
// and Updated time that docs/search and docs/list show (#3319).
type docsResults struct {
	List    string `json:"list,omitempty"`
	Title   string `json:"title,omitempty"`
	ID      string `json:"id,omitempty"`
	URL     string `json:"url,omitempty"`
	Snippet string `json:"snippet,omitempty"`
	Updated string `json:"updated,omitempty"`
}

// searchesAndReads is whether the map says the server can search and read.
func (m docsMap) searchesAndReads() bool {
	return m.Search.Tool != "" && m.Search.Query != "" && m.Read.Tool != "" && m.Read.ID != ""
}

// digest is the map in a word, so that a changed map is searched again.
func (m docsMap) digest() string {
	b, _ := json.Marshal(m)
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:8])
}

// readDocsMapsFile is the maps in one file, by server name; none when it is missing or bad.
func readDocsMapsFile(path string) map[string]docsMap {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var maps map[string]docsMap
	if json.Unmarshal(b, &maps) != nil {
		return nil
	}
	return maps
}

// docsMaps is the maps that reach folder: the person's, then the folder's over them.
func (d *Daemon) docsMaps(folder string) map[string]docsMap {
	out := map[string]docsMap{}
	if home := d.personalHome(); home != "" {
		for name, m := range readDocsMapsFile(filepath.Join(home, ".agents", docsMapsFile)) {
			out[name] = m
		}
	}
	for name, m := range readDocsMapsFile(filepath.Join(folder, ".agents", docsMapsFile)) {
		out[name] = m
	}
	return out
}

// docsServerRecord is one server's last search, kept in the slot's record.
type docsServerRecord struct {
	wire.DocsServer
	// Map is the digest of the map it searched through.
	Map string `json:"map,omitempty"`
}

// docsSearchesDue is whether a mapped server has not been searched through its map as it is.
func docsSearchesDue(rec *slotRecord, servers []string, maps map[string]docsMap) bool {
	for _, name := range servers {
		m, mapped := maps[name]
		if !mapped || !m.searchesAndReads() {
			continue
		}
		if r := findDocsRecord(rec, name); r == nil || r.Map != m.digest() {
			return true
		}
	}
	return false
}

func findDocsRecord(rec *slotRecord, name string) *docsServerRecord {
	if rec == nil {
		return nil
	}
	for i := range rec.Servers {
		if rec.Servers[i].Name == name {
			return &rec.Servers[i]
		}
	}
	return nil
}

// searchDocsServers is the one real search of each mapped server, side by side.
func (d *Daemon) searchDocsServers(ctx context.Context, folder string, servers []string, maps map[string]docsMap, now time.Time) []docsServerRecord {
	secrets := d.secrets()
	words := filepath.Base(folder)
	var out []docsServerRecord
	var wg sync.WaitGroup
	var mu sync.Mutex
	searched := 0
	for _, name := range servers {
		m, mapped := maps[name]
		if !mapped || !m.searchesAndReads() || searched >= docsSearchLimit {
			continue
		}
		searched++
		wg.Add(1)
		go func() {
			defer wg.Done()
			r := docsServerRecord{DocsServer: wire.DocsServer{Name: name, State: wire.DocsServerStateRead}, Map: m.digest()}
			proof, err := d.searchDocsServer(ctx, name, folder, secrets, m, words)
			if err != nil {
				why := err.Error()
				r.State, r.Message = wire.DocsServerStateFailed, &why
				log.Printf("docs: %s search failed", name)
			} else if proof != nil {
				date := wire.DateOf(now)
				proof.At = &date
				r.Proof = proof
			}
			mu.Lock()
			out = append(out, r)
			mu.Unlock()
		}()
	}
	wg.Wait()
	return out
}

// docsSearchError is a failed search in a sentence.
type docsSearchError string

func (e docsSearchError) Error() string { return string(e) }

// searchDocsServer is one search of the server named name, as a session in folder reaches it.
func (d *Daemon) searchDocsServer(ctx context.Context, name, folder string, secrets map[string]string, m docsMap, words string) (*wire.ConnectorProof, error) {
	s, cwd, err := d.docsServerFor(name, folder, secrets)
	if err != nil {
		return nil, err
	}
	if m.Try != "" {
		words = m.Try
	}
	return searchDocs(ctx, s, cwd, m, words, docsSearchTimeout)
}

// docsServerFor is the server named name as a session in folder reaches it, signed in, and
// the folder it starts in.
func (d *Daemon) docsServerFor(name, folder string, secrets map[string]string) (sdk.McpServer, string, error) {
	s, problem := d.eventServerNamed(name, folder, secrets)
	switch problem {
	case "waiting":
		return sdk.McpServer{}, "", docsSearchError("This folder's mcp.json waits for your approval.")
	case "missingSecret":
		return sdk.McpServer{}, "", docsSearchError("It needs a secret that isn't set.")
	case "oldTransport":
		return sdk.McpServer{}, "", docsSearchError("It speaks SSE, which Agent Loops doesn't.")
	case "notSetUp":
		return sdk.McpServer{}, "", docsSearchError("It isn't in mcp.json.")
	}
	signed := d.withSignIns([]sdk.McpServer{s.filled})
	if len(signed) == 0 {
		return sdk.McpServer{}, "", docsSearchError("It wants a sign-in first.")
	}
	return signed[0], s.cwd, nil
}

// searchDocs connects, checks that the server has the map's tools, calls the search tool
// once with words, and ends: the first doc found, or nil when it found none.
func searchDocs(ctx context.Context, s sdk.McpServer, cwd string, m docsMap, words string, timeout time.Duration) (*wire.ConnectorProof, error) {
	args := map[string]any{}
	for k, v := range m.Search.Arguments {
		args[k] = v
	}
	args[m.Search.Query] = words
	raw, err := callDocsTool(ctx, s, cwd, m, m.Search.Tool, args, timeout)
	if err != nil {
		return nil, err
	}
	return firstDoc(raw, m.Result)
}

// callDocsTool connects, checks that the server has the map's tools and tool, calls tool once
// with args, and ends: what the call answered.
func callDocsTool(ctx context.Context, s sdk.McpServer, cwd string, m docsMap, tool string, args map[string]any, timeout time.Duration) (json.RawMessage, error) {
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var c mcpConn
	switch {
	case s.Stdio != nil:
		sc, err := startStdioMCP(s.Stdio, cwd)
		if err != nil {
			return nil, docsSearchError(mcpFailureOf(err).sentence(timeout))
		}
		c = sc
	case s.Http != nil:
		c = &httpMCP{url: s.Http.Url, headers: s.Http.Headers}
	default:
		return nil, docsSearchError("What came back was not MCP.")
	}
	defer c.end()
	failed := func(err error) error {
		if ctx.Err() != nil {
			err = &mcpCheckFailure{kind: "timedOut"}
		}
		return docsSearchError(mcpFailureOf(err).sentence(timeout))
	}
	if _, err := c.call(ctx, 1, "initialize", map[string]any{"protocolVersion": "2025-06-18", "capabilities": map[string]any{},
		"clientInfo": map[string]any{"name": "Agent Loops", "version": "1"}}); err != nil {
		return nil, failed(err)
	}
	if err := c.notify(ctx, "notifications/initialized"); err != nil {
		return nil, failed(err)
	}
	has := map[string]bool{}
	id := 2
	for cursor := ""; ; id++ {
		params := map[string]any{}
		if cursor != "" {
			params["cursor"] = cursor
		}
		raw, err := c.call(ctx, id, "tools/list", params)
		if err != nil {
			return nil, failed(err)
		}
		var page struct {
			Tools []struct {
				Name string `json:"name"`
			} `json:"tools"`
			NextCursor string `json:"nextCursor"`
		}
		if json.Unmarshal(raw, &page) != nil {
			return nil, docsSearchError("What came back was not MCP.")
		}
		for _, t := range page.Tools {
			has[t.Name] = true
		}
		if page.NextCursor == "" || id > 50 {
			break
		}
		cursor = page.NextCursor
	}
	for _, t := range []string{m.Search.Tool, m.Read.Tool, tool} {
		if !has[t] {
			return nil, docsSearchError(fmt.Sprintf("Its map names %s, a tool it doesn't have.", t))
		}
	}
	raw, err := c.call(ctx, id+1, "tools/call", map[string]any{"name": tool, "arguments": args})
	if err != nil {
		return nil, failed(err)
	}
	return raw, nil
}

// docsTitleLimit is the most a proof's title holds, in characters.
const docsTitleLimit = 120

// firstDoc is the first doc in a tools/call result, found through the map's paths: in its
// structured content, or its first text as JSON, or a resource link it gave; else the first
// line of its text. Nil when the search found none.
func firstDoc(raw json.RawMessage, r docsResults) (*wire.ConnectorProof, error) {
	found, listed, text, err := docsFound(raw, r)
	if err != nil {
		return nil, err
	}
	if listed {
		if len(found) == 0 {
			return nil, nil
		}
		title := found[0].title
		if title == "" {
			title = found[0].id
		}
		if title == "" {
			return nil, docsSearchError("Its map's results.title is not in the first doc the search found.")
		}
		return &wire.ConnectorProof{Title: cutTitle(title), URL: found[0].url}, nil
	}
	for _, f := range found {
		if f.title != "" {
			return &wire.ConnectorProof{Title: cutTitle(f.title), URL: f.url}, nil
		}
	}
	if line := firstLine(text); line != "" {
		return &wire.ConnectorProof{Title: line}, nil
	}
	return nil, nil
}

// foundDoc is one doc in what a search or a list answered, as the map finds it.
type foundDoc struct {
	title, id, snippet, updated string
	// url is its web address, when it is one.
	url *string
}

// docsFound is the docs in a tools/call result: listed is true when it was a list (in its
// structured content, or its first text as JSON), at the map's paths; else the resource links
// it gave, by their address. text is its first text.
func docsFound(raw json.RawMessage, r docsResults) (found []foundDoc, listed bool, text string, err error) {
	var result struct {
		Content []struct {
			Type  string `json:"type"`
			Text  string `json:"text"`
			URI   string `json:"uri"`
			Name  string `json:"name"`
			Title string `json:"title"`
		} `json:"content"`
		Structured any  `json:"structuredContent"`
		IsError    bool `json:"isError"`
	}
	if json.Unmarshal(raw, &result) != nil {
		return nil, false, "", docsSearchError("What came back was not MCP.")
	}
	for _, c := range result.Content {
		if c.Type == "text" && text == "" {
			text = c.Text
		}
	}
	if result.IsError {
		why := firstLine(text)
		if why == "" {
			return nil, false, text, docsSearchError("Its search answered with an error.")
		}
		return nil, false, text, docsSearchError("Its search answered: " + why)
	}
	value := result.Structured
	if value == nil && text != "" {
		var v any
		if json.Unmarshal([]byte(text), &v) == nil {
			value = v
		}
	}
	if value != nil {
		items, isList := pathIn(value, r.List).([]any)
		if !isList {
			return nil, false, text, docsSearchError("Its map's results.list is not a list in what the search answered.")
		}
		for _, item := range items {
			f := foundDoc{
				title:   stringAt(item, r.Title, "title", "name"),
				id:      stringAt(item, r.ID, "id"),
				snippet: stringAt(item, r.Snippet, "snippet", "excerpt", "highlight", "summary"),
				updated: stringAt(item, r.Updated, "updated", "updatedAt", "updated_at", "lastModified", "last_edited_time", "modifiedTime"),
			}
			if u := stringAt(item, r.URL, "url"); webAddress(u) {
				f.url = &u
			}
			found = append(found, f)
		}
		return found, true, text, nil
	}
	for _, c := range result.Content {
		if c.Type == "resource_link" {
			title := c.Title
			if title == "" {
				title = c.Name
			}
			f := foundDoc{title: title, id: c.URI}
			if webAddress(c.URI) {
				f.url = &c.URI
			}
			found = append(found, f)
		}
	}
	return found, false, text, nil
}

func webAddress(u string) bool {
	return strings.HasPrefix(u, "https://") || strings.HasPrefix(u, "http://")
}

// pathIn is the value at a dotted path; the value itself for "".
func pathIn(v any, path string) any {
	if path == "" {
		return v
	}
	for _, key := range strings.Split(path, ".") {
		o, ok := v.(map[string]any)
		if !ok {
			return nil
		}
		v = o[key]
	}
	return v
}

// stringAt is the text at path in v, or at the first of the fallbacks when path is "".
func stringAt(v any, path string, fallbacks ...string) string {
	paths := []string{path}
	if path == "" {
		paths = fallbacks
	}
	for _, p := range paths {
		switch s := pathIn(v, p).(type) {
		case string:
			if strings.TrimSpace(s) != "" {
				return strings.TrimSpace(s)
			}
		case float64:
			return fmt.Sprint(s)
		}
	}
	return ""
}

func firstLine(text string) string {
	for _, l := range strings.Split(text, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			return cutTitle(l)
		}
	}
	return ""
}

func cutTitle(s string) string {
	if utf8.RuneCountInString(s) <= docsTitleLimit {
		return s
	}
	return string([]rune(s)[:docsTitleLimit-1]) + "…"
}
