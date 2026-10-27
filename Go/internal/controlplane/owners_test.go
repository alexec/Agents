package controlplane

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
)

// ownersStandIn says who owns each machine and counts how often it is asked, and whether
// any ask came while the router held its lock.
type ownersStandIn struct {
	r         *Router
	owner     map[string]string
	asked     atomic.Int64
	underLock atomic.Bool
}

func (o *ownersStandIn) PersonOf(string) string { return "" }
func (o *ownersStandIn) OwnerOf(host string) string {
	o.asked.Add(1)
	if o.r.mu.TryLock() {
		o.r.mu.Unlock()
	} else {
		o.underLock.Store(true)
	}
	return o.owner[host]
}

// #2059: the 15 s refresh holds 600 sessions to who owns 400 machines. Each owner is read
// once a machine, outside the router's lock, not once a session and machine under it; and
// a machine that changes hands moves only its own channels.
func TestHoldingToOwnersReadsEachOwnerOnceOutsideTheLock(t *testing.T) {
	t.Parallel()
	const machines, sessions, people = 400, 600, 10
	r := NewRouter(nil, nil)
	o := &ownersStandIn{r: r, owner: map[string]string{}}
	for i := range machines {
		host := "MACHINE-" + itoa(i)
		o.owner[host] = "person-" + itoa(i%people)
		up := &uplinkStandIn{closed: make(chan struct{})}
		t.Cleanup(up.Close)
		r.AttachHost(host, up)
	}
	r.mu.Lock()
	for i := range sessions {
		id := "session-" + itoa(i)
		r.clients[id] = &clientSession{caller: Caller{Session: id, Client: id, Person: "person-" + itoa(i%people)},
			channels: map[string]int{}, inFlight: map[string]map[string]bool{}, copying: map[string]map[string]string{}}
	}
	r.mu.Unlock()

	r.SetOwnership(o)
	if n := o.asked.Load(); n != machines {
		t.Fatalf("asked %d times for %d machines", n, machines)
	}
	if o.underLock.Load() {
		t.Fatal("an owner was read under the router's lock")
	}
	reaches := func(session, host string) bool {
		r.mu.Lock()
		defer r.mu.Unlock()
		_, has := r.clients[session].channels[host]
		return has
	}
	for i := range sessions {
		r.mu.Lock()
		n := len(r.clients["session-"+itoa(i)].channels)
		r.mu.Unlock()
		if n != machines/people {
			t.Fatalf("session %d holds %d channels, its person owns %d machines", i, n, machines/people)
		}
	}

	o.owner["MACHINE-0"] = "person-1"
	o.asked.Store(0)
	r.HoldToOwners()
	if n := o.asked.Load(); n != machines || o.underLock.Load() {
		t.Fatalf("asked %d times, under the lock %v", n, o.underLock.Load())
	}
	if reaches("session-0", "MACHINE-0") || !reaches("session-1", "MACHINE-0") || !reaches("session-0", "MACHINE-10") {
		t.Fatal("MACHINE-0's channels did not move to its new owner alone")
	}
	if got := r.Channels("MACHINE-0"); got != sessions/people {
		t.Fatalf("MACHINE-0 has %d channels", got)
	}
}

// #1970: a page its host answers itself is the host's person's alone. Once the machine
// changes hands, the page's session ends, so the host answers it no more; and a page
// noted after the machine changed hands ends at once.
func TestACarriedPageEndsWhenItsMachineChangesHands(t *testing.T) {
	t.Parallel()
	r := NewRouter(nil, nil)
	o := &ownersStandIn{r: r, owner: map[string]string{"MACHINE": "person-a"}}
	up := &uplinkStandIn{closed: make(chan struct{})}
	t.Cleanup(up.Close)
	r.AttachHost("MACHINE", up)
	r.SetOwnership(o)
	conns := make(chan *websocket.Conn, 2)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		ws, err := websocket.Accept(w, req, nil)
		if err != nil {
			return
		}
		conns <- ws
		<-req.Context().Done()
	}))
	t.Cleanup(srv.Close)
	page := func(id, person string) *Conn {
		ws, _, err := websocket.Dial(context.Background(), strings.Replace(srv.URL, "http", "ws", 1), nil)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { ws.CloseNow() })
		c := newConn(<-conns, "127.0.0.1:1")
		r.mu.Lock()
		r.clients[id] = &clientSession{caller: Caller{Session: id, Client: id, Person: person}, conn: c,
			channels: map[string]int{}, inFlight: map[string]map[string]bool{}, copying: map[string]map[string]string{}}
		r.mu.Unlock()
		return c
	}
	ended := func(c *Conn) bool {
		select {
		case <-c.Done():
			return true
		case <-time.After(2 * time.Second):
			return false
		}
	}

	if !r.ServesItself("person-a", "MACHINE") || r.ServesItself("person-b", "MACHINE") || r.ServesItself("person-a", "OTHER") {
		t.Fatal("a machine serves a page that is not its person's")
	}
	mine := page("session-a", "person-a")
	r.NoteCarried("session-a", "MACHINE")
	r.HoldToOwners()
	select {
	case <-mine.Done():
		t.Fatal("the owner's page ended while the machine was still theirs")
	default:
	}
	o.owner["MACHINE"] = "person-b"
	r.HoldToOwners()
	if !ended(mine) {
		t.Fatal("the page went on after its machine changed hands")
	}
	late := page("session-late", "person-a")
	r.NoteCarried("session-late", "MACHINE")
	if !ended(late) {
		t.Fatal("a page noted after its machine changed hands went on")
	}
}
