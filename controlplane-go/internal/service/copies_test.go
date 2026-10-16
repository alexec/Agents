package service

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/alexec/agents/controlplane-go/internal/auth"
	"github.com/alexec/agents/controlplane-go/internal/store"
)

func freePort(t *testing.T) int {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// Two copies of one control plane on one store, with the same key and certificate, as a
// deployment of several copies has them.
func twoCopies(t *testing.T) (*world, *world) {
	st := store.NewMemory()
	tlsConfig, pin, err := SelfSigned(t.TempDir(), "127.0.0.1")
	if err != nil {
		t.Fatal(err)
	}
	priv := auth.NewPrivateKey()
	pub, _ := auth.PublicKey(priv)
	var ws []*world
	for _, name := range []string{"a", "b"} {
		port := freePort(t)
		url := fmt.Sprintf("https://127.0.0.1:%d", port)
		s, err := New(Config{Store: st, PrivateKey: priv, URL: url, PeerURL: url, TLS: tlsConfig, Pin: pin, Bind: "127.0.0.1",
			Port: port, Name: "copies", MachineID: "this-mac", CopyBeat: 200 * time.Millisecond,
			Log: func(l string) { t.Log(name, l) }})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.Start(context.Background()); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(s.Stop)
		ws = append(ws, &world{s: s, url: url, pin: pin, ckey: pub})
	}
	deadline := time.Now().Add(5 * time.Second)
	for len(ws[0].s.mesh.Peers()) == 0 || len(ws[1].s.mesh.Peers()) == 0 {
		if time.Now().After(deadline) {
			t.Fatal("the copies never linked")
		}
		time.Sleep(50 * time.Millisecond)
	}
	return ws[0], ws[1]
}

func waitFor(t *testing.T, what string, ok func() bool) {
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("never: %s", what)
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// A host held by copy A, a client at copy B: the request goes A's way on the peer link,
// and the reply comes back the same way (T065).
func TestAClientAtOneCopyReachesAHostAtAnother(t *testing.T) {
	a, b := twoCopies(t)
	host, hostID := a.enrolHost(t, "server")
	waitFor(t, "B reaches the host through A", func() bool { return b.s.router.Reaches(hostID) && !b.s.router.Holds(hostID) })
	client, _ := b.pairClient(t, "mac")
	open := host.readUntil(t, `"open"`)
	var f struct{ C int }
	json.Unmarshal([]byte(open), &f)
	client.send(t, `{"h":"`+hostID+`","m":{"jsonrpc":"2.0","id":1,"method":"agents/list","params":{}}}`)
	host.readUntil(t, "agents/list")
	host.send(t, fmt.Sprintf(`{"c":%d,"m":{"jsonrpc":"2.0","id":1,"result":["through A"]}}`, f.C))
	if l := client.readUntil(t, `"id":1`); l != `{"h":"`+hostID+`","m":{"jsonrpc":"2.0","id":1,"result":["through A"]}}` {
		t.Fatalf("reply: %s", l)
	}
	// A broadcast the host fans out reaches the client at the other copy.
	host.send(t, fmt.Sprintf(`{"f":[%d],"m":{"jsonrpc":"2.0","method":"agents/changed","params":{}}}`, f.C))
	client.readUntil(t, "agents/changed")

	// The host leaves A: its lease is let go, and B's stream ends; a call in flight is answered.
	client.send(t, `{"h":"`+hostID+`","m":{"jsonrpc":"2.0","id":2,"method":"agents/list","params":{}}}`)
	host.readUntil(t, `"id":2`)
	host.ws.Close(websocket.StatusNormalClosure, "")
	if l := client.readUntil(t, `"id":2`); !strings.Contains(l, "-32090") {
		t.Fatalf("in flight: %s", l)
	}
	waitFor(t, "B lets the stream go", func() bool { return !b.s.router.Reaches(hostID) })
	if le := a.s.mesh.leases.Holder(context.Background(), hostID); le != nil {
		t.Fatalf("the lease is still held: %+v", le)
	}
}

// The host comes back at B, as through a load balancer: B takes the lease, and a client at
// A reaches it through B now.
func TestAHostThatMovesIsReachedAtItsNewCopy(t *testing.T) {
	a, b := twoCopies(t)
	c := a.code(t, true)
	p, err := dial(t, c.URL, c.Pin, "e:"+c.ID(), auth.CodeKey(c.Secret), c.ControlKey, "host")
	if err != nil {
		t.Fatal(err)
	}
	priv := auth.NewPrivateKey()
	pub, _ := auth.PublicKey(priv)
	body, _ := json.Marshal(map[string]any{"publicKey": pub, "name": "mover", "platform": "linux", "version": "test", "machineID": "server"})
	p.send(t, `{"jsonrpc":"2.0","id":1,"method":"hosts/announce","params":`+string(body)+`}`)
	var r struct{ Result struct{ Host string } }
	json.Unmarshal([]byte(p.read(t)), &r)
	hostID := r.Result.Host
	key, _ := auth.HostKey(priv, a.ckey, hostID)
	hello := `{"c":0,"m":{"jsonrpc":"2.0","id":1,"method":"host/hello","params":{"version":"test","platform":"linux","machineID":"server"}}}`
	atA, err := dial(t, a.url, a.pin, "h:"+hostID, key, a.ckey, "host")
	if err != nil {
		t.Fatal(err)
	}
	atA.send(t, hello)
	atA.readUntil(t, `"c":0`)
	waitFor(t, "B reaches it through A", func() bool { return b.s.router.Reaches(hostID) && !b.s.router.Holds(hostID) })
	atA.ws.Close(websocket.StatusNormalClosure, "")
	waitFor(t, "A lets it go", func() bool { return !a.s.router.Holds(hostID) })

	atB, err := dial(t, b.url, b.pin, "h:"+hostID, key, b.ckey, "host")
	if err != nil {
		t.Fatal(err)
	}
	atB.send(t, hello)
	atB.readUntil(t, `"c":0`)
	waitFor(t, "A reaches it through B", func() bool { return a.s.router.Reaches(hostID) && !a.s.router.Holds(hostID) && b.s.router.Holds(hostID) })
	if le := b.s.mesh.leases.Holder(context.Background(), hostID); le == nil || le.Copy != b.s.copyID || le.Epoch != 2 {
		t.Fatalf("the lease: %+v", le)
	}
	client, _ := a.pairClient(t, "mac")
	open := atB.readUntil(t, `"open"`)
	var f struct{ C int }
	json.Unmarshal([]byte(open), &f)
	client.send(t, `{"h":"`+hostID+`","m":{"jsonrpc":"2.0","id":5,"method":"daemon/ping"}}`)
	atB.readUntil(t, "daemon/ping")
	atB.send(t, fmt.Sprintf(`{"c":%d,"m":{"jsonrpc":"2.0","id":5,"result":{"at":"B"}}}`, f.C))
	client.readUntil(t, `"at":"B"`)
}

// A client forgotten at A is closed at B too (an event on the link).
func TestAForgetAtOneCopyClosesTheClientAtAnother(t *testing.T) {
	a, b := twoCopies(t)
	atB, id := b.pairClient(t, "mac")
	other, _ := a.pairClient(t, "mac")
	other.send(t, `{"m":{"jsonrpc":"2.0","id":1,"method":"clients/forget","params":{"client":"`+id+`"}}}`)
	other.readUntil(t, `"id":1`)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		if _, _, err := atB.ws.Read(ctx); err != nil {
			if websocket.CloseStatus(err) != forgottenCloseCode {
				t.Fatalf("closed with %v", err)
			}
			return
		}
	}
}
