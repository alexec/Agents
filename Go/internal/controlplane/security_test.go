package controlplane

// The security pass for a public machine (#1457): one test for each finding in
// specs/058-control-plane/public-security.md that the Go code fixes.

import (
	"context"
	"errors"
	"net/http"
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/coder/websocket"
)

// countingStore counts the lists made of a store, and can fail every read of a code.
type countingStore struct {
	store.Store
	lists     atomic.Int64
	codesFail atomic.Bool
}

func (c *countingStore) List(ctx context.Context, prefix string) ([]store.Key, error) {
	c.lists.Add(1)
	return c.Store.List(ctx, prefix)
}

func (c *countingStore) Get(ctx context.Context, key string) (*store.Object, error) {
	if c.codesFail.Load() && strings.Contains(key, "codes/") {
		return nil, errors.New("GET " + key + ": the bucket is down")
	}
	return c.Store.Get(ctx, key)
}

// P1: a crowd of made-up client and host ids costs one read of the store, not one each,
// and another crowd straight after costs none.
func TestUnknownIDsReadTheStoreOnce(t *testing.T) {
	t.Parallel()
	st := &countingStore{Store: store.NewMemory()}
	p := startPlane(t, st, controllink.NewPrivateKey())
	// Past the window of any read Start made.
	time.Sleep(readAgainEvery)
	crowd := func() {
		var wg sync.WaitGroup
		for i := range 200 {
			wg.Add(1)
			go func() {
				defer wg.Done()
				id := controllink.Identity{Kind: 'c', ID: strings.ToUpper(records.NewUUID())}
				if i%2 == 1 {
					id = controllink.Identity{Kind: 'h', ID: records.NewHostID()}
				}
				if _, _, _, err := p.s.key(id); err == nil {
					t.Error("a made-up id was given a key")
				}
			}()
		}
		wg.Wait()
	}
	before := st.lists.Load()
	crowd()
	// One read lists the clients, the hosts, the people (#994), the groups (#1761) and the
	// projects (#2317).
	if got := st.lists.Load() - before; got > 5 {
		t.Fatalf("200 made-up ids made %d lists; one read is 5", got)
	}
	before = st.lists.Load()
	crowd()
	if got := st.lists.Load() - before; got != 0 {
		t.Fatalf("a crowd within %v of a read made %d lists", readAgainEvery, got)
	}
}

// P1: a member paired at another copy is still admitted, once the window has passed.
func TestAMemberPairedElsewhereIsReadAgain(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	time.Sleep(readAgainEvery)
	// Paired behind this copy's back, as another copy would.
	other := records.New(st)
	id := strings.ToUpper(records.NewUUID())
	public, _ := controllink.PublicKey(controllink.NewPrivateKey())
	if err := other.SaveClient(context.Background(), records.ClientRecord{ID: id, Name: "Phone", Kind: records.KindIPhone,
		PublicKey: public, Paired: records.Now()}); err != nil {
		t.Fatal(err)
	}
	if _, c, _, err := p.s.key(controllink.Identity{Kind: 'c', ID: id}); err != nil || c == nil {
		t.Fatalf("%v", err)
	}
}

// P3: twenty failed proofs in a minute, then a minute of refusals; the minute passes.
func TestSourcesRefuseAfterTwentyFailedProofs(t *testing.T) {
	t.Parallel()
	now := time.Unix(1_000_000, 0)
	table := newSources(nil, func(string) {})
	table.now = func() time.Time { return now }
	for range failedProofsAllowed {
		proved, ok := table.enter("203.0.113.9")
		if !ok {
			t.Fatal("refused before twenty")
		}
		proved(true)
	}
	if _, ok := table.enter("203.0.113.9"); ok {
		t.Fatal("not refused after twenty")
	}
	if _, ok := table.enter("203.0.113.10"); !ok {
		t.Fatal("another address was refused")
	}
	now = now.Add(refusedFor)
	if _, ok := table.enter("203.0.113.9"); !ok {
		t.Fatal("still refused after a minute")
	}
	// Failures spread over more than a minute never add up to a refusal.
	slow := newSources(nil, func(string) {})
	slow.now = func() time.Time { return now }
	for range 3 * failedProofsAllowed {
		proved, ok := slow.enter("198.51.100.1")
		if !ok {
			t.Fatal("refused for slow failures")
		}
		proved(true)
		now = now.Add(4 * time.Second)
	}
}

// P3: fifty sockets waiting to prove a key from one address, and the fifty-first is
// refused until one has.
func TestSourcesCapSocketsWaitingForAuth(t *testing.T) {
	t.Parallel()
	table := newSources(nil, func(string) {})
	var waiting []func(bool)
	for range waitingAllowed {
		proved, ok := table.enter("2001:db8::1")
		if !ok {
			t.Fatal("refused before fifty")
		}
		waiting = append(waiting, proved)
	}
	// The same /64 is the same machine.
	if _, ok := table.enter("2001:db8::2"); ok {
		t.Fatal("not refused at fifty")
	}
	waiting[0](false)
	waiting[0](false) // told twice, counted once
	if _, ok := table.enter("2001:db8::3"); !ok {
		t.Fatal("refused once one had proved itself")
	}
	if _, ok := table.enter("2001:db8::4"); ok {
		t.Fatal("a second leave was counted")
	}
}

// P3: the table holds a bounded number of addresses, letting idle ones go.
func TestSourcesHoldABoundedTable(t *testing.T) {
	t.Parallel()
	table := newSources(nil, func(string) {})
	for i := range 3 * sourcesHeld {
		addr := netip.AddrFrom4([4]byte{10, byte(i >> 16), byte(i >> 8), byte(i)}).String()
		proved, ok := table.enter(addr)
		if !ok {
			t.Fatal("refused")
		}
		proved(false)
	}
	if len(table.table) > sourcesHeld {
		t.Fatalf("%d addresses held", len(table.table))
	}
}

// P3: X-Forwarded-For says where a socket came from only when the proxy wrote it.
func TestForwardedForIsTrustedOnlyFromTheProxy(t *testing.T) {
	t.Parallel()
	trusted, err := ParseTrustedProxies("172.30.61.250, 10.0.0.0/8")
	if err != nil {
		t.Fatal(err)
	}
	table := newSources(trusted, func(string) {})
	request := func(peer string, forwarded ...string) *http.Request {
		r := &http.Request{RemoteAddr: peer, Header: http.Header{}}
		for _, f := range forwarded {
			r.Header.Add("X-Forwarded-For", f)
		}
		return r
	}
	for _, c := range []struct {
		r    *http.Request
		want string
	}{
		{request("172.30.61.250:4000", "203.0.113.9"), "203.0.113.9"},
		// The last entry is the one the proxy added.
		{request("172.30.61.250:4000", "1.1.1.1, 203.0.113.9"), "203.0.113.9"},
		{request("172.30.61.250:4000", "1.1.1.1", "203.0.113.9"), "203.0.113.9"},
		{request("10.1.2.3:4000", "2001:db8::1"), "2001:db8::1"},
		// A stranger says it is someone else: it is itself.
		{request("198.51.100.7:4000", "203.0.113.9"), "198.51.100.7"},
		{request("172.30.61.251:4000", "203.0.113.9"), "172.30.61.251"},
		// The proxy with nothing to say, or nonsense.
		{request("172.30.61.250:4000"), "172.30.61.250"},
		{request("172.30.61.250:4000", "not an address"), "172.30.61.250"},
		{request("[::ffff:172.30.61.250]:4000", "203.0.113.9"), "203.0.113.9"},
	} {
		if got := table.of(c.r); got != c.want {
			t.Errorf("%s %v: %s, want %s", c.r.RemoteAddr, c.r.Header.Values("X-Forwarded-For"), got, c.want)
		}
	}
	if _, err := ParseTrustedProxies("caddy"); err == nil {
		t.Fatal("a name was taken for an address")
	}
}

// failProof opens a socket as from, says nonsense instead of proving a key, and gives the
// status the upgrade was answered with.
func failProof(t *testing.T, url, from string) int {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	header := http.Header{}
	header.Set("X-Forwarded-For", from)
	ws, resp, err := websocket.Dial(ctx, strings.Replace(url, "http", "ws", 1)+"/v1/connect", &websocket.DialOptions{HTTPHeader: header})
	if err != nil {
		if resp != nil {
			return resp.StatusCode
		}
		t.Fatal(err)
	}
	defer ws.CloseNow()
	if _, _, err := ws.Read(ctx); err != nil {
		t.Fatal(err)
	}
	ws.Write(ctx, websocket.MessageText, []byte(`{"auth":"nonsense"}`))
	_, line, _ := ws.Read(ctx)
	if !strings.Contains(string(line), controllink.BadMessage) {
		t.Fatalf("%s", line)
	}
	return http.StatusSwitchingProtocols
}

// P3 end to end: behind a trusted proxy, a stranger that fails twenty proofs is refused
// before its socket opens, and a member from another address is not.
func TestAStrangerIsRefusedAfterTwentyFailedProofs(t *testing.T) {
	t.Parallel()
	port := freePort(t)
	url := "http://127.0.0.1:" + itoa(port)
	s, err := New(Config{Store: store.NewMemory(), PrivateKey: controllink.NewPrivateKey(), URL: url, Bind: "127.0.0.1",
		Port: port, Name: "Test plane", TrustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8")}})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.Start(context.Background()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(s.Stop)
	p := &plane{t: t, s: s, url: url}
	for range failedProofsAllowed {
		if status := failProof(t, url, "203.0.113.9"); status != http.StatusSwitchingProtocols {
			t.Fatalf("refused early: %d", status)
		}
	}
	// The last refusal is counted once its socket is let go.
	p.waitFor(func() bool {
		s.sources.mu.Lock()
		defer s.sources.mu.Unlock()
		source := s.sources.table[keyOf("203.0.113.9")]
		return source != nil && time.Now().Before(source.refusing)
	}, "the stranger refused")
	if status := failProof(t, url, "203.0.113.9"); status != http.StatusTooManyRequests {
		t.Fatalf("answered %d", status)
	}
	// A member pairs and connects from its own address.
	p.client("Window")
}

// P4: a copy that was forwarding when it stopped comes back frozen and forwarding, to the
// same list, until the same time; --no-forwarding serves again.
func TestAForwardingCopyForwardsAfterARestart(t *testing.T) {
	t.Parallel()
	key := controllink.NewPrivateKey()
	st := store.NewMemory()
	port := freePort(t)
	url := "http://127.0.0.1:" + itoa(port)
	start := func(noForwarding bool) *Service {
		s, err := New(Config{Store: st, PrivateKey: key, URL: url, Bind: "127.0.0.1", Port: port, Name: "Old",
			NoForwarding: noForwarding})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.Start(context.Background()); err != nil {
			t.Fatal(err)
		}
		return s
	}
	old := start(false)
	p := &plane{t: t, s: old, url: url, store: st, private: key}
	member, _ := p.client("Window")
	d := drive(t, url, key)
	d.must("handover/freeze", nil)
	d.must("handover/forward", map[string]any{"endpoints": []records.Endpoint{{URL: "https://new.example.com"}}})
	d.lines.Close()
	// The mark keeps milliseconds.
	until := old.phase.forwardingUntil().Truncate(time.Millisecond)
	old.Stop()

	again := start(false)
	if again.phase.now() != phaseForwarding || !again.phase.forwardingUntil().Equal(until) {
		t.Fatalf("%s until %v", again.phase.now(), again.phase.forwardingUntil())
	}
	// A member that comes back is given the new list, as before the restart.
	clientKey, _ := controllink.ClientKey(member.Private, member.ControlKey, member.Client)
	epoch := 0
	lines, ok, err := controllink.Join(context.Background(), url, "", controllink.Credentials{Identity: "c:" + member.Client,
		Key: clientKey, Kind: "mac", ControlKey: member.ControlKey, Epoch: &epoch})
	if err != nil {
		t.Fatal(err)
	}
	lines.Close()
	if len(ok.Endpoints) != 1 || ok.Endpoints[0].URL != "https://new.example.com" {
		t.Fatalf("%+v", ok.Endpoints)
	}
	// Frozen: nothing it holds changes.
	again.methods.mu.Lock()
	frozen := again.methods.frozen
	again.methods.mu.Unlock()
	if !frozen {
		t.Fatal("not frozen after the restart")
	}
	again.Stop()

	served := start(true)
	t.Cleanup(served.Stop)
	if served.phase.now() != phaseServing {
		t.Fatalf("%s with --no-forwarding", served.phase.now())
	}
}

// Logs: no code, no code's id, no MAC and no key reaches a log line, whether the code
// pairs, fails, or the store can't read it.
func TestNoSecretReachesTheLog(t *testing.T) {
	t.Parallel()
	private := controllink.NewPrivateKey()
	st := &countingStore{Store: store.NewMemory()}
	p := startPlane(t, st, private)
	var secrets []string
	shown, err := p.s.Codes().Issue(context.Background(), false, false, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	code, _ := controllink.ParseCode(shown.Text)
	secrets = append(secrets, shown.Text, controllink.B64URL(code.Secret), controllink.B64URL(code.Secret[:16]),
		controllink.B64URL(private))
	member, err := controllink.PairClient(context.Background(), code, "Window")
	if err != nil {
		t.Fatal(err)
	}
	// Spent: a second pairing fails, and says so.
	if _, err := controllink.PairClient(context.Background(), code, "Again"); err == nil {
		t.Fatal("a code was used twice")
	}
	clientKey, _ := controllink.ClientKey(member.Private, member.ControlKey, member.Client)
	lines, ok, err := controllink.Join(context.Background(), p.url, "", controllink.Credentials{Identity: "c:" + member.Client,
		Key: clientKey, Kind: "mac", ControlKey: member.ControlKey})
	if err != nil {
		t.Fatal(err)
	}
	lines.Close()
	secrets = append(secrets, ok.Mac, controllink.B64URL(clientKey), controllink.B64URL(member.Private))
	// A code the store can't read: its error names the code's key.
	other := p.code(false)
	secrets = append(secrets, other.Text(), controllink.B64URL(other.Secret), controllink.B64URL(other.Secret[:16]))
	st.codesFail.Store(true)
	if _, err := controllink.PairClient(context.Background(), other, "Phone"); err == nil {
		t.Fatal("paired with the store down")
	}
	st.codesFail.Store(false)
	// A failed proof.
	failProof(t, p.url, "")
	time.Sleep(300 * time.Millisecond)

	var said []string
	for {
		select {
		case line := <-p.lines:
			said = append(said, line)
			continue
		default:
		}
		break
	}
	if !strings.Contains(strings.Join(said, "\n"), "could not read a code") {
		t.Fatalf("the store's failure was not logged: %q", said)
	}
	for _, line := range said {
		for _, secret := range secrets {
			if secret != "" && strings.Contains(line, secret) {
				t.Errorf("a secret in the log: %q", line)
			}
		}
	}
}

// P3 in Caddy: every site in the Caddyfiles caps its request bodies.
func TestEveryPublicRouteCapsItsBody(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"Caddyfile.public", "Caddyfile"} {
		data, err := os.ReadFile(filepath.Join("..", "..", "..", "deploy", name))
		if err != nil {
			t.Fatal(err)
		}
		for _, site := range caddySites(string(data)) {
			if !strings.Contains(site.body, "request_body") || !strings.Contains(site.body, "max_size") {
				t.Errorf("%s: %s has no request_body max_size", name, site.address)
			}
		}
	}
}

type caddySite struct{ address, body string }

// caddySites is every top-level block of a Caddyfile but the global options (the one with
// no address).
func caddySites(text string) []caddySite {
	var sites []caddySite
	depth := 0
	var current *caddySite
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "#") {
			continue
		}
		if depth == 0 && strings.HasSuffix(trimmed, "{") {
			address := strings.TrimSpace(strings.TrimSuffix(trimmed, "{"))
			if address != "" {
				current = &caddySite{address: address}
			}
		} else if current != nil {
			current.body += line + "\n"
		}
		depth += strings.Count(trimmed, "{") - strings.Count(trimmed, "}")
		if depth == 0 && current != nil {
			sites = append(sites, *current)
			current = nil
		}
	}
	return sites
}
