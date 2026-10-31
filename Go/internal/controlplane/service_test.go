package controlplane

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/web"
	"github.com/alexec/agents/Go/wire"
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
	// told hears what each host is told on its channel 0, when set before it connects.
	told func(host, method string, params json.RawMessage)
	// asked answers what the control plane asks a fake host on channel 0 (#2011).
	asked func(host, method string, params json.RawMessage) (any, bool)
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
	return startPlaneWith(t, st, private, nil)
}

// startPlaneWith is startPlane with something of its Config changed first.
func startPlaneWith(t *testing.T, st store.Store, private []byte, change func(*Config)) *plane {
	// freePort lets its port go before the plane binds it, and the tests run in parallel
	// (#2512), so another test can take it in between: try a new one then.
	for range 4 {
		p, err := tryStartPlane(t, st, private, change)
		if err == nil {
			return p
		}
		if !errors.Is(err, syscall.EADDRINUSE) {
			t.Fatal(err)
		}
	}
	t.Fatal("no free port for the plane")
	return nil
}

func tryStartPlane(t *testing.T, st store.Store, private []byte, change func(*Config)) (*plane, error) {
	port := freePort(t)
	p := &plane{t: t, url: "http://127.0.0.1:" + itoa(port), store: st, private: private, lines: make(chan string, 1000)}
	cfg := Config{Store: st, PrivateKey: private, URL: p.url, Bind: "127.0.0.1", Port: port,
		Name: "Test plane", MachineID: "MACHINE-1", Log: func(l string) {
			select {
			case p.lines <- l:
			default:
			}
		}}
	if change != nil {
		change(&cfg)
	}
	s, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		return nil, err
	}
	t.Cleanup(s.Stop)
	p.s = s
	return p, nil
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
	root   string
	member *controllink.Membership
	cancel context.CancelFunc
	done   chan struct{}
	mu     sync.Mutex
	opened []string
	// uplink is the host's side of the link, to ask the control plane on channel 0.
	uplink *controllink.Uplink
	// private is the host's own P-256 key, which what is sealed to it opens with (#999).
	private []byte
}

func (p *plane) host(machine string) *fakeHost { return p.hostWith(machine, nil) }

// hostWith is host, told each channel as it opens.
func (p *plane) hostWith(machine string, opened func(controllink.Conn)) *fakeHost {
	return p.hostSaying(fakeHello(machine), opened)
}

// olderHost is a host from before #1748: it says no capabilities.
func (p *plane) olderHost(machine string) *fakeHost {
	hello := fakeHello(machine)
	hello.Capabilities = nil
	return p.hostSaying(hello, nil)
}

func (p *plane) hostSaying(hello controllink.MachineHello, opened func(controllink.Conn)) *fakeHost {
	root := p.t.TempDir()
	private := controllink.NewPrivateKey()
	member, err := controllink.Enroll(context.Background(), root, p.code(true), private, hello)
	if err != nil {
		p.t.Fatal(err)
	}
	return p.serveHost(root, member, private, hello, opened)
}

// fakeHello is a host of this build: it says the capabilities a host declares.
func fakeHello(machine string) controllink.MachineHello {
	return controllink.MachineHello{Version: "0.1", Platform: "linux aarch64", MachineID: machine, Name: new("box " + machine),
		Implementation: new("go"), Capabilities: wire.DeclaredCapabilities["host"]}
}

// serveHost connects a host that has joined, and answers its channels as host does.
func (p *plane) serveHost(root string, member *controllink.Membership, private []byte, hello controllink.MachineHello, opened func(controllink.Conn)) *fakeHost {
	ctx, cancel := context.WithCancel(context.Background())
	h := &fakeHost{root: root, member: member, cancel: cancel, done: make(chan struct{}), private: private}
	told, asked := p.told, p.asked
	u := &controllink.Uplink{Root: root, Member: member, Private: private, Hello: hello, Told: func(method string, params json.RawMessage) {
		if told != nil {
			told(member.Host, method, params)
		}
	}, Accept: func(c controllink.Conn) {
		h.mu.Lock()
		h.opened = append(h.opened, c.Device())
		h.mu.Unlock()
		if opened != nil {
			opened(c)
		}
		for line := range c.In() {
			var m struct {
				ID     json.RawMessage `json:"id"`
				Method string          `json:"method"`
			}
			json.Unmarshal([]byte(line), &m)
			switch m.Method {
			case "daemon/ping":
				c.Write(reply(m.ID, map[string]any{"pong": member.Host}))
			case "agents/list", "elicitations/pending":
				c.Write(reply(m.ID, []any{}))
			case "worktrees/all":
				c.Write(reply(m.ID, fakeWorktrees))
			default:
				c.Write(replyError(m.ID, notFound(m.Method)))
			}
		}
	}}
	h.uplink = u
	if asked != nil {
		u.Asked = func(method string, params json.RawMessage) (any, bool) { return asked(member.Host, method, params) }
	}
	go func() {
		defer close(h.done)
		u.Run(ctx)
	}()
	p.t.Cleanup(h.stop)
	p.waitFor(func() bool { s, ok := p.s.Router().State(member.Host); return ok && s.online() }, "the host online")
	return h
}

// fakeWorktrees is every fake host's worktrees/all: one ahead of its upstream, one with
// no upstream and commits not on the base, one with a change not committed, one pushed.
var fakeWorktrees = []map[string]any{{"folder": "file:///work/app", "worktrees": []map[string]any{
	{"name": "ahead", "root": "file:///work/app-ahead", "branch": "agents/ahead", "isFolderPath": false, "exists": true,
		"madeByApp": true, "agents": []string{}, "status": map[string]any{"uncommitted": 0, "ahead": 2, "behind": 0}},
	{"name": "local", "root": "file:///work/app-local", "branch": "agents/local", "isFolderPath": false, "exists": true,
		"madeByApp": true, "agents": []string{}, "status": map[string]any{"uncommitted": 0, "unmerged": 4}},
	{"name": "dirty", "root": "file:///work/app-dirty", "branch": "agents/dirty", "isFolderPath": false, "exists": true,
		"madeByApp": true, "agents": []string{}, "status": map[string]any{"uncommitted": 1, "ahead": 0, "behind": 0}},
	{"name": "pushed", "root": "file:///work/app-pushed", "branch": "agents/pushed", "isFolderPath": false, "exists": true,
		"madeByApp": true, "agents": []string{}, "status": map[string]any{"uncommitted": 0, "ahead": 0, "behind": 3}},
}}}

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
	t.Parallel()
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
	var hosts []wire.ControlMachine
	json.Unmarshal(call(t, window, "", "hosts/list", nil), &hosts)
	if len(hosts) != 2 || hosts[0].State != "online" || hosts[1].State != "online" || deref(hosts[0].Implementation) != "go" {
		t.Fatalf("%+v", hosts)
	}
	var clients []map[string]any
	json.Unmarshal(call(t, window, "", "clients/list", nil), &clients)
	if len(clients) != 1 || clients[0]["kind"] != "mac" {
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
	t.Parallel()
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
		Secret: p.code(false).Secret, URL: c.URL, Name: c.Name}, controllink.NewPrivateKey(), controllink.MachineHello{}); err == nil {
		t.Fatal("a client code enrolled a host")
	}
	// A spent code replayed by the key that spent it is given the same host.
	hc := p.code(true)
	priv := controllink.NewPrivateKey()
	first, err := controllink.Enroll(context.Background(), t.TempDir(), hc, priv, controllink.MachineHello{Name: new("a"), MachineID: "X"})
	if err != nil {
		t.Fatal(err)
	}
	again, err := controllink.Enroll(context.Background(), t.TempDir(), hc, priv, controllink.MachineHello{Name: new("a"), MachineID: "X"})
	if err != nil || again.Host != first.Host {
		t.Fatal(again, err)
	}
	if _, err := controllink.Enroll(context.Background(), t.TempDir(), hc, controllink.NewPrivateKey(), controllink.MachineHello{}); err == nil {
		t.Fatal("another key used a spent code")
	}
}

// clients/forget: its sockets close with 4403, and it is refused as forgotten after.
func TestAForgottenClientIsClosedAndRefused(t *testing.T) {
	t.Parallel()
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
	t.Parallel()
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
	var hosts []wire.ControlMachine
	json.Unmarshal(call(t, window, "", "hosts/list", nil), &hosts)
	if len(hosts) != 1 || string(hosts[0].ID) != h.member.Host {
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
	t.Parallel()
	root := t.TempDir()
	key := controllink.NewPrivateKey()
	public, _ := controllink.PublicKey(key)
	st := store.NewFolder(root)
	settings := records.Settings{Name: "Swift plane", Port: 8790, MachineID: "M", ControlKey: public}
	r := records.New(st)
	if _, err := r.SettingsOrMake(context.Background(), func() records.Settings { return settings }); err != nil {
		t.Fatal(err)
	}
	r.SaveHost(context.Background(), records.MachineRecord{ID: "mac", Name: "Mac", Platform: "macOS arm64"})
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
	t.Parallel()
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
	t.Parallel()
	at := time.Date(2026, 10, 16, 9, 0, 0, 123e6, time.Local)
	got := stamped("one\ntwo", at)
	lines := strings.Split(strings.TrimSuffix(got, "\n"), "\n")
	if len(lines) != 2 || !strings.HasSuffix(lines[1], " two") || !strings.HasPrefix(lines[0], "2026-10-16T09:00:00.123") {
		t.Fatal(got)
	}
}

// A browser pairs and connects through the loopback listener only, bound to its origin;
// a window's code and key are refused there, and a browser's code over TLS (071).
func TestABrowserThroughTheLoopbackListener(t *testing.T) {
	t.Parallel()
	dist := t.TempDir()
	index := []byte("<html></html>")
	sum := sha256.Sum256(index)
	os.WriteFile(filepath.Join(dist, "index.html"), index, 0o644)
	os.WriteFile(filepath.Join(dist, "MANIFEST"), []byte("agents-web 1\nout "+hex.EncodeToString(sum[:])+" Web/dist/index.html\n"), 0o644)

	port := freePort(t)
	url := "http://127.0.0.1:" + itoa(port)
	var webChanged []web.Status
	s, err := New(Config{Store: store.NewMemory(), PrivateKey: controllink.NewPrivateKey(), URL: url, Bind: "127.0.0.1",
		Port: port, Name: "Test plane", Web: &WebConfig{Folder: dist, Port: 0},
		WebChanged: func(st web.Status) { webChanged = append(webChanged, st) }})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	if len(webChanged) != 1 || !webChanged[0].Served || s.WebPort() == 0 {
		t.Fatalf("%+v", webChanged)
	}
	origin := web.OriginFor(s.WebPort())

	pair := func(browser bool, kind string, at string) (string, []byte, error) {
		shown, err := s.Codes().Issue(context.Background(), false, browser, time.Minute)
		if err != nil {
			t.Fatal(err)
		}
		code, _ := controllink.ParseCode(shown.Text)
		l, err := dialBrowser(at, origin)
		if err != nil {
			return "", nil, err
		}
		defer l.Close()
		auth, _, err := answerHello(l, controllink.Identity{Kind: 'p', ID: code.ID()}, controllink.CodeKey(code.Secret), at, "browser")
		if err != nil {
			return "", nil, err
		}
		_ = auth
		private := controllink.NewPrivateKey()
		public, _ := controllink.PublicKey(private)
		id := records.NewUUID()
		params, _ := json.Marshal(wire.ClientAnnounce{ID: wire.UUID(id), PublicKey: public, Name: "Safari", Kind: wire.ClientKind(kind)})
		l.Write(context.Background(), `{"jsonrpc":"2.0","id":1,"method":"clients/announce","params":`+string(params)+`}`)
		line, err := l.Read(context.Background())
		if err != nil {
			return "", nil, err
		}
		if !strings.Contains(line, `"result"`) {
			return "", nil, fmt.Errorf("%s", line)
		}
		return id, private, nil
	}
	// A window's code is no good at the loopback listener.
	if _, _, err := pair(false, records.KindBrowser, origin); err == nil || !strings.Contains(err.Error(), "That code is for a window or a phone") {
		t.Fatal(err)
	}
	id, private, err := pair(true, records.KindBrowser, origin)
	if err != nil {
		t.Fatal(err)
	}
	if c := s.Records().Client(id); c == nil || !strings.HasPrefix(c.Name, "Safari on ") || c.Kind != records.KindBrowser {
		t.Fatal(c)
	}
	// The browser's key proves itself at the loopback listener, bound to its origin…
	public, _ := controllink.PublicKey(s.cfg.PrivateKey)
	key, _ := controllink.ClientKey(private, public, id)
	l, err := dialBrowser(origin, origin)
	if err != nil {
		t.Fatal(err)
	}
	if _, ok, err := answerHello(l, controllink.Identity{Kind: 'c', ID: id}, key, origin, "browser"); err != nil || ok == nil {
		t.Fatal(err)
	}
	l.Close()
	// …and nowhere else: not over the TLS listener's door.
	l, err = controllink.Dial(context.Background(), url, "")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	if _, _, err := answerHello(l, controllink.Identity{Kind: 'c', ID: id}, key, url, "browser"); err == nil {
		t.Fatal("a browser's key worked over the TLS listener")
	}
}

// dialBrowser opens the loopback listener's socket as the page does, with its Origin.
func dialBrowser(base, origin string) (*controllink.Lines, error) {
	return controllink.DialOrigin(context.Background(), base, origin)
}

// answerHello goes through the exchange by hand: it returns the auth sent and the ok, or
// the refusal.
func answerHello(l *controllink.Lines, id controllink.Identity, key []byte, at, kind string) (*controllink.Auth, *controllink.OK, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	line, err := l.Read(ctx)
	if err != nil {
		return nil, nil, err
	}
	m, _ := controllink.ParseMessage(line)
	if m.Hello == nil {
		return nil, nil, fmt.Errorf("no hello: %s", line)
	}
	origin, _ := controllink.Origin(at)
	auth, expect, err := controllink.Answer(m.Hello, id, key, origin, kind, nil, "", nil)
	if err != nil {
		return nil, nil, err
	}
	l.Write(ctx, controllink.Message{Auth: auth}.Line())
	line, err = l.Read(ctx)
	if err != nil {
		return nil, nil, err
	}
	m, _ = controllink.ParseMessage(line)
	if m.OK == nil {
		return nil, nil, fmt.Errorf("refused: %s", line)
	}
	return auth, m.OK, controllink.Check(m.OK, expect)
}

// hosts/install is answered by the installer, in its words, through the router.
func TestHostsInstallAnswersInItsWords(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Window")
	if e := callError(t, window, "", "hosts/install", map[string]string{"destination": " "}); !strings.Contains(e, "Say which server.") {
		t.Fatal(e)
	}
	if e := callError(t, window, "", "hosts/update", map[string]string{"host": "x", "destination": "devbox"}); !strings.Contains(e, "There is no such host.") {
		t.Fatal(e)
	}
	call(t, window, "", "hosts/checkAgain", map[string]string{"host": "x"})
}

// rawHost enrols and connects a host by hand, and returns its uplink's lines: for a
// relay host (agents-relay), whose channel 0 the test reads itself.
func (p *plane) rawHost(name string, relay bool) (string, *controllink.Lines) {
	host, l, _ := p.rawHostKey(name, relay)
	return host, l
}

// rawHostKey is rawHost, with the key the host proves itself with.
func (p *plane) rawHostKey(name string, relay bool) (string, *controllink.Lines, []byte) {
	ctx := context.Background()
	code := p.code(true)
	private := controllink.NewPrivateKey()
	public, _ := controllink.PublicKey(private)
	l, _, err := controllink.Join(ctx, code.URL, "", controllink.Credentials{Identity: "e:" + code.ID(),
		Key: controllink.CodeKey(code.Secret), Kind: "host", ControlKey: code.ControlKey})
	if err != nil {
		p.t.Fatal(err)
	}
	params, _ := json.Marshal(wire.MachineAnnounce{PublicKey: public, Name: name, Platform: "macOS arm64", Version: "1",
		MachineID: "RELAY-MAC", Relay: &relay})
	l.Write(ctx, `{"jsonrpc":"2.0","id":1,"method":"hosts/announce","params":`+string(params)+`}`)
	line, err := l.Read(ctx)
	if err != nil {
		p.t.Fatal(err)
	}
	l.Close()
	var answer struct {
		Result wire.Admitted `json:"result"`
	}
	json.Unmarshal([]byte(line), &answer)
	host := string(deref(answer.Result.Host))
	key, _ := controllink.HostKey(private, code.ControlKey, host)
	l, _, err = controllink.Join(ctx, code.URL, "", controllink.Credentials{Identity: "h:" + host, Key: key,
		Kind: "host", ControlKey: code.ControlKey})
	if err != nil {
		p.t.Fatal(err)
	}
	hello, _ := json.Marshal(wire.MachineHello{Version: "1", Platform: "macOS arm64", MachineID: "RELAY-MAC", Relay: &relay})
	l.Write(ctx, channelFrame(0, `{"jsonrpc":"2.0","id":1,"method":"host/hello","params":`+string(hello)+`}`))
	p.t.Cleanup(l.Close)
	return host, l, key
}

// readUntil reads a host's lines until one holds want.
func readUntil(t *testing.T, l *controllink.Lines, want string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for {
		line, err := l.Read(ctx)
		if err != nil {
			t.Fatalf("no %s: %v", want, err)
		}
		if strings.Contains(line, want) {
			return line
		}
	}
}

// A need a host raises goes to the relay host, sealed to the device the ladder picks
// (T097): the iPhone that may notify, then taken back when the need is met.
func TestANeedGoesToTheRelayHost(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	relayID, relay := p.rawHost("relay mac", true)
	if relayID == "mac" {
		t.Fatal("a relay was made the home host")
	}
	box := p.host("MACHINE-2")
	// A phone pairs and says it may notify; the relay host hears the devices.
	m, err := controllink.PairClient(context.Background(), p.code(false), "phone")
	if err != nil {
		t.Fatal(err)
	}
	yes := true
	if err := p.s.Records().ChangeClient(context.Background(), m.Client, func(c *records.ClientRecord) bool {
		c.Kind, c.MayNotify = records.KindIPhone, &yes
		return true
	}); err != nil {
		t.Fatal(err)
	}
	p.s.tellRelayDevices()
	readUntil(t, relay, m.Client)
	// The window was given no channel on the relay host.
	if n := p.s.Router().Channels(relayID); n != 0 {
		t.Fatal(n)
	}

	need := `{"need":{"id":{"permission":"E0000000-0000-4000-8000-000000000005"},"agentID":"A0000000-0000-4000-8000-000000000001",` +
		`"folder":"file:///work","kind":"permission","raisedAt":800000000,"headline":{"h1":"work","h2":"Fix","h3":"may run"}},"buzz":true}`
	if _, err := p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(need)); err != nil {
		t.Fatal(err)
	}
	line := readUntil(t, relay, "relay/deliver")
	if !strings.Contains(line, `"device":"`+m.Client+`"`) || !strings.Contains(line, `"alert":true`) || !strings.Contains(line, `"h2":"Fix"`) {
		t.Fatal(line)
	}
	p.s.methods.HostSaid(box.member.Host, "attention/need", json.RawMessage(`{"withdraw":{"permission":"E0000000-0000-4000-8000-000000000005"}}`))
	if line := readUntil(t, relay, "relay/deliver"); strings.Contains(line, "headline") {
		t.Fatal(line)
	}
}

// A kept request goes to a host on a channel of its own and comes back with its reply;
// one for a host that is not here is nil (ControlRouter.deliverKept).
// keptClient is who the kept request comes from.
const keptClient = "C4A77E15-0000-4000-8000-000000001009"

func TestAKeptRequestIsDelivered(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("MACHINE-2")
	m := p.s.Router().DeliverKept("elicitations/pending", map[string]any{}, keptClient, records.KindUnknown, box.member.Host, 5*time.Second)
	if m == nil || string(m.Result) != "[]" {
		t.Fatal(m)
	}
	if n := p.s.Router().Channels(box.member.Host); n != 0 {
		t.Fatalf("%d channels left open", n)
	}
	if p.s.Router().DeliverKept("x", nil, keptClient, records.KindUnknown, "nobody", time.Second) != nil {
		t.Fatal("delivered to nobody")
	}
}

// Machine providers answer on a single copy with a home for their secrets, and say
// why not anywhere else (#691).
func TestProvidersAnswerWhereTheyCanRun(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Window")
	if e := callError(t, window, "", "providers/list", nil); !strings.Contains(e, "-32064") {
		t.Fatal(e)
	}

	port := freePort(t)
	url := "http://127.0.0.1:" + itoa(port)
	s, err := New(Config{Store: store.NewMemory(), PrivateKey: controllink.NewPrivateKey(), URL: url, Bind: "127.0.0.1",
		Port: port, Name: "With providers", ProviderHome: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	defer s.Stop()
	shown, _ := s.Codes().Issue(context.Background(), false, false, time.Minute)
	code, _ := controllink.ParseCode(shown.Text)
	member, err := controllink.PairClient(context.Background(), code, "Window")
	if err != nil {
		t.Fatal(err)
	}
	w, err := controllink.DialClient(context.Background(), member)
	if err != nil {
		t.Fatal(err)
	}
	defer w.Close()
	var listed struct {
		Providers []any `json:"providers"`
	}
	if err := json.Unmarshal(call(t, w, "", "providers/list", nil), &listed); err != nil || listed.Providers == nil {
		t.Fatalf("%v %+v", err, listed)
	}
	// A kept request's list is there, and empty.
	call(t, w, "", "hosts/listKept", map[string]any{})
}

// A host says which language it is written in (#1134): kept from its announce and its hello,
// and a hello from the other language on the same root replaces it, as
// HostImplementationTests.itIsKeptFromTheHelloAndListed.
func TestAHostsImplementationIsKeptFromItsHello(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("MACHINE-2")
	implementation := func() string {
		var said string
		if rec := p.s.records.Host(box.member.Host); rec != nil {
			json.Unmarshal(rec.Extra["implementation"], &said)
		}
		return said
	}
	p.waitFor(func() bool { return implementation() == "go" }, "go from the announce")
	hello := func(impl string) {
		params, _ := json.Marshal(map[string]any{"version": "0.1", "platform": "linux aarch64", "machineID": "MACHINE-2",
			"implementation": impl})
		if _, err := p.s.methods.HostSaid(box.member.Host, "host/hello", params); err != nil {
			t.Fatal(err)
		}
	}
	hello("swift")
	if got := implementation(); got != "swift" {
		t.Fatalf("after a Swift hello: %q", got)
	}
	hello("")
	if got := implementation(); got != "" {
		t.Fatalf("a hello from before the field: %q", got)
	}
}

func TestToolsetFilesAreTheNamedOnesOnly(t *testing.T) {
	t.Parallel()
	folder := t.TempDir()
	os.MkdirAll(filepath.Join(folder, "claude"), 0o755)
	os.WriteFile(filepath.Join(folder, "claude", "manifest.json"), []byte(`{"runtimeID":"claude"}`), 0o644)
	os.WriteFile(filepath.Join(folder, "claude", "mac-node.json"), []byte(`{}`), 0o644)
	if data, ok := toolsetFile("claude/manifest.json", folder); !ok || string(data) != `{"runtimeID":"claude"}` {
		t.Fatalf("manifest: %q %v", data, ok)
	}
	for _, name := range []string{"claude/mac-node.json", "claude/../claude/manifest.json", "opencode/manifest.json", "claude/package.json"} {
		if _, ok := toolsetFile(name, folder); ok {
			t.Fatalf("%s was handed out", name)
		}
	}
	if _, ok := toolsetFile("claude/manifest.json", ""); ok {
		t.Fatal("no folder, yet a file")
	}
}

// Every host hears which windows are paired, and hears it again when one is forgotten: the
// policy it checks its local socket against (#1118).
func TestHostsHearThePairedWindows(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, host := p.rawHost("this mac", false)
	m, err := controllink.PairClient(context.Background(), p.code(false), "window")
	if err != nil {
		t.Fatal(err)
	}
	for line := readUntil(t, host, "host/clients"); !strings.Contains(line, m.Client); line = readUntil(t, host, "host/clients") {
	}
	if err := p.s.methods.forget(context.Background(), m.Client, 0); err != nil {
		t.Fatal(err)
	}
	// A listing sent before the forget can still be on its way (the pairing can send more
	// than one), so read on until one leaves the window out, for at most 10 s (#2512).
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	for {
		line, err := host.Read(ctx)
		if err != nil {
			t.Fatal("a forgotten window is still listed:", err)
		}
		if strings.Contains(line, "host/clients") && !strings.Contains(line, m.Client) {
			return
		}
	}
}

// A host hears host/clients when it says hello and when the paired windows change, not
// on every refresh (#1528): forty refreshes (ten minutes of them) tell it nothing, so the
// next host/clients it reads is the one that lists a new window.
func TestAHostHearsThePairedWindowsOnlyWhenTheyChange(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, host := p.rawHost("this mac", false)
	if line := readUntil(t, host, "host/clients"); !strings.Contains(line, `"clients":[]`) {
		t.Fatal("the hello's host/clients:", line)
	}
	for range 40 {
		p.s.syncRelays()
	}
	m, err := controllink.PairClient(context.Background(), p.code(false), "window")
	if err != nil {
		t.Fatal(err)
	}
	if line := readUntil(t, host, "host/clients"); !strings.Contains(line, m.Client) {
		t.Fatal("the refreshes told the host an unchanged list:", line)
	}
}

// #1996: hosts on the control plane's own machine that join at once, each with a code of
// its own, are one mac and the rest ids of their own, each kept with its own key, and
// each proves it. None writes over another's record.
func TestHostsJoiningAtOnceFromItsMachineAreOneMac(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	const n = 6
	codes := make([]*controllink.Code, n)
	for i := range codes {
		codes[i] = p.code(true)
	}
	keys := make([][]byte, n)
	members := make([]*controllink.Membership, n)
	errs := make([]error, n)
	start := make(chan struct{})
	var wg sync.WaitGroup
	for i := range n {
		keys[i] = controllink.NewPrivateKey()
		wg.Go(func() {
			<-start
			members[i], errs[i] = controllink.Enroll(context.Background(), t.TempDir(), codes[i], keys[i],
				controllink.MachineHello{Name: new("host " + itoa(i)), MachineID: "MACHINE-1"})
		})
	}
	close(start)
	wg.Wait()
	seen := map[string]bool{}
	macs := 0
	for i := range n {
		if errs[i] != nil {
			t.Fatal(errs[i])
		}
		host := members[i].Host
		if seen[host] {
			t.Fatalf("two hosts enrolled as %s", host)
		}
		seen[host] = true
		if host == "mac" {
			macs++
		}
		public, _ := controllink.PublicKey(keys[i])
		if r := p.s.Records().Host(host); r == nil || !bytes.Equal(r.PublicKey, public) {
			t.Fatalf("%s is not kept with its own key: %+v", host, r)
		}
		key, _ := controllink.HostKey(keys[i], codes[i].ControlKey, host)
		l, _, err := controllink.Join(context.Background(), p.url, "", controllink.Credentials{Identity: "h:" + host, Key: key,
			Kind: "host", ControlKey: codes[i].ControlKey})
		if err != nil {
			t.Fatalf("%s could not prove its key: %v", host, err)
		}
		l.Close()
	}
	if macs != 1 {
		t.Fatalf("%d hosts are mac", macs)
	}
	// A replay of a join that could not be mac is given the id it was given.
	for i := range n {
		again, err := controllink.Enroll(context.Background(), t.TempDir(), codes[i], keys[i],
			controllink.MachineHello{Name: new("host " + itoa(i)), MachineID: "MACHINE-1"})
		if err != nil || again.Host != members[i].Host {
			t.Fatalf("replay of %s: %v %v", members[i].Host, again, err)
		}
	}
}

// #1996: a host proving a key that is not the one it enrolled with is refused, and the
// log says which host and why.
func TestABadProofSaysWhichHostAndWhy(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	code := p.code(true)
	member, err := controllink.Enroll(context.Background(), t.TempDir(), code, controllink.NewPrivateKey(),
		controllink.MachineHello{Name: new("a"), MachineID: "X"})
	if err != nil {
		t.Fatal(err)
	}
	key, _ := controllink.HostKey(controllink.NewPrivateKey(), code.ControlKey, member.Host)
	_, _, err = controllink.Join(context.Background(), p.url, "", controllink.Credentials{Identity: "h:" + member.Host, Key: key,
		Kind: "host", ControlKey: code.ControlKey})
	if r := (*controllink.Refusal)(nil); !errors.As(err, &r) || r.Reason != controllink.BadProof {
		t.Fatalf("%v", err)
	}
	want := "host " + member.Host + " proved a key that is not the one it enrolled with"
	timeout := time.After(10 * time.Second)
	for {
		select {
		case line := <-p.lines:
			if strings.Contains(line, want) && strings.Contains(line, "bad-proof") {
				return
			}
		case <-timeout:
			t.Fatal("the bad proof was not logged with its host and why")
		}
	}
}
