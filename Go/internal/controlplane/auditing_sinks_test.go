package controlplane

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// US4 (#1001): an admin sets an HTTP sink; each audit entry goes to it; the token is
// sealed in the store and never answered; a set with no token keeps it; a member may not.
func TestAnAdminSetsAnAuditSink(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	var lines, auths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		mu.Lock()
		defer mu.Unlock()
		lines = append(lines, strings.Split(strings.TrimSpace(string(b)), "\n")...)
		auths = append(auths, r.Header.Get("Authorization"))
	}))
	defer srv.Close()
	saw := func(method string) bool {
		mu.Lock()
		defer mu.Unlock()
		for _, l := range lines {
			if strings.Contains(l, `"method":"`+method+`"`) {
				return true
			}
		}
		return false
	}

	s := store.NewMemory()
	p := startPlaneWith(t, s, controllink.NewPrivateKey(), withKeeper(newKeeperKey()))
	_, window := p.client("Test window")
	token := "s3cret-token"
	var state wire.AuditSinksState
	json.Unmarshal(call(t, window, "", "audit/setSinks", wire.AuditSinks{Sinks: []wire.AuditSink{
		{Kind: wire.AuditSinkKindHttp, Address: srv.URL + "/in", Token: &token}}}), &state)
	if len(state.Sinks) != 1 || state.Sinks[0].Sink.Token != nil || state.Sinks[0].Sink.HasToken == nil || !*state.Sinks[0].Sink.HasToken {
		t.Fatalf("%+v", state)
	}
	if o, _ := s.Get(context.Background(), auditSinksKey); o == nil || strings.Contains(string(o.Data), token) {
		t.Fatalf("the record holds the token: %v", o)
	}

	call(t, window, "", "control/setAuditDays", wire.AuditDays{Days: 30})
	p.waitFor(func() bool { return saw("control/setAuditDays") }, "the entry at the sink")

	// Set again with no token: the token stays.
	call(t, window, "", "audit/setSinks", wire.AuditSinks{Sinks: []wire.AuditSink{{Kind: wire.AuditSinkKindHttp, Address: srv.URL + "/in"}}})
	call(t, window, "", "control/setAuditDays", wire.AuditDays{Days: 60})
	p.waitFor(func() bool {
		mu.Lock()
		defer mu.Unlock()
		return strings.Count(strings.Join(lines, "\n"), "control/setAuditDays") >= 2
	}, "the second entry at the sink")
	mu.Lock()
	for _, a := range auths {
		if a != "Bearer "+token {
			t.Errorf("auth %q", a)
		}
	}
	mu.Unlock()

	var listed wire.AuditSinksState
	json.Unmarshal(call(t, window, "", "audit/sinks", wire.Empty{}), &listed)
	if len(listed.Sinks) != 1 || !*listed.Sinks[0].Sink.HasToken || strings.Contains(mustMarshal(listed), token) {
		t.Fatalf("%+v", listed)
	}

	// Refused: five sinks, a bad address, the same one twice.
	for _, bad := range [][]wire.AuditSink{
		{{Kind: "http", Address: "https://a/1"}, {Kind: "http", Address: "https://a/2"}, {Kind: "http", Address: "https://a/3"},
			{Kind: "http", Address: "https://a/4"}, {Kind: "http", Address: "https://a/5"}},
		{{Kind: "syslog", Address: "udp://siem:514"}},
		{{Kind: "http", Address: "https://a/1"}, {Kind: "http", Address: "https://a/1"}},
	} {
		if e := callError(t, window, "", "audit/setSinks", wire.AuditSinks{Sinks: bad}); !strings.Contains(e, "-32602") {
			t.Errorf("%+v: %s", bad, e)
		}
	}

	sam := p.invite(window, "Sam", wire.UserRoleMember)
	for _, method := range []string{"audit/sinks", "audit/setSinks"} {
		if e := callError(t, sam.window, "", method, wire.AuditSinks{Sinks: []wire.AuditSink{}}); !strings.Contains(e, "-32045") {
			t.Errorf("%s: %s", method, e)
		}
	}
}

func mustMarshal(v any) string {
	b, _ := json.Marshal(v)
	return string(b)
}
