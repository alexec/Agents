package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/alexec/agents/Go/internal/agentsd/skillcatalog"
)

// fill_secret (#3530): the value goes to the page and never back to the agent.

const filledValue = "hunter2-correct-horse"

// fillPage stands in for one @playwright/mcp on a page with a password field: it answers
// as 0.0.83 does, with the value typed in the code it ran and in the page's snapshot.
type fillPage struct {
	mu       sync.Mutex
	calls    []map[string]json.RawMessage
	names    []string
	value    string // the field's value
	filled   bool   // the field has the fill's mark
	noMask   bool   // the page will not let the field be masked
	navigate bool   // the page went somewhere else
}

func (p *fillPage) callTool(_ context.Context, name string, args map[string]json.RawMessage) (*mcp.CallToolResult, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.calls, p.names = append(p.calls, args), append(p.names, name)
	text := func(s string) *mcp.CallToolResult { return &mcp.CallToolResult{Content: []mcp.Content{&mcp.TextContent{Text: s}}} }
	switch name {
	case "browser_type":
		json.Unmarshal(args["text"], &p.value)
		return text("### Ran Playwright code\n```js\nawait page.getByRole('textbox', { name: 'Password' }).fill('" + p.value + "');\n```"), nil
	case "browser_evaluate":
		var fn string
		json.Unmarshal(args["function"], &fn)
		// Playwright says the code it ran after the result, every word in it.
		text := func(s string) *mcp.CallToolResult { return text(s + "\n### Ran Playwright code\n" + fn) }
		switch {
		case fn == maskField && p.noMask:
			return &mcp.CallToolResult{IsError: true, Content: []mcp.Content{&mcp.TextContent{Text: "Error: element is detached"}}}, nil
		case fn == maskField:
			p.filled = true
			return text("### Result\n\"agents-masked\""), nil
		case fn == filledCheck && p.filled && !p.navigate:
			return text("### Result\n\"agents-filled\""), nil
		case fn == filledCheck:
			return text("### Result\n\"agents-clear\""), nil
		}
		return text("### Result\n\"" + p.value + "\""), nil
	case "browser_navigate":
		p.navigate = true
	}
	return text("- textbox \"Password\": " + p.value), nil
}

func (p *fillPage) close() {}

func (p *fillPage) asked() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.names...)
}

// fillSetUp is a host with the machine's browser on a fillPage, and the person's secrets.
func fillSetUp(t *testing.T, secrets map[string]string) (*mcpClient, *fillPage, *Daemon) {
	t.Helper()
	fakeBrowser(t)
	page := &fillPage{}
	openBrowserSession = func(context.Context, browserStart) (browserSession, error) { return page, nil }
	home := t.TempDir()
	t.Setenv("AGENTS_PERSONAL_HOME", home)
	path := skillcatalog.SecretsPath(home)
	os.MkdirAll(filepath.Dir(path), 0o700)
	env, _ := skillcatalog.LoadSecretsForChange(path)
	for k, v := range secrets {
		env.Set(k, v)
	}
	if err := env.Save(path); err != nil {
		t.Fatal(err)
	}
	d, _ := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	m := appClient(t, d, seeded(t, d, t.TempDir(), nil).ID)
	m.post("initialize", map[string]any{}, 1)
	return m, page, d
}

// replyText is every text of a reply, together.
func replyText(r browserReply) string {
	var b strings.Builder
	for _, c := range r.Content {
		b.WriteString(c.Text)
	}
	return b.String()
}

func TestFillSecretIsListedWithTheBrowserTools(t *testing.T) {
	m, _, _ := fillSetUp(t, nil)
	_, list := m.post("tools/list", nil, 2)
	if !strings.Contains(string(list["result"]), `"name":"fill_secret"`) {
		t.Fatal("no fill_secret")
	}
	if got := appToolMethod(fillSecretName); got != "secrets/fill" {
		t.Fatal(got)
	}
}

func TestFillSecretTypesTheValueAndNeverSaysIt(t *testing.T) {
	m, page, d := fillSetUp(t, map[string]string{"GITLAB_PASSWORD": filledValue})
	r := m.browserTool(2, "fill_secret", map[string]any{"secret": "GITLAB_PASSWORD", "element": "Password field", "target": "e12"})
	if r.IsError || replyText(r) != "GITLAB_PASSWORD filled." {
		t.Fatalf("%+v", r)
	}
	// Typed into the field the agent named, then masked there.
	if got := page.asked(); len(got) != 2 || got[0] != "browser_type" || got[1] != "browser_evaluate" {
		t.Fatal(got)
	}
	if page.value != filledValue || string(page.calls[0]["target"]) != `"e12"` || string(page.calls[1]["target"]) != `"e12"` {
		t.Fatalf("%q %s", page.value, page.calls[1]["target"])
	}
	// A page read has the value out.
	if r := m.browserTool(3, "browser_snapshot", nil); strings.Contains(replyText(r), filledValue) ||
		replyText(r) != "- textbox \"Password\": <secret GITLAB_PASSWORD>" {
		t.Fatalf("%+v", r)
	}
	// A script on the page is refused; so is code, and a result written to a file.
	if r := m.browserTool(4, "browser_evaluate", map[string]any{"function": "() => document.querySelector('input').value"}); !r.IsError ||
		!strings.Contains(replyText(r), "refused on a page with a secret filled in") {
		t.Fatalf("%+v", r)
	}
	if r := m.browserTool(5, "browser_run_code_unsafe", map[string]any{"code": "async (page) => 1"}); !r.IsError {
		t.Fatalf("%+v", r)
	}
	if r := m.browserTool(6, "browser_snapshot", map[string]any{"filename": "page.yml"}); !r.IsError || !strings.Contains(replyText(r), "filename") {
		t.Fatalf("%+v", r)
	}
	// Once the page navigates, a script runs again, its result filtered as ever.
	m.browserTool(7, "browser_navigate", map[string]any{"url": "https://example.com"})
	if r := m.browserTool(8, "browser_evaluate", map[string]any{"function": "() => 1"}); r.IsError || strings.Contains(replyText(r), filledValue) {
		t.Fatalf("%+v", r)
	}
	// The record has the name and the field, never the value.
	assertNotUnder(t, d.Store.Loc.Root, filledValue)
}

func TestFillSecretAsksForAMissingSecretFirst(t *testing.T) {
	m, page, d := fillSetUp(t, map[string]string{"PIN": "123"})
	r := m.browserTool(2, "fill_secret", map[string]any{"secret": "GITLAB_PASSWORD", "target": "e12"})
	if !r.IsError || replyText(r) != "GITLAB_PASSWORD is not set. Ask the person for it with ask_secret, then call fill_secret again." {
		t.Fatalf("%+v", r)
	}
	// Refused before the lease: nothing started, nothing held.
	if len(page.asked()) != 0 || d.browser.Filter.Hides() {
		t.Fatal(page.asked())
	}
	if r := m.browserTool(3, "fill_secret", map[string]any{"secret": "PIN", "target": "e12"}); !r.IsError || !strings.Contains(replyText(r), "shorter than four") {
		t.Fatalf("%+v", r)
	}
	if r := m.browserTool(4, "fill_secret", map[string]any{"secret": "PIN"}); !r.IsError || !strings.Contains(replyText(r), "`target`") {
		t.Fatalf("%+v", r)
	}
}

func TestAFieldThatCannotBeMaskedIsEmptiedAgain(t *testing.T) {
	m, page, _ := fillSetUp(t, map[string]string{"GITLAB_PASSWORD": filledValue})
	page.noMask = true
	r := m.browserTool(2, "fill_secret", map[string]any{"secret": "GITLAB_PASSWORD", "target": "#password", "submit": true})
	if !r.IsError || strings.Contains(replyText(r), filledValue) || !strings.Contains(replyText(r), "taken out again") {
		t.Fatalf("%+v", r)
	}
	if got := page.asked(); len(got) != 3 || got[2] != "browser_type" || page.value != "" {
		t.Fatal(got, page.value)
	}
}

func TestFillSecretPressesEnterAfterTheMask(t *testing.T) {
	m, page, _ := fillSetUp(t, map[string]string{"GITLAB_PASSWORD": filledValue})
	r := m.browserTool(2, "fill_secret", map[string]any{"secret": "GITLAB_PASSWORD", "target": "e12", "submit": true})
	if r.IsError || replyText(r) != "GITLAB_PASSWORD filled, and Enter pressed." {
		t.Fatalf("%+v", r)
	}
	if got := page.asked(); len(got) != 3 || got[2] != "browser_press_key" {
		t.Fatal(got)
	}
}

// assertNotUnder fails when any file under root holds s.
func assertNotUnder(t *testing.T, root, s string) {
	t.Helper()
	filepath.Walk(root, func(path string, fi os.FileInfo, err error) error {
		if err != nil || fi.IsDir() {
			return nil
		}
		if b, err := os.ReadFile(path); err == nil && strings.Contains(string(b), s) {
			t.Errorf("%s holds the value", path)
		}
		return nil
	})
}

// #3531: a card secret is filled a part at a time, and once one part is in the page every
// part is out of what the agent reads, the CVC as a whole number only.
func TestACardIsFilledAPartAtATime(t *testing.T) {
	card := `{"number":"4242424242424242","expiry":"09/31","cvc":"737","name":"Sam Lee","zip":"94110"}`
	m, page, d := fillSetUp(t, map[string]string{"SHOP_CARD": card})
	r := m.browserTool(2, "fill_secret", map[string]any{"secret": "SHOP_CARD", "target": "e7"})
	if !r.IsError || !strings.Contains(replyText(r), "is a card. Name the part") || len(page.asked()) != 0 {
		t.Fatalf("%+v", r)
	}
	for i, c := range []struct{ part, typed string }{
		{"number", "4242424242424242"}, {"exp_month", "09"}, {"exp_year", "2031"}, {"expiry", "09/31"}, {"cvc", "737"}, {"zip", "94110"},
	} {
		r := m.browserTool(3+i, "fill_secret", map[string]any{"secret": "SHOP_CARD", "part": c.part, "target": "e7"})
		if r.IsError || replyText(r) != "SHOP_CARD "+c.part+" filled." || page.value != c.typed {
			t.Fatalf("%s: %+v %q", c.part, r, page.value)
		}
	}
	page.value = "4242 4242 4242 4242, 09/31, 737, Sam Lee, 94110, $73.70"
	got := replyText(m.browserTool(20, "browser_snapshot", nil))
	want := "- textbox \"Password\": <secret SHOP_CARD.number ending 4242>, <secret SHOP_CARD.expiry>, <secret SHOP_CARD.cvc>, " +
		"<secret SHOP_CARD.name>, <secret SHOP_CARD.zip>, $73.70"
	if got != want {
		t.Fatalf("got %q", got)
	}
	assertNotUnder(t, d.Store.Loc.Root, "4242424242424242")
	assertNotUnder(t, d.Store.Loc.Root, `"cvc":"737"`)
}

func TestAPartIsOnlyForACard(t *testing.T) {
	m, page, _ := fillSetUp(t, map[string]string{"GITLAB_PASSWORD": filledValue})
	r := m.browserTool(2, "fill_secret", map[string]any{"secret": "GITLAB_PASSWORD", "part": "cvc", "target": "e7"})
	if !r.IsError || !strings.Contains(replyText(r), "is not a card") || len(page.asked()) != 0 {
		t.Fatalf("%+v", r)
	}
}
