package controlplane

import (
	"context"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// A control plane in this process, over plain HTTP on loopback, with the Go host's and a
// window's side of the link (controllink) as its members.
type plane struct {
	t       *testing.T
	s       *Service
	url     string
	store   store.Store
	private []byte
	lines   chan string
}

func freePort(t *testing.T) int {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	return ln.Addr().(*net.TCPAddr).Port
}

func startPlane(t *testing.T, st store.Store, private []byte) *plane {
	port := freePort(t)
	p := &plane{t: t, url: "http://127.0.0.1:" + itoa(port), store: st, private: private, lines: make(chan string, 1000)}
	s, err := New(Config{Store: st, PrivateKey: private, URL: p.url, Bind: "127.0.0.1", Port: port,
		Name: "Test plane", MachineID: "MACHINE-1", Log: func(l string) {
			select {
			case p.lines <- l:
			default:
			}
		}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Stop)
	p.s = s
	return p
}

func itoa(n int) string { return strconv.Itoa(n) }

func (p *plane) code(host bool) *controllink.Code {
	shown, err := p.s.Codes().Issue(context.Background(), host, false, time.Minute)
	if err != nil {
		p.t.Fatal(err)
	}
	c, err := controllink.ParseCode(shown.Text)
	if err != nil {
		p.t.Fatal(err)
	}
	return c
}

// fakeHost enrols with a host code and serves each channel: daemon/ping and
// agents/list are answered, anything else is method-not-found.
type fakeHost struct {
	member *controllink.Membership
	cancel context.CancelFunc
	done   chan struct{}
	mu     sync.Mutex
	opened []string
}

func (p *plane) host(machine string) *fakeHost {
	root := p.t.TempDir()
	private := controllink.NewPrivateKey()
	hello := controllink.HostHello{Version: "0.1", Platform: "linux aarch64", MachineID: machine, Name: "box " + machine,
		Implementation: "go"}
	member, err := controllink.Enroll(context.Background(), root, p.code(true), private, hello)
	if err != nil {
		p.t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	h := &fakeHost{member: member, cancel: cancel, done: make(chan struct{})}
	u := &controllink.Uplink{Root: root, Member: member, Private: private, Hello: hello, Accept: func(c controllink.Conn) {
		h.mu.Lock()
		h.opened = append(h.opened, c.Device())
		h.mu.Unlock()
		for line := range c.In() {
			var m struct {
				ID     json.RawMessage `json:"id"`
				Method string          `json:"method"`
			}
			json.Unmarshal([]byte(line), &m)
			switch m.Method {
			case "daemon/ping":
				c.Write(reply(m.ID, map[string]any{"pong": member.Host}))
			case "agents/list":
				c.Write(reply(m.ID, []any{}))
			default:
				c.Write(replyError(m.ID, notFound(m.Method)))
			}
		}
	}}
	go func() {
		defer close(h.done)
		u.Run(ctx)
	}()
	p.t.Cleanup(h.stop)
	p.waitFor(func() bool { s, ok := p.s.Router().State(member.Host); return ok && s.online() }, "the host online")
	return h
}

func (h *fakeHost) stop() {
	h.cancel()
	<-h.done
}

func (p *plane) client(name string) (*controllink.ClientMembership, *controllink.Session) {
	m, err := controllink.PairClient(context.Background(), p.code(false), name)
	if err != nil {
		p.t.Fatal(err)
	}
	s, err := controllink.DialClient(context.Background(), m)
	if err != nil {
		p.t.Fatal(err)
	}
	p.t.Cleanup(s.Close)
	return m, s
}

func (p *plane) waitFor(ok func() bool, what string) {
	p.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			p.t.Fatalf("waited for %s", what)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func call(t *testing.T, s *controllink.Session, host, method string, params any) json.RawMessage {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	got, err := s.Call(ctx, host, method, params)
	if err != nil {
		t.Fatalf("%s %s: %v", host, method, err)
	}
	return got
}

func callError(t *testing.T, s *controllink.Session, host, method string, params any) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, err := s.Call(ctx, host, method, params)
	if err == nil {
		t.Fatalf("%s %s answered", host, method)
	}
	return err.Error()
}

// The whole path: a host enrols and connects, a window pairs and connects, the window's
// calls reach the host through its channel and the control plane's own methods answer.
func TestAHostAndAWindowThroughTheControlPlane(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	// A host on the control plane's own machine is its home host, mac.
	home := p.host("MACHINE-1")
	if home.member.Host != "mac" {
		t.Fatal(home.member.Host)
	}
	box := p.host("MACHINE-2")
	if box.member.Host == "mac" || len(box.member.Host) != 8 {
		t.Fatal(box.member.Host)
	}
	member, window := p.client("Test window")

	var pong struct{ Pong string }
	json.Unmarshal(call(t, window, box.member.Host, "daemon/ping", nil), &pong)
	if pong.Pong != box.member.Host {
		t.Fatal(pong)
	}
	call(t, window, "mac", "agents/list", nil)

	var status struct {
		Name      string  `json:"name"`
		HomeHost  string  `json:"homeHost"`
		You       string  `json:"you"`
		StartedAt float64 `json:"startedAt"`
	}
	json.Unmarshal(call(t, window, "", "control/status", nil), &status)
	if status.Name != "Test plane" || status.HomeHost != "mac" || status.You != member.Client || status.StartedAt < 8e8 {
		t.Fatalf("%+v", status)
	}
	var hosts []controlHost
	json.Unmarshal(call(t, window, "", "hosts/list", nil), &hosts)
	if len(hosts) != 2 || hosts[0].State != "online" || hosts[1].State != "online" || hosts[0].Implementation != "go" {
		t.Fatalf("%+v", hosts)
	}
	var clients []map[string]any
	json.Unmarshal(call(t, window, "", "clients/list", nil), &clients)
	if len(clients) != 1 || clients[0]["grant"] != "operator" || clients[0]["kind"] != "mac" {
		t.Fatalf("%+v", clients)
	}

	// A host no one enrolled is refused as such, and an unknown method in words.
	if e := callError(t, window, "nobody", "daemon/ping", nil); !strings.Contains(e, "-32091") {
		t.Fatal(e)
	}
	if e := callError(t, window, "", "nothing/here", nil); !strings.Contains(e, "-32601") {
		t.Fatal(e)
	}

	// The host goes: its calls are answered offline, and every window hears it.
	box.stop()
	p.waitFor(func() bool { s, _ := p.s.Router().State(box.member.Host); return !s.online() }, "the host offline")
	if e := callError(t, window, box.member.Host, "daemon/ping", nil); !strings.Contains(e, "-32090") {
		t.Fatal(e)
	}
}

// A code works once; the same key spending it again is the same join (#212).
func TestACodeIsUsedOnce(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	c := p.code(false)
	if _, err := controllink.PairClient(context.Background(), c, "First"); err != nil {
		t.Fatal(err)
	}
	if _, err := controllink.PairClient(context.Background(), c, "Second"); err == nil || !strings.Contains(err.Error(), spentWords) {
		t.Fatalf("a spent code paired: %v", err)
	}
	// A client code is no host code.
	if _, err := controllink.Enroll(context.Background(), t.TempDir(), &controllink.Code{Host: true, ControlKey: c.ControlKey,
		Secret: p.code(false).Secret, URL: c.URL, Name: c.Name}, controllink.NewPrivateKey(), controllink.HostHello{}); err == nil {
		t.Fatal("a client code enrolled a host")
	}
	// A spent code replayed by the key that spent it is given the same host.
	hc := p.code(true)
	priv := controllink.NewPrivateKey()
	first, err := controllink.Enroll(context.Background(), t.TempDir(), hc, priv, controllink.HostHello{Name: "a", MachineID: "X"})
	if err != nil {
		t.Fatal(err)
	}
	again, err := controllink.Enroll(context.Background(), t.TempDir(), hc, priv, controllink.HostHello{Name: "a", MachineID: "X"})
	if err != nil || again.Host != first.Host {
		t.Fatal(again, err)
	}
	if _, err := controllink.Enroll(context.Background(), t.TempDir(), hc, controllink.NewPrivateKey(), controllink.HostHello{}); err == nil {
		t.Fatal("another key used a spent code")
	}
}

// clients/forget: its sockets close with 4403, and it is refused as forgotten after.
func TestAForgottenClientIsClosedAndRefused(t *testing.T) {
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Window")
	other, phone := p.client("Phone")
	call(t, window, "", "clients/forget", map[string]string{"client": other.Client})
	p.waitFor(func() bool { return p.s.Router().Sessions() == 1 }, "the phone's session to end")
	_, err := phone.Call(context.Background(), "", "control/status", nil)
	if err == nil {
		t.Fatal("a forgotten client was answered")
	}
	if _, err := controllink.DialClient(context.Background(), other); err == nil || !strings.Contains(err.Error(), "forgotten") {
		t.Fatalf("a forgotten client connected: %v", err)
	}
}

// A copy started again on the same folder and key is the same control plane: the host
// rejoins with its membership, and the window with its pairing.
func TestTheFolderAndKeyAreTheControlPlane(t *testing.T) {
	root := t.TempDir()
	key := controllink.NewPrivateKey()
	st := store.NewFolder(filepath.Join(root, "store"))
	p := startPlane(t, st, key)
	h := p.host("MACHINE-2")
	member, _ := p.client("Window")
	h.stop()
	p.s.Stop()

	q := startPlane(t, store.NewFolder(filepath.Join(root, "store")), key)
	// The members' address is the old copy's; this one answers at another port, so they
	// are pointed at it as a moved copy's members would be.
	member.URL = q.url
	window, err := controllink.DialClient(context.Background(), member)
	if err != nil {
		t.Fatal(err)
	}
	defer window.Close()
	var hosts []controlHost
	json.Unmarshal(call(t, window, "", "hosts/list", nil), &hosts)
	if len(hosts) != 1 || hosts[0].ID != h.member.Host {
		t.Fatalf("%+v", hosts)
	}
	// Another key is not this store's control plane.
	s, _ := New(Config{Store: store.NewFolder(filepath.Join(root, "store")), PrivateKey: controllink.NewPrivateKey(),
		URL: "http://127.0.0.1:1", Port: 0, Bind: "127.0.0.1"})
	if _, err := s.Start(context.Background()); err == nil || !strings.Contains(err.Error(), "another key") {
		t.Fatal(err)
	}
}

// A store the Swift control plane wrote is taken up as it is.
func TestASwiftStoreIsTakenUp(t *testing.T) {
	root := t.TempDir()
	key := controllink.NewPrivateKey()
	public, _ := controllink.PublicKey(key)
	st := store.NewFolder(root)
	settings := records.Settings{Name: "Swift plane", Port: 8790, MachineID: "M", ControlKey: public}
	r := records.New(st)
	if _, err := r.SettingsOrMake(context.Background(), func() records.Settings { return settings }); err != nil {
		t.Fatal(err)
	}
	r.SaveHost(context.Background(), records.HostRecord{ID: "mac", Name: "Mac", Platform: "macOS arm64"})
	p := startPlane(t, store.NewFolder(root), key)
	if p.s.Records().Host("mac") == nil {
		t.Fatal("the host went")
	}
	data, _ := os.ReadFile(filepath.Join(root, "v1", "control.json"))
	var written map[string]any
	json.Unmarshal(data, &written)
	if written["name"] != "Swift plane" || written["url"] != p.url {
		t.Fatalf("%s", data)
	}
}

func TestTheInstallScriptIsSwifts(t *testing.T) {
	theirs, err := os.ReadFile("../../../scripts/host-install.sh")
	if err != nil {
		t.Skip("scripts/ is not here (the Go module alone, in a container)")
	}
	if string(theirs) != InstallScript {
		t.Fatal("install.sh differs from scripts/host-install.sh: copy it again")
	}
	if got := InstallCommand("https://a:1/", "68pJOOtmq-dhsJdha_txtRqkMHL-HsskodMb3odpx3s", "CODE"); got !=
		"curl -fsSL --insecure --pinnedpubkey sha256//68pJOOtmq+dhsJdha/txtRqkMHL+HsskodMb3odpx3s= https://a:1/v1/install.sh | sh -s -- 'CODE'" {
		t.Fatal(got)
	}
}

func TestStampedLines(t *testing.T) {
	at := time.Date(2026, 10, 16, 9, 0, 0, 123e6, time.Local)
	got := stamped("one\ntwo", at)
	lines := strings.Split(strings.TrimSuffix(got, "\n"), "\n")
	if len(lines) != 2 || !strings.HasSuffix(lines[1], " two") || !strings.HasPrefix(lines[0], "2026-10-16T09:00:00.123") {
		t.Fatal(got)
	}
}
