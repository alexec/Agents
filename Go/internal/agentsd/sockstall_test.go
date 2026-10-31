package agentsd

import (
	"bufio"
	"context"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// A daemon.sock client that never reads does not hold Broadcast, or the clients that do
// read: it is let go, and the others hear everything (#1399).
func TestAStalledSocketClientIsLetGo(t *testing.T) {
	// Both callers are windows, which hear notifications, whatever the platform's door.
	old := socketPolicyFor
	socketPolicyFor = func(*Daemon) SocketPolicy { return fixedPolicy{role: RoleControl, ok: true} }
	t.Cleanup(func() { socketPolicyFor = old })
	d, c := start(t, t.TempDir())
	// The test's own connection is read too: only the socket's client stalls.
	go func() {
		for range c.out {
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dir, err := os.MkdirTemp("", "sock") // short: a Unix socket's path is at most 104 bytes
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	path := filepath.Join(dir, "d.sock")
	go d.ServeSocket(ctx, path)
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(path); err == nil {
			break
		}
	}
	stalled, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer stalled.Close()
	reader, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	clients := func() int {
		d.mu.Lock()
		defer d.mu.Unlock()
		return len(d.clients)
	}
	for deadline := time.Now().Add(5 * time.Second); clients() < 3; time.Sleep(10 * time.Millisecond) {
		if time.Now().After(deadline) {
			t.Fatal("the clients were not taken")
		}
	}
	const n = 3000
	var heard atomic.Int64
	go func() {
		r := bufio.NewReaderSize(reader, 1<<20)
		for {
			line, err := r.ReadString('\n')
			if err != nil {
				return
			}
			if strings.Contains(line, wire.NotifyFolderChanged.Name) {
				heard.Add(1)
			}
		}
	}()
	big := strings.Repeat("x", 16<<10)
	done := make(chan struct{})
	go func() {
		for i := 0; i < n; i++ {
			Broadcast(d, wire.NotifyFolderChanged, wire.FolderSummary{Name: big})
		}
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(30 * time.Second):
		t.Fatal("Broadcast is held by a client that reads nothing")
	}
	for deadline := time.Now().Add(10 * time.Second); heard.Load() < n && time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
	}
	if got := heard.Load(); got != n {
		t.Fatalf("the reading client heard %d of %d", got, n)
	}
	// The stalled one was let go: what it has buffered ends in EOF.
	stalled.SetReadDeadline(time.Now().Add(10 * time.Second))
	if _, err := io.Copy(io.Discard, stalled); err != nil {
		t.Fatalf("the stalled client was not let go: %v", err)
	}
}
