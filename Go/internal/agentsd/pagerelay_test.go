package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	cpstore "github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// The page this host serves when the control plane runs elsewhere (#1951): a browser pairs
// and connects at the host's loopback listener, and the control plane answers it through
// the host. With no control plane to carry it to, the page is told it is unavailable.
func TestAPageThroughThisHost(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	dist := t.TempDir()
	index := []byte("<html></html>")
	sum := sha256.Sum256(index)
	os.WriteFile(filepath.Join(dist, "index.html"), index, 0o644)
	os.WriteFile(filepath.Join(dist, "MANIFEST"), []byte("agents-web 1\nout "+hex.EncodeToString(sum[:])+" Web/dist/index.html\n"), 0o644)

	// A control plane elsewhere, with no page of its own.
	port := freeTCPPort(t)
	controlPrivate := controllink.NewPrivateKey()
	cp, err := controlplane.New(controlplane.Config{Store: cpstore.NewMemory(), PrivateKey: controlPrivate,
		URL: "http://127.0.0.1:" + strconv.Itoa(port), Bind: "127.0.0.1", Port: port, Name: "Away"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := cp.Start(ctx); err != nil {
		t.Fatal(err)
	}
	defer cp.Stop()

	// This host, joined to it, with its uplink up.
	root := t.TempDir()
	d, _ := start(t, root)
	private, err := controllink.HostPrivateKey(controllink.HostKeyFile{Root: root})
	if err != nil {
		t.Fatal(err)
	}
	shown, err := cp.Codes().Issue(ctx, true, false, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	hostCode, _ := controllink.ParseCode(shown.Text)
	hello := controllink.MachineHello{Version: "test", Platform: "Linux arm64", MachineID: "PAGE-TEST"}
	member, err := controllink.Enroll(ctx, root, hostCode, private, hello)
	if err != nil {
		t.Fatal(err)
	}
	up := &controllink.Uplink{Root: root, Member: member, Private: private, Hello: hello, Accept: d.Accept}
	upCtx, stopUplink := context.WithCancel(ctx)
	defer stopUplink()
	go up.Run(upCtx)

	listener := d.StartPage(ctx, private, dist, 0)
	if listener == nil {
		t.Fatal("no page served")
	}
	origin := listener.Origin()

	// A browser code, spent at this host's page: the control plane takes it, bound to the
	// host's origin. Tried until the host's uplink is up, as the page tries again.
	shown, err = cp.Codes().Issue(ctx, false, true, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	code, _ := controllink.ParseCode(shown.Text)
	var l *controllink.Lines
	deadline := time.Now().Add(15 * time.Second)
	for {
		l, err = controllink.DialOrigin(ctx, origin, origin)
		if err != nil {
			t.Fatal(err)
		}
		if err = exchange(ctx, l, controllink.Identity{Kind: 'p', ID: code.ID()}, controllink.CodeKey(code.Secret), origin); err == nil {
			break
		}
		l.Close()
		if time.Now().After(deadline) {
			t.Fatalf("the page was never carried: %v", err)
		}
		time.Sleep(200 * time.Millisecond)
	}
	browser := controllink.NewPrivateKey()
	public, _ := controllink.PublicKey(browser)
	id := records.NewUUID()
	params, _ := json.Marshal(wire.ClientAnnounce{ID: wire.UUID(id), PublicKey: public, Name: "Safari", Kind: wire.ClientKind(records.KindBrowser)})
	l.Write(ctx, `{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":`+string(params)+`}`)
	if line, err := l.Read(ctx); err != nil || !strings.Contains(line, `"result"`) {
		t.Fatal(line, err)
	}
	l.Close()
	host, _ := json.Marshal(member.Host)

	// A code's ok is no person's: its calls to this host are never answered here.
	shown, err = cp.Codes().Issue(ctx, false, true, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	code, _ = controllink.ParseCode(shown.Text)
	if l, err = controllink.DialOrigin(ctx, origin, origin); err != nil {
		t.Fatal(err)
	}
	if err := exchange(ctx, l, controllink.Identity{Kind: 'p', ID: code.ID()}, controllink.CodeKey(code.Secret), origin); err != nil {
		t.Fatal(err)
	}
	l.Write(ctx, `{"h":`+string(host)+`,"m":{"jsonrpc":"2.0","id":3,"method":"daemon/status"}}`)
	for {
		rctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		line, err := l.Read(rctx)
		cancel()
		if err != nil {
			break
		}
		if strings.Contains(line, `"id":3`) && strings.Contains(line, `"result"`) {
			t.Fatalf("a code's call was answered by this host: %s", line)
		}
	}
	l.Close()

	// The browser connects there with its own key, and the control plane answers it.
	controlPublic, _ := controllink.PublicKey(controlPrivate)
	key, _ := controllink.ClientKey(browser, controlPublic, id)
	if l, err = controllink.DialOrigin(ctx, origin, origin); err != nil {
		t.Fatal(err)
	}
	if err := exchange(ctx, l, controllink.Identity{Kind: 'c', ID: id}, key, origin); err != nil {
		t.Fatal(err)
	}
	l.Write(ctx, `{"m":{"jsonrpc":"2.0","id":7,"method":"control/status"}}`)
	for {
		rctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		line, err := l.Read(rctx)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(line, `"id":7`) {
			if !strings.Contains(line, `"result"`) {
				t.Fatal(line)
			}
			break
		}
	}

	// Its calls to this host are answered here (#1970): with the uplink gone, so the control
	// plane could not have, they are still answered, framed as the control plane frames them.
	stopUplink()
	time.Sleep(300 * time.Millisecond)
	l.Write(ctx, `{"h":`+string(host)+`,"m":{"jsonrpc":"2.0","id":8,"method":"daemon/status"}}`)
	for {
		rctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		line, err := l.Read(rctx)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(line, `"id":8`) {
			if !strings.Contains(line, `"result"`) || !strings.HasPrefix(line, `{"h":`+string(host)+`,"m":`) {
				t.Fatal(line)
			}
			break
		}
	}
	// A call the audit keeps still goes through the control plane, which says the machine
	// is offline: this host never answers it itself.
	l.Write(ctx, `{"h":`+string(host)+`,"m":{"jsonrpc":"2.0","id":9,"method":"agents/stop","params":{"agentID":"`+records.NewUUID()+`"}}}`)
	for {
		rctx, cancel := context.WithTimeout(ctx, 10*time.Second)
		line, err := l.Read(rctx)
		cancel()
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(line, `"id":9`) {
			if !strings.Contains(line, "offline") {
				t.Fatal(line)
			}
			break
		}
	}
	l.Close()

	// The control plane gone: the page is told so, with a reason it knows.
	cp.Stop()
	if l, err = controllink.DialOrigin(ctx, origin, origin); err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	rctx, cancel2 := context.WithTimeout(ctx, 20*time.Second)
	defer cancel2()
	line, err := l.Read(rctx)
	if err != nil || !strings.Contains(line, controllink.Unavailable) {
		t.Fatalf("%q %v", line, err)
	}
}

// The control plane's word that a page is answered here is taken only from the line right
// after the page's ok, and says who the page is and which calls still go up.
func TestCarriedLine(t *testing.T) {
	said := controllink.Carried{Actor: wire.AuditActor{User: "P1"}, Up: []string{"agents/start"}}
	got, ok := controllink.ParseCarried(said.Line())
	if !ok || got.Actor.User != "P1" {
		t.Fatal(said.Line())
	}
	for _, line := range []string{`{"ok":{}}`, `{"carried":{"up":[]}}`, `{"carried":{"actor":{"user":"P1"}},"jsonrpc":"2.0"}`, `[]`} {
		if _, ok := controllink.ParseCarried(line); ok {
			t.Fatal(line)
		}
	}
	c := &pageChannel{}
	c.carried(got)
	if c.Actor() == nil || c.Actor().User != "P1" {
		t.Fatal("no actor")
	}
	for m, up := range map[string]bool{
		`{"jsonrpc":"2.0","id":1,"method":"agents/start"}`:  true,
		`{"jsonrpc":"2.0","id":1,"method":"daemon/status"}`: false,
		`{"jsonrpc":"2.0","id":1,"result":{}}`:              false,
		`not json`:                                          true,
	} {
		if c.goesUp(json.RawMessage(m)) != up {
			t.Fatal(m)
		}
	}
}

// exchange is the page's side of the exchange, bound to origin.
func exchange(ctx context.Context, l *controllink.Lines, id controllink.Identity, key []byte, origin string) error {
	rctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	line, err := l.Read(rctx)
	if err != nil {
		return err
	}
	m, _ := controllink.ParseMessage(line)
	if m.Hello == nil {
		return fmt.Errorf("no hello: %s", line)
	}
	auth, expect, err := controllink.Answer(m.Hello, id, key, origin, "browser", nil, "", nil)
	if err != nil {
		return err
	}
	l.Write(rctx, controllink.Message{Auth: auth}.Line())
	if line, err = l.Read(rctx); err != nil {
		return err
	}
	if m, _ = controllink.ParseMessage(line); m.OK == nil {
		return fmt.Errorf("refused: %s", line)
	}
	return controllink.Check(m.OK, expect)
}

func freeTCPPort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}
