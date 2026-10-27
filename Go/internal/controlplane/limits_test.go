package controlplane

// The limits on paired clients, connections and slow requests (#2150).

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
	"github.com/coder/websocket"
)

func TestABucketRefillsAtItsRate(t *testing.T) {
	t.Parallel()
	var b bucket
	now := time.Unix(1000, 0)
	for i := range 10 {
		if !b.take(now, 1, 2, 10) {
			t.Fatalf("refused at %d of a burst of 10", i)
		}
	}
	if b.take(now, 1, 2, 10) {
		t.Fatal("took an eleventh")
	}
	now = now.Add(time.Second)
	if !b.take(now, 2, 2, 10) || b.take(now, 1, 2, 10) {
		t.Fatal("one second did not give back two")
	}
	now = now.Add(time.Hour)
	if !b.take(now, 10, 2, 10) || b.take(now, 1, 2, 10) {
		t.Fatal("an hour gave back more than the burst")
	}
}

// A client over its rate for a costly method is answered tooManyRequests, and its socket
// stays open: the next cheap call goes.
func TestACostlyMethodOverItsRateIsRefusedAndTheSocketStays(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, s := p.client("Window")
	ctx := context.Background()
	refused := 0
	for range costlyBurst + 5 {
		_, err := s.Call(ctx, "", "reports/usage", map[string]any{})
		if err != nil && strings.Contains(err.Error(), fmt.Sprint(wire.FailureTooManyRequests)) {
			refused++
		}
	}
	if refused < 5 {
		t.Fatalf("%d of %d costly calls refused; want at least 5", refused, costlyBurst+5)
	}
	if _, err := s.Call(ctx, "", "control/status", nil); err != nil {
		t.Fatalf("the socket did not stay: %v", err)
	}
	// Logged once in the window, not once a refusal.
	said := 0
	for {
		select {
		case l := <-p.lines:
			if strings.Contains(l, "over its rate") {
				said++
			}
			continue
		default:
		}
		break
	}
	if said != 1 {
		t.Fatalf("the refusals were logged %d times", said)
	}
}

func TestEveryLineAndByteCounts(t *testing.T) {
	t.Parallel()
	c := newClientRates()
	now := time.Unix(1000, 0)
	c.now = func() time.Time { return now }
	for i := range clientLinesBurst {
		if !c.allow("A", 10, "machines/list") {
			t.Fatalf("refused line %d", i)
		}
	}
	if c.allow("A", 10, "machines/list") {
		t.Fatal("a line past the burst went")
	}
	// A reply to a host takes no line, and another client has its own.
	if !c.allow("A", 10, "") || !c.allow("B", 10, "machines/list") {
		t.Fatal("refused what is not over its rate")
	}
	if !c.allow("C", clientBytesBurst-1, "dropbox/put") || c.allow("C", 2<<20, "") {
		t.Fatal("bytes past the burst went")
	}
}

// The listeners close a slow request, but never a socket in use, however long it lasts.
func TestTimeoutsCloseASlowRequestButNotASocket(t *testing.T) {
	// Not parallel (#2512): it sets the package's HTTP timeouts.
	read, write, idle := httpReadTimeout, httpWriteTimeout, httpIdleTimeout
	httpReadTimeout, httpWriteTimeout, httpIdleTimeout = 300*time.Millisecond, 300*time.Millisecond, 300*time.Millisecond
	t.Cleanup(func() { httpReadTimeout, httpWriteTimeout, httpIdleTimeout = read, write, idle })
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	for _, srv := range p.s.servers {
		if srv.MaxHeaderBytes != httpHeaderMost || srv.ReadTimeout == 0 || srv.WriteTimeout == 0 || srv.IdleTimeout == 0 {
			t.Fatalf("a listener without its limits: %+v", srv)
		}
	}
	_, s := p.client("Window")
	// A body that never comes is closed.
	conn, err := net.Dial("tcp", strings.TrimPrefix(p.url, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	fmt.Fprintf(conn, "POST /v1/join HTTP/1.1\r\nHost: x\r\nContent-Length: 1000\r\n\r\n{")
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	started := time.Now()
	buf := make([]byte, 4096)
	for {
		if _, err := conn.Read(buf); err != nil {
			if ne, ok := err.(net.Error); ok && ne.Timeout() {
				t.Fatal("a slow request was held open")
			}
			break
		}
	}
	if time.Since(started) > 3*time.Second {
		t.Fatalf("a slow request was closed only after %v", time.Since(started))
	}
	// The socket outlives every timeout.
	time.Sleep(time.Second)
	if _, err := s.Call(context.Background(), "", "control/status", nil); err != nil {
		t.Fatalf("a socket in use was closed: %v", err)
	}
}

func TestTheDownloadsHaveARateForEachAddress(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	get := func() int {
		resp, err := http.Get(p.url + "/v1/install.sh")
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	for i := range downloadsBurst {
		if status := get(); status != http.StatusOK {
			t.Fatalf("download %d answered %d", i, status)
		}
	}
	if status := get(); status != http.StatusTooManyRequests {
		t.Fatalf("a download past the rate answered %d", status)
	}
}

// Past the most sockets a copy holds, a new one is refused before it opens; past the most a
// client key holds, its exchange is refused as crowded (#2194), which it tries again later.
func TestSocketsAreCapped(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	m, _ := p.client("Window")
	for range sessionsPerClient - 1 {
		s, err := controllink.DialClient(context.Background(), m)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(s.Close)
	}
	p.waitFor(func() bool { return p.s.router.Crowded(m.Client) }, "the client to hold its most")
	if _, err := controllink.DialClient(context.Background(), m); !refusedAs(err, controllink.Crowded) {
		t.Fatalf("one socket more: %v", err)
	}
	// Eight are open: as many as this copy holds, say.
	p.s.mu.Lock()
	p.s.socketsMost = sessionsPerClient
	p.s.mu.Unlock()
	if status := failProof(t, p.url, "198.51.100.1"); status != http.StatusServiceUnavailable {
		t.Fatalf("a socket past the most answered %d", status)
	}
}

func refusedAs(err error, reason string) bool {
	return err != nil && strings.Contains(err.Error(), reason)
}

// Until a socket proves a key, it reads no message larger than an auth line needs.
func TestAnUnprovenSocketReadsOnlySmallMessages(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	ws, _, err := websocket.Dial(ctx, strings.Replace(p.url, "http", "ws", 1)+"/v1/connect", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	if _, _, err := ws.Read(ctx); err != nil {
		t.Fatal(err)
	}
	ws.Write(ctx, websocket.MessageText, []byte(`{"auth":"`+strings.Repeat("a", unprovenMessageMost)+`"}`))
	_, _, err = ws.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusMessageTooBig {
		t.Fatalf("a large first message was read: %v", err)
	}
}

// When every place to join is taken, the oldest of the address holding the most ends, so
// a few addresses can't keep everyone out; and one person named holds at most ten.
func TestJoinPlacesAreFair(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	ctx := context.Background()
	public, _ := controllink.PublicKey(controllink.NewPrivateKey())
	ask := func(from string, person *string) (*wire.MachineJoinTicket, error) {
		return p.s.joins.ask(ctx, wire.MachineJoinAsk{Name: "Box", Platform: "linux", PublicKey: public, Person: person}, from)
	}
	for i := range joinsOpen {
		if _, err := ask(fmt.Sprintf("198.51.100.%d", i/joinsPerSource), nil); err != nil {
			t.Fatalf("ask %d: %v", i, err)
		}
	}
	if _, err := ask("198.51.100.0", nil); err == nil {
		t.Fatal("a sixth from one address was let in")
	}
	// The same /64 is one address.
	for i := range joinsPerSource {
		if _, err := ask(fmt.Sprintf("2001:db8::%d", i+1), nil); err != nil {
			t.Fatalf("a newcomer was kept out: %v", err)
		}
	}
	if _, err := ask("2001:db8::99", nil); err == nil {
		t.Fatal("a sixth from one /64 was let in")
	}
	// Each newcomer ended one of the busiest address's requests.
	all, err := p.s.joins.all(ctx)
	if err != nil {
		t.Fatal(err)
	}
	ended := map[string]int{}
	for _, r := range all {
		if r.Result == "expired" {
			ended[r.From]++
		}
	}
	if len(ended) != joinsPerSource {
		t.Fatalf("ended %v; want one of each of five busiest addresses", ended)
	}
	// A person named: at most joinsPerPerson, from however many addresses.
	p = startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Window")
	named := p.invite(window, "Sam", wire.UserRoleMember).id
	for i := range joinsPerPerson {
		if _, err := ask(fmt.Sprintf("203.0.113.%d", i), &named); err != nil {
			t.Fatalf("ask %d for a person: %v", i, err)
		}
	}
	if _, err := ask("203.0.113.200", &named); err == nil {
		t.Fatal("an eleventh request for one person was let in")
	}
}

// When every sign-in place is taken, the oldest of the address holding the most is closed
// for a newcomer, and an address with its five still gets no sixth.
func TestSignInPlacesAreFair(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	si := p.s.signIns
	conns := make(chan *websocket.Conn, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		conns <- ws
		<-r.Context().Done()
	}))
	t.Cleanup(srv.Close)
	open := func(from string) *Conn {
		ws, _, err := websocket.Dial(context.Background(), strings.Replace(srv.URL, "http", "ws", 1), nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ws.CloseNow() })
		c := newConn(<-conns, from+":1")
		go si.pairing(c, "S", nil, nil)
		return c
	}
	held := func() int {
		si.mu.Lock()
		defer si.mu.Unlock()
		n := 0
		for _, list := range si.open {
			n += len(list)
		}
		return n
	}
	var oldest *Conn
	for i := range signInsOpen {
		c := open(fmt.Sprintf("198.51.100.%d", i/signInsPerSource))
		if oldest == nil {
			oldest = c
		}
		p.waitFor(func() bool { return held() == i+1 }, "a sign-in to hold its place")
	}
	open("203.0.113.1")
	select {
	case <-oldest.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("the oldest sign-in of the busiest address was not closed")
	}
	p.waitFor(func() bool {
		si.mu.Lock()
		defer si.mu.Unlock()
		return len(si.open["203.0.113.1"]) == 1
	}, "the newcomer to hold a place")
	sixth := open("198.51.100.1")
	select {
	case <-sixth.Done():
	case <-time.After(5 * time.Second):
		t.Fatal("a sixth sign-in from one address was let in")
	}
}
