package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// pair_web_page (#4214): the agent's tab opens the web page with the control plane's code,
// and the agent is never told the code.
func TestPairWebPageOpensThePageAndNeverSaysTheCode(t *testing.T) {
	m, page, d := fillSetUp(t, nil)
	const url = "http://localhost:8792/#code=agents-control%3A1%3Asecret"
	var mu sync.Mutex
	asked := 0
	ask := askControl(func(_ context.Context, method string, _ any) (json.RawMessage, error) {
		if method != wire.CallMachinePairWebPage.Name {
			return json.RawMessage(`{}`), nil
		}
		mu.Lock()
		asked++
		mu.Unlock()
		return json.Marshal(wire.WebPagePairing{URL: url})
	})
	d.askControl.Store(&ask)
	_, list := m.post("tools/list", nil, 2)
	if !strings.Contains(string(list["result"]), `"name":"pair_web_page"`) {
		t.Fatal("no pair_web_page")
	}
	r := m.browserTool(3, "pair_web_page", map[string]any{})
	if r.IsError || strings.Contains(replyText(r), "secret") || !strings.Contains(replyText(r), "open") {
		t.Fatalf("%+v", r)
	}
	mu.Lock()
	defer mu.Unlock()
	if asked != 1 {
		t.Fatal(asked)
	}
	names := page.asked()
	if len(names) != 1 || names[0] != "browser_navigate" || string(page.calls[0]["url"]) != `"`+url+`"` {
		t.Fatalf("%v %v", names, page.calls)
	}
}

func TestPairWebPageSaysWhyTheControlPlaneRefused(t *testing.T) {
	m, page, d := fillSetUp(t, nil)
	ask := askControl(func(_ context.Context, method string, _ any) (json.RawMessage, error) {
		if method != wire.CallMachinePairWebPage.Name {
			return json.RawMessage(`{}`), nil
		}
		return nil, errors.New("Only the machine this control plane runs on pairs its browser with the web page.")
	})
	d.askControl.Store(&ask)
	r := m.browserTool(2, "pair_web_page", map[string]any{})
	if !r.IsError || !strings.Contains(replyText(r), "Only the machine") || len(page.asked()) != 0 {
		t.Fatalf("%+v %v", r, page.asked())
	}
}
