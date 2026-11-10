package controlplane

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// webDist is a Web/dist with its MANIFEST, for the loopback listener.
func webDist(t *testing.T) string {
	t.Helper()
	dist := t.TempDir()
	index := []byte("<html></html>")
	sum := sha256.Sum256(index)
	os.WriteFile(filepath.Join(dist, "index.html"), index, 0o644)
	os.WriteFile(filepath.Join(dist, "MANIFEST"), []byte("agents-web 1\nout "+hex.EncodeToString(sum[:])+" Web/dist/index.html\n"), 0o644)
	return dist
}

// The web page turns the listener off and on, and the control plane keeps it (#4252).
func TestAnAdminTurnsTheWebListenerOffAndOn(t *testing.T) {
	t.Parallel()
	var mu sync.Mutex
	var kept []bool
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		c.Web = &WebConfig{Folder: webDist(t), Port: 0}
		c.WebSwitched = func(on bool) error { mu.Lock(); kept = append(kept, on); mu.Unlock(); return nil }
	})
	_, window := p.client("Window")
	port := p.s.WebPort()
	if port == 0 {
		t.Fatal("not serving")
	}
	var status wire.WebRemoteStatus
	json.Unmarshal(call(t, window, "", "control/setWeb", wire.WebServe{On: false}), &status)
	if status.Served || status.Reason == nil || *status.Reason != "off" || p.s.WebPort() != 0 {
		t.Fatalf("%+v", status)
	}
	if conn, err := net.DialTimeout("tcp", "127.0.0.1:"+itoa(port), time.Second); err == nil {
		conn.Close()
		t.Fatal("the listener is still open")
	}
	// Try Again leaves it off.
	json.Unmarshal(call(t, window, "", "control/retryWeb", wire.Empty{}), &status)
	if status.Served {
		t.Fatalf("%+v", status)
	}
	var said wire.ControlStatus
	json.Unmarshal(call(t, window, "", "control/status", wire.Empty{}), &said)
	if said.Web == nil || said.Web.Served || said.Restartable != nil {
		t.Fatalf("%+v", said)
	}
	json.Unmarshal(call(t, window, "", "control/setWeb", wire.WebServe{On: true}), &status)
	if !status.Served || p.s.WebPort() == 0 {
		t.Fatalf("%+v", status)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(kept) != 2 || kept[0] || !kept[1] {
		t.Fatalf("%v", kept)
	}
}

// Started with web-off, it serves nothing until turned on.
func TestTheWebListenerStartsOffWhenKeptOff(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		c.Web = &WebConfig{Folder: webDist(t), Port: 0}
		c.WebOff = true
	})
	if p.s.WebPort() != 0 {
		t.Fatal("serving")
	}
	_, window := p.client("Window")
	var said wire.ControlStatus
	json.Unmarshal(call(t, window, "", "control/status", wire.Empty{}), &said)
	if said.Web == nil || said.Web.Reason == nil || *said.Web.Reason != "off" {
		t.Fatalf("%+v", said.Web)
	}
}

// control/restart calls Restart where something starts it again, and is refused elsewhere.
func TestRestartOnlyWhereItStartsAgain(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Window")
	if e := callError(t, window, "", "control/restart", wire.Empty{}); !strings.Contains(e, "can't restart itself") {
		t.Fatal(e)
	}
	if e := callError(t, window, "", "control/setWeb", wire.WebServe{On: false}); !strings.Contains(e, "serves no page") {
		t.Fatal(e)
	}
	restarted := make(chan struct{}, 1)
	q := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) {
		c.Restart = func() { restarted <- struct{}{} }
	})
	_, other := q.client("Window")
	var said wire.ControlStatus
	json.Unmarshal(call(t, other, "", "control/status", wire.Empty{}), &said)
	if said.Restartable == nil || !*said.Restartable {
		t.Fatalf("%+v", said)
	}
	call(t, other, "", "control/restart", wire.Empty{})
	select {
	case <-restarted:
	case <-time.After(5 * time.Second):
		t.Fatal("not restarted")
	}
}
