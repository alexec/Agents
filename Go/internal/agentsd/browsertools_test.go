package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/alexec/agents/Go/internal/browser"
	"github.com/alexec/agents/Go/wire"
)

// The browser tools (#3534): Playwright's tools on the `agents` server, one agent at a
// time under browser:agents, each result through the machine's filter.

// fakePlaywright stands in for one @playwright/mcp: it says what it was asked and what it
// was started on, and answers with a page that has the card number in it, and a picture.
type fakePlaywright struct {
	start  browserStart
	mu     sync.Mutex
	calls  []string
	closed bool
}

func (f *fakePlaywright) callTool(_ context.Context, name string, args map[string]json.RawMessage) (*mcp.CallToolResult, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.closed {
		return nil, errors.New("closed")
	}
	f.calls = append(f.calls, name+" "+string(args["url"]))
	if name == "browser_close" {
		return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: "No page is open."}}}, nil
	}
	return &mcp.CallToolResult{Content: []mcp.Content{
		&mcp.TextContent{Text: "- textbox \"Card number\": 4111 1111 1111 1111\n- text: Welcome"},
		&mcp.ImageContent{Data: []byte("png!"), MIMEType: "image/png"},
		&mcp.EmbeddedResource{Resource: &mcp.ResourceContents{URI: "file:///x", Text: "4111111111111111"}},
	}}, nil
}

func (f *fakePlaywright) isClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

func (f *fakePlaywright) asked() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.calls...)
}

func (f *fakePlaywright) close() {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
}

// fakeBrowser gives the daemon an address with no Chromium behind it, and a fakePlaywright
// for each session started; it says each one, in order.
func fakeBrowser(t *testing.T) (endpoint func(moveTo string) string, started func() []*fakePlaywright) {
	t.Helper()
	ep := "ws://127.0.0.1:1/devtools/browser/one"
	var mu sync.Mutex
	var all []*fakePlaywright
	oldEndpoint, oldOpen := browserEndpoint, openBrowserSession
	browserEndpoint = func(*browser.Machine) (string, error) {
		mu.Lock()
		defer mu.Unlock()
		return ep, nil
	}
	openBrowserSession = func(_ context.Context, s browserStart) (browserSession, error) {
		mu.Lock()
		defer mu.Unlock()
		f := &fakePlaywright{start: s}
		all = append(all, f)
		return f, nil
	}
	oldHome := toolsHome
	if toolsHome == "" {
		toolsHome = t.TempDir()
	}
	t.Cleanup(func() { browserEndpoint, openBrowserSession, toolsHome = oldEndpoint, oldOpen, oldHome })
	endpoint = func(moveTo string) string {
		mu.Lock()
		defer mu.Unlock()
		if moveTo != "" {
			ep = moveTo
		}
		return ep
	}
	return endpoint, func() []*fakePlaywright {
		mu.Lock()
		defer mu.Unlock()
		return append([]*fakePlaywright(nil), all...)
	}
}

type browserReply struct {
	Content []struct {
		Type     string `json:"type"`
		Text     string `json:"text"`
		Data     string `json:"data"`
		MimeType string `json:"mimeType"`
	} `json:"content"`
	IsError bool `json:"isError"`
}

func (m *mcpClient) browserTool(id int, name string, args map[string]any) browserReply {
	m.t.Helper()
	_, r := m.post("tools/call", map[string]any{"name": "mcp__agents__" + name, "arguments": args}, id)
	var res browserReply
	if err := json.Unmarshal(r["result"], &res); err != nil || len(res.Content) == 0 {
		m.t.Fatalf("%s: %s %s", name, r["result"], r["error"])
	}
	return res
}

func TestTheBrowserToolsAreListed(t *testing.T) {
	fakeBrowser(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	m := appClient(t, d, seeded(t, d, t.TempDir(), nil).ID)
	m.post("initialize", map[string]any{}, 1)
	_, list := m.post("tools/list", nil, 2)
	var tools struct {
		Tools []struct {
			Name        string          `json:"name"`
			Description string          `json:"description"`
			InputSchema json.RawMessage `json:"inputSchema"`
		} `json:"tools"`
	}
	json.Unmarshal(list["result"], &tools)
	got := map[string]string{}
	for _, tool := range tools.Tools {
		if strings.HasPrefix(tool.Name, "browser_") {
			got[tool.Name] = tool.Description
			if len(tool.InputSchema) == 0 {
				t.Fatalf("%s has no schema", tool.Name)
			}
		}
	}
	for _, name := range []string{"browser_navigate", "browser_snapshot", "browser_click", "browser_type", "browser_take_screenshot", "browser_tabs"} {
		if got[name] == "" {
			t.Fatalf("no %s in %v", name, got)
		}
	}
	if !strings.HasSuffix(got["browser_navigate"], browserNavigateNote) || strings.Contains(got["browser_click"], browserNavigateNote) {
		t.Fatal(got["browser_navigate"])
	}
	// A host with nowhere to install the browser lists none of them.
	toolsHome = ""
	_, list = m.post("tools/list", nil, 3)
	if strings.Contains(string(list["result"]), `"browser_navigate"`) {
		t.Fatal("listed with no tools home")
	}
	if _, r := m.post("tools/call", map[string]any{"name": "mcp__agents__browser_navigate", "arguments": map[string]any{"url": "https://example.com"}}, 4); !strings.Contains(string(r["error"]), "No tool called") {
		t.Fatalf("%s", r["error"])
	}
}

func TestAnAgentDrivesTheBrowserUnderItsLease(t *testing.T) {
	endpoint, started := fakeBrowser(t)
	fakeRuntimes(t)
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	dir := t.TempDir()
	titled := func(title string) func(*wire.Agent) { return func(a *wire.Agent) { a.Title = &title } }
	firstAgent := seeded(t, d, dir, titled("Sign up"))
	secondAgent := seeded(t, d, dir, titled("Pay"))
	first, second := appClient(t, d, firstAgent.ID), appClient(t, d, secondAgent.ID)
	first.post("initialize", map[string]any{}, 1)
	second.post("initialize", map[string]any{}, 1)
	d.browser.Filter.Hide("CARD", "4111111111111111")

	r := first.browserTool(2, "browser_navigate", map[string]any{"url": "https://example.com"})
	if r.IsError || len(r.Content) != 3 {
		t.Fatalf("%+v", r)
	}
	// The card number is out of the text; the picture goes through (no mask yet); the
	// resource, which the filter does not read, is left out.
	if r.Content[0].Text != "- textbox \"Card number\": <secret CARD ending 1111>\n- text: Welcome" {
		t.Fatal(r.Content[0].Text)
	}
	if r.Content[1].Type != "image" || r.Content[1].Data != "cG5nIQ==" || r.Content[1].MimeType != "image/png" {
		t.Fatalf("%+v", r.Content[1])
	}
	if r.Content[2].Type != "text" || strings.Contains(r.Content[2].Text, "4111") {
		t.Fatalf("%+v", r.Content[2])
	}
	if !d.holdsBrowser(firstAgent.ID) {
		t.Fatal("the first call took no lease")
	}
	// Started once, on the machine's browser, in the agent's folder, its output in the cache.
	s := started()
	if len(s) != 1 || s[0].start.endpoint != endpoint("") || s[0].start.cwd != folderPath(&firstAgent) ||
		!strings.HasPrefix(s[0].start.output, d.Store.Loc.Cache) || !strings.Contains(s[0].start.output, string(firstAgent.ID)) {
		t.Fatalf("%+v", s)
	}
	if fi, err := os.Stat(s[0].start.output); err != nil || !fi.IsDir() {
		t.Fatal(err)
	}
	// Playwright's own failure is the agent's to read, not a broken session.
	if r := first.browserTool(3, "browser_close", nil); !r.IsError || r.Content[0].Text != "No page is open." {
		t.Fatalf("%+v", r)
	}
	if s := started(); len(s) != 1 || len(s[0].asked()) != 2 || s[0].asked()[0] != `browser_navigate "https://example.com"` {
		t.Fatalf("%+v", s[0].asked())
	}

	// The second agent waits in line, told so, with no Playwright of its own yet.
	r = second.browserTool(2, "browser_snapshot", nil)
	if r.IsError || !strings.HasPrefix(r.Content[0].Text, "This machine's browser is held by “Sign up” until ") ||
		!strings.Contains(r.Content[0].Text, "You are 1st in line.") {
		t.Fatalf("%+v", r)
	}
	if len(started()) != 1 {
		t.Fatal("started a Playwright for an agent in line")
	}

	// Chromium started again (an idle stop, a crash): a new Playwright on the new address.
	endpoint("ws://127.0.0.1:1/devtools/browser/two")
	first.browserTool(4, "browser_snapshot", nil)
	if s := started(); len(s) != 2 || !s[0].isClosed() || s[1].start.endpoint != endpoint("") {
		t.Fatalf("%+v", s)
	}

	// The turn's end lets go of both: the Playwright ends, its output goes, and the lease
	// goes to the one in line.
	output := started()[1].start.output
	d.endBrowserDrive(firstAgent.ID)
	if s := started(); !s[1].isClosed() {
		t.Fatal("the Playwright outlived the turn")
	}
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		t.Fatal("the output outlived the turn", err)
	}
	if d.holdsBrowser(firstAgent.ID) || !d.holdsBrowser(secondAgent.ID) {
		t.Fatal("the lease did not go on")
	}
	// The grant wakes the second agent with a new token, so its drive starts here.
	if _, err := d.browserDriveFor(context.Background(), secondAgent.ID, folderPath(&secondAgent)); err != nil || len(started()) != 3 {
		t.Fatal(err)
	}
	// The host's stop ends every Playwright.
	d.stopBrowserDrives()
	if s := started(); !s[2].isClosed() {
		t.Fatal("a Playwright outlived the host")
	}
}

func TestABrowserThatDoesNotStartSaysWhy(t *testing.T) {
	fakeBrowser(t)
	browserEndpoint = func(*browser.Machine) (string, error) {
		return "", errors.New("downloading Chromium failed: no network")
	}
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	if r := m.browserTool(2, "browser_navigate", map[string]any{"url": "https://example.com"}); !r.IsError ||
		r.Content[0].Text != "The browser did not start: downloading Chromium failed: no network" {
		t.Fatalf("%+v", r)
	}
}

func TestABrowserToolIsAMethodOfItsOwn(t *testing.T) {
	for tool, want := range map[string]string{
		"browser_navigate": "browser/navigate", "browser_take_screenshot": "browser/takeScreenshot",
		"browser_navigate_back": "browser/navigateBack", "show_file": "files/show",
	} {
		if got := appToolMethod(tool); got != want {
			t.Fatal(tool, got)
		}
	}
	if name, ok := browserToolNamed("mcp__agents__browser_network_requests"); !ok || name != "browser_network_requests" {
		t.Fatal(name)
	}
	if name, ok := browserToolNamed("mcp__agents__browser_network_request"); !ok || name != "browser_network_request" {
		t.Fatal(name)
	}
	if _, ok := browserToolNamed("mcp__agents__show_file"); ok {
		t.Fatal("show_file is not a browser tool")
	}
}

// The list is the pinned @playwright/mcp's: after a change to the pin, run
// scripts/browser-tools.sh.
func TestTheBrowserToolsMatchThePin(t *testing.T) {
	var list browserToolList
	if err := json.Unmarshal(browserToolsFile, &list); err != nil {
		t.Fatal(err)
	}
	b, err := os.ReadFile(filepath.Join("browsertoolset", "manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		Package        string `json:"package"`
		PackageVersion string `json:"packageVersion"`
	}
	json.Unmarshal(b, &manifest)
	if list.Package != manifest.Package || list.Version != manifest.PackageVersion {
		t.Fatalf("browsertools.json is %s %s, the pin %s %s: run scripts/browser-tools.sh", list.Package, list.Version, manifest.Package, manifest.PackageVersion)
	}
	// Playwright's, and the app's own fill_secret (#3530).
	tools, names := browserTools()
	if len(tools) != len(list.Tools)+1 || len(names) != len(tools) || len(tools) < 20 {
		t.Fatalf("%d tools, %d names", len(tools), len(names))
	}
}

// Playwright's links into its output folder, as 0.0.83 writes them, name the tool that
// reads the file through the filter instead.
func TestPlaywrightsFilesAreNotLinked(t *testing.T) {
	const out = "/cache/browser/output/A1"
	in := "### Snapshot\n- [Snapshot](/cache/browser/output/A1/page-2026-11-05T17-40-49-901Z.yml)\n" +
		"### Events\n- New console entries: /cache/browser/output/A1/console-2026-11-05T17-40-49-716Z.log#L1\n" +
		"### Result\n- [Screenshot of viewport](/cache/browser/output/A1/page-1.png)\n" +
		"// Screenshot viewport and save it as /cache/browser/output/A1/page-1.png\n" +
		"  path: '/cache/browser/output/A1/page-1.png',\n" +
		"- [Saved](/home/me/project/shot.png)"
	want := "### Snapshot\n- Snapshot (call browser_snapshot to read the page)\n" +
		"### Events\n- New console entries: (call browser_console_messages to read them)\n" +
		"### Result\n- Screenshot of viewport (the image is in this result)\n" +
		"// Screenshot viewport and save it as (the image is in this result)\n" +
		"  path: '(the image is in this result)',\n" +
		"- [Saved](/home/me/project/shot.png)"
	if got := outputLinks(in, out); got != want {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
	if got := outputLinks("/cache/browser/output/A10/x.yml", out); got != "/cache/browser/output/A10/x.yml" {
		t.Fatal(got)
	}
}
