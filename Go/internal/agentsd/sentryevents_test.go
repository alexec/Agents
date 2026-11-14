package agentsd

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/sentrymcp"
)

// #3583: a new issue in a scratch Sentry project raises health.issue_new from the sentry
// events server (its own front, run as this test binary over stdio), and a wait on it wakes.

// TestSentryEventsHelper is the sentry-mcp server, when the test below starts it.
func TestSentryEventsHelper(t *testing.T) {
	if os.Getenv("AGENTS_SENTRY_HELPER") != "1" {
		return
	}
	account := &sentrymcp.Account{Token: os.Getenv("SENTRY_AUTH_TOKEN"), Org: os.Getenv("SENTRY_ORG"), URL: os.Getenv("SENTRY_URL")}
	front := &sentrymcp.Front{Events: &sentrymcp.Events{Account: account}, Upstream: sentrymcp.NewServer("test"), Version: "test"}
	_ = front.Serve(context.Background(), os.Stdin, os.Stdout)
	os.Exit(0)
}

func TestAWaitOnANewSentryIssue(t *testing.T) {
	var mu sync.Mutex
	issues := []map[string]any{}
	searches := 0
	sentry := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer sntryu_scratch" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		if id := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/0/organizations/scratch/issues/"), "/"); id != "" {
			for _, it := range issues {
				if it["id"] == id {
					json.NewEncoder(w).Encode(it)
					return
				}
			}
			w.WriteHeader(http.StatusNotFound)
			return
		}
		searches++
		json.NewEncoder(w).Encode(issues)
	}))
	defer sentry.Close()

	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	home := t.TempDir()
	d.PersonalHome = home
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	b, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{"sentry-events": map[string]any{
		"command": os.Args[0], "args": []string{"-test.run=^TestSentryEventsHelper$"},
		"env": map[string]string{"AGENTS_SENTRY_HELPER": "1", "SENTRY_AUTH_TOKEN": "sntryu_scratch", "SENTRY_ORG": "scratch", "SENTRY_URL": sentry.URL},
	}}})
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), b, 0o644)
	quickPolls(d)
	d.StartMCPEvents()

	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(21, "wait_for_event", map[string]any{"events": "health.issue_new", "where": map[string]any{"project": "web"}, "until_minutes": 10})
		answered <- text
	}()
	// The first poll only marks where the wait starts.
	waitFor(t, "the first poll", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return searches > 0
	})
	mu.Lock()
	issues = append(issues, map[string]any{"id": "42", "shortId": "WEB-1", "title": "TypeError: x is undefined", "level": "error",
		"permalink": "https://scratch.sentry.io/issues/42/", "firstSeen": time.Now().UTC().Format(time.RFC3339),
		"project": map[string]any{"slug": "web"}, "firstRelease": map[string]any{"version": "web@1.2.0"}})
	mu.Unlock()
	select {
	case text := <-answered:
		if !strings.HasPrefix(text, "Subscribed to health.issue_new on sentry-events (project web). health.issue_new happened at ") ||
			!strings.Contains(text, "web@1.2.0") || !strings.Contains(text, "WEB-1") {
			t.Fatal(text)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the wait was never answered")
	}
}
