package agentsd

import (
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

func problemFields(t *testing.T, link string) url.Values {
	t.Helper()
	u, err := url.Parse(link)
	if err != nil {
		t.Fatal(err)
	}
	if u.Host != "github.com" || u.Path != "/agentloops-dev/agent-loops/issues/new" {
		t.Fatalf("link goes to %s%s", u.Host, u.Path)
	}
	return u.Query()
}

func TestProblemReportCutsTokensAndHomes(t *testing.T) {
	token := "ghp_" + strings.Repeat("a", 36)
	rt := "claude"
	r := wire.ProblemReportRequest{
		Happened: "The chat froze in /Users/alex/src/app\nand stayed frozen",
		Expected: "It to go on; my token " + token + " is in /home/bob/.config",
		Client:   "Mac window 0.17.0",
		ClientOS: "macOS 26.1",
		Runtime:  &rt,
		WithLog:  true,
	}
	log := []string{"2026-11-06T10:00:00Z opened /srv/people/alex/x", "2026-11-06T10:00:01Z Bearer " + strings.Repeat("b", 20)}
	got := problemReport(r, log, "/srv/people/alex")

	if got.Title != "The chat froze in ~/src/app" {
		t.Errorf("title %q", got.Title)
	}
	for _, leak := range []string{token, "/Users/alex", "/home/bob", "/srv/people/alex", strings.Repeat("b", 20)} {
		if strings.Contains(got.Body, leak) || strings.Contains(got.URL, url.QueryEscape(leak)) {
			t.Errorf("report has %q:\n%s", leak, got.Body)
		}
	}
	for _, want := range []string{"## What happened", "## What I expected", "- Client: Mac window 0.17.0 on macOS 26.1", "- Runtime: claude", "Recent log lines", "opened ~/x"} {
		if !strings.Contains(got.Body, want) {
			t.Errorf("body has no %q:\n%s", want, got.Body)
		}
	}
	q := problemFields(t, got.URL)
	if q.Get("title") != got.Title || q.Get("body") != got.Body || q.Get("labels") != "bug" {
		t.Errorf("link's fields %v", q)
	}
}

func TestProblemReportWithoutLogOrWords(t *testing.T) {
	got := problemReport(wire.ProblemReportRequest{Client: "Web page", ClientOS: "Safari"}, nil, "")
	if got.Title != "A problem in Agent Loops" {
		t.Errorf("title %q", got.Title)
	}
	if strings.Contains(got.Body, "Recent log lines") || !strings.Contains(got.Body, "_Not given._") || !strings.Contains(got.Body, "- Runtime: none") {
		t.Errorf("body:\n%s", got.Body)
	}
}

func TestProblemReportLinkFitsGitHub(t *testing.T) {
	var log []string
	for i := 0; i < problemLogLines; i++ {
		log = append(log, strings.Repeat("line ", 60))
	}
	r := wire.ProblemReportRequest{Happened: strings.Repeat("words ", 2000), Client: "Web page", ClientOS: "Firefox", WithLog: true}
	got := problemReport(r, log, "")
	if len(got.URL) > problemURLMost {
		t.Fatalf("link is %d long", len(got.URL))
	}
	if !strings.Contains(got.Body, "Recent log lines") {
		t.Error("the body the person sees lost its log lines")
	}
	problemFields(t, got.URL)
}

func TestLastLogLines(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "daemon.log")
	if lastLogLines(path, 3) != nil {
		t.Error("a missing log has lines")
	}
	if err := os.WriteFile(path, []byte("one\ntwo\nthree\nfour\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(lastLogLines(path, 3), ","); got != "two,three,four" {
		t.Errorf("lines %q", got)
	}
	long := strings.Repeat("x", problemLogTail) + "\nlast\n"
	if err := os.WriteFile(path, []byte(long), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := lastLogLines(path, 3); len(got) != 1 || got[0] != "last" {
		t.Errorf("a cut first line was kept: %d lines", len(got))
	}
}
