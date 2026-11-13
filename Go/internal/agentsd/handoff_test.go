package agentsd

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/wire"
)

// hand_to_person (#3529): the person gets the page for one step, the agent's browser calls
// wait for their answer, and the answer says what to do next.

// handOffSetUp is a host with the machine's browser, and an agent in a turn of its own.
func handOffSetUp(t *testing.T) (*mcpClient, *conn, *Daemon, wire.UUID) {
	t.Helper()
	fakeBrowser(t)
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	t.Cleanup(d.Shutdown)
	a := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil })
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	return m, c, d, a.ID
}

func inTurn(d *Daemon, id wire.UUID) {
	l := d.live(id)
	l.mu.Lock()
	l.inTurn = true
	l.mu.Unlock()
}

func pendingHandOff(t *testing.T, c *conn) wire.ElicitationRequest {
	t.Helper()
	var pending []wire.ElicitationRequest
	waitFor(t, "the card", func() bool {
		json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
		return len(pending) == 1
	})
	return pending[0]
}

var captcha = map[string]any{"step": "Solve the CAPTCHA", "reason": "The sign-up form needs a person to pass its check."}

func TestHandToPersonIsListedWithTheBrowserTools(t *testing.T) {
	m, _, _, _ := handOffSetUp(t)
	_, list := m.post("tools/list", nil, 2)
	if !strings.Contains(string(list["result"]), `"name":"hand_to_person"`) {
		t.Fatal("no hand_to_person")
	}
	if got := appToolMethod(handToPersonName); got != "browser/handToPerson" {
		t.Fatal(got)
	}
	if got := toolTimeKind("mcp__agents__hand_to_person"); got != "person" {
		t.Fatal(got)
	}
}

func TestTheAgentHandsAStepToThePerson(t *testing.T) {
	m, c, d, id := handOffSetUp(t)
	if r := m.browserTool(2, "hand_to_person", captcha); !r.IsError || replyText(r) != "A step can only be handed to the person while this agent is working." {
		t.Fatalf("%+v", r)
	}
	if r := m.browserTool(3, "hand_to_person", map[string]any{"reason": "x"}); !r.IsError || !strings.Contains(replyText(r), "say in `step`") {
		t.Fatalf("%+v", r)
	}
	inTurn(d, id)
	answered := make(chan browserReply, 1)
	go func() { answered <- m.browserTool(4, "hand_to_person", captcha) }()
	req := pendingHandOff(t, c)
	if h := req.HandOff; h == nil || h.Step != "Solve the CAPTCHA" || h.Reason == nil || *h.Reason != captcha["reason"] {
		t.Fatalf("%+v", req)
	}
	if req.Message == nil || *req.Message != "Solve the CAPTCHA" {
		t.Fatalf("%+v", req.Message)
	}
	// A notification answers it in one tap, as any one-choice question.
	if got := formAnswers(req); len(got) != 2 || got[0].Title != "Done" || got[1].Title != "Can't do it" {
		t.Fatalf("%+v", got)
	}
	// The agent's other browser calls wait for the person.
	if r := m.browserTool(5, "browser_snapshot", nil); !r.IsError || !strings.HasPrefix(replyText(r), `The person has the page, to "Solve the CAPTCHA".`) {
		t.Fatalf("%+v", r)
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": req.ID, "action": "accept",
		"content": map[string]any{"outcome": "cannot", "outcome_note": "It wants a phone number."}})
	r := <-answered
	if r.IsError || replyText(r) != `The person could not do "Solve the CAPTCHA". They said: It wants a phone number. The page is yours again. Try another way, or say what you cannot do without it.` {
		t.Fatalf("%+v", r)
	}
	if d.handOffOpen(id) != nil {
		t.Fatal("still open")
	}
}

func TestDoneGivesThePageBack(t *testing.T) {
	if got := handOffNoteFor("Sign in to GitLab", wire.AnswerElicitationRequestActionAccept,
		map[string]wire.JSONValue{"outcome": wire.JSONValue(`"done"`)}); got != `The person did "Sign in to GitLab". The page is yours again: call browser_snapshot to see where it is now, and carry on from it.` {
		t.Fatal(got)
	}
	if got := handOffNoteFor("Sign in to GitLab", wire.AnswerElicitationRequestActionDecline, nil); !strings.HasPrefix(got, `The person did not take the page for "Sign in to GitLab".`) {
		t.Fatal(got)
	}
}

// A hand-off the person takes longer over than a tool call may wait: the agent ends its
// turn, keeps the browser, and is started again with the answer.
func TestAHandOffLeftOpenKeepsTheBrowser(t *testing.T) {
	_, left := formHolds(t)
	left() // the call must outlast its hold
	m, c, d, id := handOffSetUp(t)
	inTurn(d, id)
	if r := m.browserTool(2, "hand_to_person", captcha); r.IsError || replyText(r) != handOffStillOpen {
		t.Fatalf("%+v", r)
	}
	if !d.holdsBrowser(id) {
		t.Fatal("no lease")
	}
	d.endBrowserDrive(id)
	if !d.holdsBrowser(id) {
		t.Fatal("the turn's end gave the page away while the person has it")
	}
	req := pendingHandOff(t, c)
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": req.ID, "action": "accept", "content": map[string]any{"outcome": "done"}})
	waitFor(t, "the answer in its chat", func() bool {
		for _, said := range userMessages(d, id) {
			if strings.HasPrefix(said, `The person replied to your hand_to_person. The person did "Solve the CAPTCHA".`) {
				return true
			}
		}
		return false
	})
}

// fakeChrome is a Chrome's DevTools HTTP: its tabs, and the tab each /json/activate brought
// to the front.
func fakeChrome(t *testing.T, targets []chromeTarget) (int, chan string) {
	t.Helper()
	fronted := make(chan string, 4)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/json/list":
			json.NewEncoder(w).Encode(targets)
		case strings.HasPrefix(r.URL.Path, "/json/activate/"):
			fronted <- strings.TrimPrefix(r.URL.Path, "/json/activate/")
			w.Write([]byte("Target activated"))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(srv.Close)
	port, _ := strconv.Atoi(srv.URL[strings.LastIndex(srv.URL, ":")+1:])
	return port, fronted
}

// A step in one of the agents' own Chrome windows (#5095): its page tab comes to the
// front, the card names the window, and the agent takes no browser lease for it.
func TestAHandOffInTheAgentsChrome(t *testing.T) {
	m, c, d, id := handOffSetUp(t)
	port, fronted := fakeChrome(t, []chromeTarget{
		{ID: "BUBBLE", Type: "page", URL: "chrome://signin-dice-web-intercept.top-chrome/"},
		{ID: "SW", Type: "service_worker", URL: "https://signup.live.com/sw.js"},
		{ID: "TAB", Type: "page", Title: "Create account", URL: "https://signup.live.com/signup?lic=1"},
	})
	inTurn(d, id)
	args := map[string]any{"step": "Press and hold the button", "reason": "Microsoft asks a person to prove they're human.", "cdp_port": port}
	answered := make(chan browserReply, 1)
	go func() { answered <- m.browserTool(2, "hand_to_person", args) }()
	req := pendingHandOff(t, c)
	want := "the agents' Chrome (DevTools port " + strconv.Itoa(port) + "), at the tab “Create account” (signup.live.com)"
	if h := req.HandOff; h == nil || h.Window == nil || *h.Window != want {
		t.Fatalf("%+v", req.HandOff)
	}
	if got := <-fronted; got != "TAB" {
		t.Fatal(got)
	}
	if d.holdsBrowser(id) {
		t.Fatal("took the app's browser for a step in another window")
	}
	c.call(t, 2, "elicitations/answer", map[string]any{"requestID": req.ID, "action": "accept", "content": map[string]any{"outcome": "done"}})
	if r := <-answered; r.IsError || !strings.HasPrefix(replyText(r), `The person did "Press and hold the button".`) {
		t.Fatalf("%+v", r)
	}
}

func TestAHandOffInAChromeThatIsNotThere(t *testing.T) {
	m, c, d, id := handOffSetUp(t)
	inTurn(d, id)
	gone, _ := fakeChrome(t, nil)
	cases := map[int]string{
		80:   "Nothing was handed over: cdp_port 80 is not a DevTools port",
		gone: "Nothing was handed over: the Chrome on DevTools port " + strconv.Itoa(gone) + " has no web page open.",
	}
	closed := httptest.NewServer(http.NotFoundHandler())
	shut, _ := strconv.Atoi(closed.URL[strings.LastIndex(closed.URL, ":")+1:])
	closed.Close()
	cases[shut] = "Nothing was handed over: no Chrome answers on DevTools port " + strconv.Itoa(shut) + "."
	n := 2
	for port, want := range cases {
		args := map[string]any{"step": "Press and hold the button", "reason": "x", "cdp_port": port}
		if r := m.browserTool(n, "hand_to_person", args); !r.IsError || !strings.HasPrefix(replyText(r), want) {
			t.Fatalf("%d: %+v", port, r)
		}
		n++
	}
	var pending []wire.ElicitationRequest
	json.Unmarshal(c.call(t, 1, "elicitations/pending", nil), &pending)
	if len(pending) != 0 {
		t.Fatalf("%+v", pending)
	}
}
