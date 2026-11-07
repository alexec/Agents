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

	"github.com/alexec/agents/Go/internal/betterstackmcp"
)

// #3655: a new incident on a scratch Better Stack monitor raises health.incident_started
// from the betterstack events server (its own front, run as this test binary over stdio),
// and a wait on it wakes.

// TestBetterStackEventsHelper is the betterstack-mcp server, when the test below starts it.
func TestBetterStackEventsHelper(t *testing.T) {
	if os.Getenv("AGENTS_BETTERSTACK_HELPER") != "1" {
		return
	}
	account := &betterstackmcp.Account{Token: os.Getenv("BETTERSTACK_API_TOKEN"), URL: os.Getenv("BETTERSTACK_URL")}
	front := &betterstackmcp.Front{Events: &betterstackmcp.Events{Account: account}, Upstream: betterstackmcp.NewServer("test"), Version: "test"}
	_ = front.Serve(context.Background(), os.Stdin, os.Stdout)
	os.Exit(0)
}

func TestAWaitOnABetterStackIncident(t *testing.T) {
	var mu sync.Mutex
	incidents := []map[string]any{}
	reads := 0
	bs := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		if r.Header.Get("Authorization") != "Bearer bs_scratch" {
			w.WriteHeader(http.StatusUnauthorized)
			return
		}
		reads++
		json.NewEncoder(w).Encode(map[string]any{"data": incidents, "pagination": map[string]any{"next": nil}})
	}))
	defer bs.Close()

	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	a := seeded(t, d, t.TempDir(), nil)
	m := appClient(t, d, a.ID)
	m.post("initialize", map[string]any{}, 1)
	home := t.TempDir()
	d.PersonalHome = home
	os.MkdirAll(filepath.Join(home, ".agents"), 0o755)
	b, _ := json.Marshal(map[string]any{"mcpServers": map[string]any{"betterstack-events": map[string]any{
		"command": os.Args[0], "args": []string{"-test.run=^TestBetterStackEventsHelper$"},
		"env": map[string]string{"AGENTS_BETTERSTACK_HELPER": "1", "BETTERSTACK_API_TOKEN": "bs_scratch", "BETTERSTACK_URL": bs.URL},
	}}})
	os.WriteFile(filepath.Join(home, ".agents", "mcp.json"), b, 0o644)
	quickPolls(d)
	d.StartMCPEvents()

	answered := make(chan string, 1)
	go func() {
		text, _ := m.tool(21, "wait_for_event", map[string]any{"events": "health.incident_started", "until_minutes": 10})
		answered <- text
	}()
	// The first poll only marks where the wait starts.
	waitFor(t, "the first poll", func() bool {
		mu.Lock()
		defer mu.Unlock()
		return reads > 0
	})
	mu.Lock()
	incidents = append(incidents, map[string]any{"id": "77", "type": "incident", "attributes": map[string]any{
		"name": "web", "url": "https://app.example.com/health", "cause": "Status 503", "team_name": "Scratch",
		"started_at": time.Now().UTC().Format(time.RFC3339)}})
	mu.Unlock()
	select {
	case text := <-answered:
		if !strings.HasPrefix(text, "Subscribed to health.incident_started on betterstack-events. health.incident_started happened at ") ||
			!strings.Contains(text, "Status 503") {
			t.Fatal(text)
		}
	case <-time.After(20 * time.Second):
		t.Fatal("the wait was never answered")
	}
}
