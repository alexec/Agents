package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// A GitHub sign-in (#1335) through the wire: the client is given the code and the links,
// waits, and is told the account; the host keeps the tokens; the list says connected and
// never holds a token; disconnect takes it away.
func TestConnectingGitHubWithTheDeviceFlow(t *testing.T) {
	var polls atomic.Int32
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/login/device/code":
			fmt.Fprint(w, `{"device_code":"dev-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}`)
		case "/login/oauth/access_token":
			if polls.Add(1) < 3 {
				fmt.Fprint(w, `{"error":"authorization_pending"}`)
				return
			}
			fmt.Fprint(w, `{"access_token":"ghu_secret","expires_in":28800,"refresh_token":"ghr_secret","refresh_token_expires_in":15897600}`)
		case "/api/user":
			fmt.Fprint(w, `{"login":"octocat"}`)
		default:
			http.NotFound(w, r)
		}
	}))
	defer gh.Close()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.newDeviceFlow = func(wire.ConnectionProvider) *connections.DeviceFlow {
		return &connections.DeviceFlow{ClientID: connections.GitHubClientID, Base: gh.URL + "/", API: gh.URL + "/api/",
			HTTP: gh.Client(), Sleep: func(ctx context.Context, _ time.Duration) error { return ctx.Err() }}
	}

	var started wire.ConnectionSignIn
	json.Unmarshal(c.call(t, 1, "connections/sign-in", map[string]any{"provider": "github"}), &started)
	if started.Status != wire.ConnectionSignInStatusWaiting || started.UserCode != "ABCD-1234" ||
		started.VerificationURL != "https://github.com/login/device" || started.InstallURL == nil ||
		*started.InstallURL != "https://github.com/apps/agents-loops/installations/new" {
		t.Fatalf("started: %+v", started)
	}
	var done wire.ConnectionSignIn
	for i := 0; i < 20 && done.Status != wire.ConnectionSignInStatusConnected; i++ {
		raw := c.call(t, 2+i, "connections/sign-in/wait", map[string]any{"flowID": started.FlowID})
		if strings.Contains(string(raw), "ghu_secret") || strings.Contains(string(raw), "dev-1") {
			t.Fatalf("a secret went to the client: %s", raw)
		}
		json.Unmarshal(raw, &done)
	}
	if done.Connection == nil || done.Connection.Login == nil || *done.Connection.Login != "octocat" {
		t.Fatalf("done: %+v", done)
	}
	kept, ok, _ := file.Get(connections.GitHub)
	if !ok || kept.Access != "ghu_secret" || kept.Refresh != "ghr_secret" {
		t.Fatalf("kept: %+v", kept)
	}

	raw := c.call(t, 30, "connections/list", map[string]any{})
	if strings.Contains(string(raw), "ghu_secret") || strings.Contains(string(raw), "ghr_secret") {
		t.Fatalf("a token in the list: %s", raw)
	}
	var list wire.ConnectionsList
	json.Unmarshal(raw, &list)
	if len(list.Connections) != 1 || list.Connections[0].State != wire.ConnectionStateConnected {
		t.Fatalf("list: %+v", list)
	}

	c.call(t, 31, "connections/disconnect", map[string]any{"provider": "github"})
	json.Unmarshal(c.call(t, 32, "connections/list", map[string]any{}), &list)
	if len(list.Connections) != 0 {
		t.Fatalf("after disconnect: %+v", list)
	}
}

// A second client that asks while a sign-in waits is shown the same code; a cancel ends it.
func TestASignInUnderWayIsShared(t *testing.T) {
	var starts atomic.Int32
	gh := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path == "/login/device/code" {
			starts.Add(1)
			fmt.Fprint(w, `{"device_code":"dev-1","user_code":"ABCD-1234","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}`)
			return
		}
		fmt.Fprint(w, `{"error":"authorization_pending"}`)
	}))
	defer gh.Close()
	d, c := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	d.newDeviceFlow = func(wire.ConnectionProvider) *connections.DeviceFlow {
		return &connections.DeviceFlow{ClientID: connections.GitHubClientID, Base: gh.URL + "/", API: gh.URL + "/api/",
			HTTP: gh.Client(), Sleep: func(ctx context.Context, _ time.Duration) error {
				select {
				case <-ctx.Done():
					return ctx.Err()
				case <-time.After(10 * time.Millisecond):
					return nil
				}
			}}
	}
	var a, b, cancelled wire.ConnectionSignIn
	json.Unmarshal(c.call(t, 1, "connections/sign-in", map[string]any{"provider": "github"}), &a)
	json.Unmarshal(c.call(t, 2, "connections/sign-in", map[string]any{"provider": "github"}), &b)
	if a.FlowID != b.FlowID || starts.Load() != 1 {
		t.Fatalf("two sign-ins: %v %v, %d starts", a.FlowID, b.FlowID, starts.Load())
	}
	json.Unmarshal(c.call(t, 3, "connections/sign-in/cancel", map[string]any{"flowID": a.FlowID}), &cancelled)
	if cancelled.Status != wire.ConnectionSignInStatusCancelled {
		t.Fatalf("cancel: %+v", cancelled)
	}
}
