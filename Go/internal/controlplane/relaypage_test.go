package controlplane

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/web"
	"github.com/alexec/agents/Go/wire"
)

// A page a host carries from its loopback listener (#1480, specs/1480-local-page-on-agentsd):
// the host proves itself as w:<host> with the port, and the page's own exchange follows on
// the same socket, bound to http://localhost:<port>. A browser pairs and connects that way,
// and is refused anywhere else, as at the control plane's own loopback listener.
func TestAPageAHostCarries(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	host, _, hostKey := p.rawHostKey("Mac", false)
	p.waitFor(func() bool { return p.s.router.Reaches(host) }, "the host online")
	const port = 8792
	origin := web.OriginFor(port)

	// The host's half: w:<host>, its key, the port. Answers the open socket, after the ok.
	carry := func(id string, key []byte, page *int64) (*controllink.Lines, error) {
		l, err := controllink.Dial(context.Background(), p.url, "")
		if err != nil {
			return nil, err
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		line, err := l.Read(ctx)
		if err != nil {
			return nil, err
		}
		m, _ := controllink.ParseMessage(line)
		at, _ := controllink.Origin(p.url)
		ident, _ := controllink.ParseIdentity(id)
		auth, expect, err := controllink.Answer(m.Hello, ident, key, at, "page", nil, "", nil)
		if err != nil {
			return nil, err
		}
		auth.Page = page
		l.Write(ctx, controllink.Message{Auth: auth}.Line())
		line, err = l.Read(ctx)
		if err != nil {
			return nil, err
		}
		if m, _ = controllink.ParseMessage(line); m.OK == nil {
			l.Close()
			return nil, fmt.Errorf("refused: %s", line)
		}
		return l, controllink.Check(m.OK, expect)
	}
	page := new(int64)
	*page = port

	// The browser pairs through the host, with a browser code, bound to the host's origin.
	shown, err := p.s.Codes().Issue(context.Background(), false, true, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	code, _ := controllink.ParseCode(shown.Text)
	l, err := carry("w:"+host, hostKey, page)
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := answerHello(l, controllink.Identity{Kind: 'p', ID: code.ID()}, controllink.CodeKey(code.Secret), origin, "browser"); err != nil {
		t.Fatal(err)
	}
	private := controllink.NewPrivateKey()
	public, _ := controllink.PublicKey(private)
	id := records.NewUUID()
	params, _ := json.Marshal(wire.ClientAnnounce{ID: wire.UUID(id), PublicKey: public, Name: "Safari", Kind: wire.ClientKind(records.KindBrowser)})
	l.Write(context.Background(), `{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":`+string(params)+`}`)
	if line, err := l.Read(context.Background()); err != nil || !strings.Contains(line, `"result"`) {
		t.Fatal(line, err)
	}
	l.Close()

	// It connects through the host, and the control plane answers its calls.
	control, _ := controllink.PublicKey(p.s.cfg.PrivateKey)
	key, _ := controllink.ClientKey(private, control, id)
	if l, err = carry("w:"+host, hostKey, page); err != nil {
		t.Fatal(err)
	}
	if _, ok, err := answerHello(l, controllink.Identity{Kind: 'c', ID: id}, key, origin, "browser"); err != nil || ok == nil {
		t.Fatal(err)
	}
	l.Write(context.Background(), `{"m":{"jsonrpc":"2.0","id":7,"method":"control/status"}}`)
	if line := readUntil(t, l, `"id":7`); !strings.Contains(line, `"result"`) {
		t.Fatal(line)
	}
	l.Close()

	// Bound to that origin only: through another port, the proof is no good.
	other := new(int64)
	*other = port + 1
	if l, err = carry("w:"+host, hostKey, other); err != nil {
		t.Fatal(err)
	}
	if _, _, err := answerHello(l, controllink.Identity{Kind: 'c', ID: id}, key, origin, "browser"); err == nil {
		t.Fatal("a proof bound to one port worked through another")
	}
	l.Close()

	// A host says the port, a real one; no one else may say one.
	if _, err := carry("w:"+host, hostKey, nil); err == nil || !strings.Contains(err.Error(), controllink.BadMessage) {
		t.Fatal(err)
	}
	zero := new(int64)
	if _, err := carry("w:"+host, hostKey, zero); err == nil || !strings.Contains(err.Error(), controllink.BadMessage) {
		t.Fatal(err)
	}
	if _, err := carry("h:"+host, hostKey, page); err == nil || !strings.Contains(err.Error(), controllink.BadMessage) {
		t.Fatal("a host's own uplink said a page:", err)
	}

	// A relay host runs no agents, so it carries no page.
	relayHost, _, relayKey := p.rawHostKey("Relay", true)
	p.waitFor(func() bool { return p.s.router.Reaches(relayHost) }, "the relay host online")
	if _, err := carry("w:"+relayHost, relayKey, page); err == nil || !strings.Contains(err.Error(), controllink.Unknown) {
		t.Fatal(err)
	}
}
