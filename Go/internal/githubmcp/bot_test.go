package githubmcp

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/connections"
)

// The bot's writes name the person it acts for (#3858): a body ends in the footer, a commit
// message in the trailer, once; other writes, and the person's own, are as they were.
func TestTheBotsWritesNameThePerson(t *testing.T) {
	bot := connections.Bot{Slug: "alexec-agents", Person: "alexec"}
	var got []string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		got = append(got, r.URL.Path+" "+string(b))
	}))
	defer server.Close()
	active := true
	client := &http.Client{Transport: &SignTransport{Next: http.DefaultTransport,
		Bot: func() (connections.Bot, bool) { return bot, active }}}
	post := func(method, path, body string) map[string]any {
		got = nil
		req, _ := http.NewRequest(method, server.URL+path, strings.NewReader(body))
		res, err := client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = res.Body.Close()
		var m map[string]any
		_ = json.Unmarshal([]byte(got[0][strings.Index(got[0], " ")+1:]), &m)
		return m
	}

	m := post("POST", "/repos/o/r/issues/3/comments", `{"body":"Done <b>here</b>."}`)
	if m["body"] != "Done <b>here</b>.\n\n"+bot.Footer() {
		t.Errorf("comment: %q", m["body"])
	}
	m = post("POST", "/repos/o/r/pulls", `{"title":"t","body":"Fixes #1\n","head":"h","base":"main"}`)
	if m["body"] != "Fixes #1\n\n"+bot.Footer() || m["title"] != "t" {
		t.Errorf("pull request: %v", m)
	}
	m = post("PUT", "/repos/o/r/contents/README.md", `{"message":"Say hello\n\nSigned-off-by: x <x@y>","content":"aGk="}`)
	if m["message"] != "Say hello\n\nSigned-off-by: x <x@y>\n"+bot.Trailer() {
		t.Errorf("commit: %q", m["message"])
	}
	m = post("POST", "/repos/o/r/git/commits", `{"message":"One line","tree":"t"}`)
	if m["message"] != "One line\n\n"+bot.Trailer() {
		t.Errorf("git commit: %q", m["message"])
	}
	signed := `{"body":"Hi\n\n` + bot.Footer() + `"}`
	if m = post("PATCH", "/repos/o/r/issues/comments/9", signed); strings.Count(m["body"].(string), bot.Footer()) != 1 {
		t.Errorf("signed twice: %q", m["body"])
	}
	if m = post("POST", "/repos/o/r/issues/3/labels", `{"labels":["x"]}`); m["body"] != nil {
		t.Errorf("labels: %v", m)
	}
	active = false
	if m = post("POST", "/repos/o/r/issues/3/comments", `{"body":"Mine"}`); m["body"] != "Mine" {
		t.Errorf("the person's own comment: %q", m["body"])
	}
}
