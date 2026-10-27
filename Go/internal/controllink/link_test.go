package controllink

import (
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// fakeControl is the control plane's end of the exchange, as ControlService.swift does it,
// enough to enrol a host, take its uplink, and open a channel to it.
type fakeControl struct {
	t       *testing.T
	private []byte
	secret  []byte // the host code's
	host    string
	srv     *httptest.Server
	hellos  chan MachineHello
	channel chan string // what the host wrote on channel 1
	refuse  bool
	// stall, when set, is what the first uplink waits on after opening its channel, reading
	// nothing more: a control plane gone quiet (#1403). Later uplinks are served as usual.
	stall   chan struct{}
	uplinks atomic.Int32
	// letGo, when set, closes every uplink as soon as its machine/hello is read: a copy that
	// lets go at once (#1529).
	letGo bool

	mu         sync.Mutex
	hostPublic []byte // from machines/announce
}

func newFakeControl(t *testing.T) *fakeControl {
	f := &fakeControl{t: t, private: NewPrivateKey(), secret: make([]byte, 32), host: "k3rs7zgm",
		hellos: make(chan MachineHello, 4), channel: make(chan string, 16)}
	rand.Read(f.secret)
	f.srv = httptest.NewServer(http.HandlerFunc(f.serve))
	t.Cleanup(f.srv.Close)
	return f
}

func (f *fakeControl) code() *Code {
	pub, _ := PublicKey(f.private)
	return &Code{Host: true, ControlKey: pub, Secret: f.secret, URL: f.srv.URL, Name: "scratch"}
}

func (f *fakeControl) serve(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/v1/connect" {
		http.NotFound(w, r)
		return
	}
	ws, err := websocket.Accept(w, r, nil)
	if err != nil {
		return
	}
	defer ws.CloseNow()
	ctx := r.Context()
	l := &Lines{ws: ws}
	nonce := make([]byte, 32)
	rand.Read(nonce)
	pub, _ := PublicKey(f.private)
	l.Write(ctx, Message{Hello: &Hello{V: Version, Name: "scratch", Control: B64URL(pub), Nonce: B64URL(nonce), Copy: "a"}}.Line())
	line, err := l.Read(ctx)
	if err != nil {
		return
	}
	m, _ := ParseMessage(line)
	if m.Auth == nil {
		return
	}
	a := *m.Auth
	var key []byte
	switch {
	case strings.HasPrefix(a.ID, "e:"):
		key = CodeKey(f.secret)
	case a.ID == "h:"+f.host:
		// The control plane's side of HostKey: ECDH of its private key and the host's public one.
		key = f.hostKey()
	}
	peer, _ := FromB64URL(a.Nonce)
	origin, _ := Origin(f.srv.URL)
	got, _ := FromB64URL(a.Mac)
	if key == nil || f.refuse || !Same(got, PeerMAC(key, nonce, peer, a.ID, origin)) {
		l.Write(ctx, Message{Refused: Unknown}.Line())
		return
	}
	l.Write(ctx, Message{OK: &OK{Mac: B64URL(ServerMAC(key, nonce, peer, a.ID, origin))}}.Line())
	if strings.HasPrefix(a.ID, "e:") {
		req, _ := l.Read(ctx)
		var call struct {
			Method string `json:"method"`
			Params struct {
				PublicKey []byte `json:"publicKey"`
			} `json:"params"`
		}
		json.Unmarshal([]byte(req), &call)
		if call.Method != "machines/announce" {
			f.t.Errorf("enrol said %s", call.Method)
		}
		f.mu.Lock()
		f.hostPublic = call.Params.PublicKey
		f.mu.Unlock()
		l.Write(ctx, `{"jsonrpc":"2.0","id":1,"result":{"host":"`+f.host+`"}}`)
		return
	}
	// The uplink: machine/hello on channel 0, then a channel opened and a message on it.
	first, _ := l.Read(ctx)
	var frame struct {
		C int `json:"c"`
		M struct {
			Method string       `json:"method"`
			Params MachineHello `json:"params"`
		} `json:"m"`
	}
	json.Unmarshal([]byte(first), &frame)
	if frame.C != 0 || frame.M.Method != "machine/hello" {
		f.t.Errorf("first uplink line %s", first)
	}
	f.hellos <- frame.M.Params
	if f.letGo {
		return
	}
	l.Write(ctx, `{"c":1,"open":{"client":"C","device":"D1","fanOut":true}}`)
	l.Write(ctx, `{"c":1,"m":{"jsonrpc":"2.0","id":7,"method":"daemon/ping"}}`)
	if f.uplinks.Add(1) == 1 && f.stall != nil {
		select {
		case <-f.stall:
		case <-ctx.Done():
		}
		return
	}
	for {
		line, err := l.Read(ctx)
		if err != nil {
			return
		}
		// machine/machines is answered on channel 0, as the control plane does (#1444).
		var ask struct {
			C int `json:"c"`
			M struct {
				ID     int64           `json:"id"`
				Method string          `json:"method"`
				Params json.RawMessage `json:"params"`
			} `json:"m"`
		}
		if json.Unmarshal([]byte(line), &ask) == nil && ask.C == 0 && ask.M.Method == "machine/machines" {
			id := strconv.FormatInt(ask.M.ID, 10)
			if strings.Contains(string(ask.M.Params), "refuse") {
				l.Write(ctx, `{"c":0,"m":{"jsonrpc":"2.0","id":`+id+`,"error":{"code":-32010,"message":"Agents can’t ask that of the control plane."}}}`)
			} else {
				l.Write(ctx, `{"c":0,"m":{"jsonrpc":"2.0","id":`+id+`,"result":{"providers":[]}}}`)
			}
			continue
		}
		f.channel <- line
	}
}

func (f *fakeControl) hostKey() []byte {
	f.mu.Lock()
	defer f.mu.Unlock()
	k, err := HostKey(f.private, f.hostPublic, f.host)
	if err != nil {
		f.t.Fatal(err)
	}
	return k
}

// A host enrols with its code, keeps control-host.json, dials as h:<host>, says machine/hello
// on channel 0 and serves a channel the control plane opens.
func TestEnrolThenUplink(t *testing.T) {
	f := newFakeControl(t)
	root := t.TempDir()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	private, err := HostPrivateKey(root)
	if err != nil {
		t.Fatal(err)
	}
	again, _ := HostPrivateKey(root)
	if string(again) != string(private) {
		t.Fatal("the host key changed between reads")
	}
	hello := MachineHello{Version: "1.2.3", Platform: "Linux arm64", MachineID: "m1", Name: new("devbox"), Implementation: new("go")}
	m, err := Enroll(ctx, root, f.code(), private, hello)
	if err != nil {
		t.Fatal(err)
	}
	if m.Host != f.host {
		t.Fatalf("host %q", m.Host)
	}
	if _, err := os.Stat(filepath.Join(root, "control-host.json")); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadMembership(root)
	if err != nil || loaded.Host != f.host || loaded.URL != f.srv.URL {
		t.Fatalf("loaded %+v %v", loaded, err)
	}
	served := make(chan string, 4)
	u := &Uplink{Root: root, Member: loaded, Private: private, Hello: hello, Accept: func(c Conn) {
		if c.Device() != "D1" {
			t.Errorf("device %q", c.Device())
		}
		// A control plane that reads fan-out frames is sent one for every channel (#167).
		if up, n, ok := c.(FanOuter).FanOutRoute(); !ok || n != 1 || up == nil {
			t.Errorf("route %v %d %v", up, n, ok)
		}
		for line := range c.In() {
			served <- line
			c.Write(`{"jsonrpc":"2.0","id":7,"result":{}}`)
		}
	}}
	go u.Run(ctx)
	select {
	case h := <-f.hellos:
		if h.Host == nil || string(*h.Host) != f.host || h.Implementation == nil || *h.Implementation != "go" || h.Version != "1.2.3" {
			t.Fatalf("hello %+v", h)
		}
	case <-ctx.Done():
		t.Fatal("no machine/hello")
	}
	if line := <-served; !strings.Contains(line, "daemon/ping") {
		t.Fatalf("served %s", line)
	}
	if line := <-f.channel; line != `{"c":1,"m":{"jsonrpc":"2.0","id":7,"result":{}}}` {
		t.Fatalf("reply frame %s", line)
	}
	// A request on channel 0 waits for its answer (#1444), or for the refusal.
	if got, err := u.Ask(ctx, "machine/machines", map[string]any{"agent": "Claude (x)", "method": "machines/forAgent", "params": map[string]any{}}); err != nil || string(got) != `{"providers":[]}` {
		t.Fatalf("ask %s %v", got, err)
	}
	var refused *AskError
	if _, err := u.Ask(ctx, "machine/machines", map[string]any{"method": "refuse"}); !errors.As(err, &refused) || refused.Code != -32010 || refused.Message != "Agents can’t ask that of the control plane." {
		t.Fatalf("refused %v", err)
	}
	u.WriteFanOut([]int{1, 3}, `{"jsonrpc":"2.0","method":"agent/changed","params":{}}`)
	if line := <-f.channel; line != `{"f":[1,3],"m":{"jsonrpc":"2.0","method":"agent/changed","params":{}}}` {
		t.Fatalf("fan-out frame %s", line)
	}
}

func TestEnrolRefused(t *testing.T) {
	f := newFakeControl(t)
	f.refuse = true
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := Enroll(ctx, t.TempDir(), f.code(), NewPrivateKey(), MachineHello{})
	var r *Refusal
	if !errors.As(err, &r) || r.Reason != Unknown {
		t.Fatalf("err %v", err)
	}
}

// The membership file keeps the Swift ControlMembership's shape: Data as base64.
func TestMembershipShape(t *testing.T) {
	root := t.TempDir()
	m := &Membership{Host: "h1", ControlKey: []byte{4, 1, 2}, Addresses: []string{}, Name: "n", URL: "https://x"}
	if err := m.Save(root); err != nil {
		t.Fatal(err)
	}
	b, _ := os.ReadFile(filepath.Join(root, "control-host.json"))
	if !strings.Contains(string(b), `"controlKey":"BAEC"`) {
		t.Fatalf("file %s", b)
	}
}
