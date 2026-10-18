package controllink

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Conn is one channel as a daemon client connection: lines in, lines out.
type Conn interface {
	Write(line string) error
	In() <-chan string
	Close()
	Device() string
}

// Accept is handed every channel the control plane opens; it serves it until In closes.
type Accept func(Conn)

// Uplink dials the control plane as this host and keeps the socket up (ControlUplink.swift).
type Uplink struct {
	Root    string
	Member  *Membership
	Private []byte
	Hello   HostHello
	Accept  Accept

	mu       sync.Mutex
	out      *sender
	channels map[int]*channel
	nextID   atomic.Int64
	OnChange func(connected bool, problem string)
	tunnels  map[string]chan *channel
	asks     map[int64]chan askReply // Ask's requests on channel 0, by id, until answered
	// Lend is where this host's relay for a runtime listens on loopback, for a tunnel the
	// control plane opens to it (the lending Mac's end, T091); 0 when it lends none.
	Lend func(runtime string) int
	// Told is handed what the control plane tells this host on channel 0, a method and its
	// params, such as host/clients (#1118); nil hears none of it.
	Told func(method string, params json.RawMessage)
	// pingEvery is how often a quiet link is pinged, and how long its pong may take;
	// upPing when 0.
	pingEvery time.Duration
}

// The control plane's socket is written by a goroutine of its own, through a bounded queue,
// as daemon.sock's clients are (#1399), so a control plane that stops reading (a stalled
// TLS link, a half-open TCP one after sleep) never holds Broadcast, a channel's writer or
// u.mu (#1403): its queue stays full for upQueueWait, or a write takes longer than Lines'
// 10 s, and the socket is dropped. Run dials again. A ping finds a link gone quiet with
// nothing to write.
const (
	upQueue     = 1024
	upQueueWait = 2 * time.Second
	upPing      = 20 * time.Second
)

type sender struct {
	l    *Lines
	out  chan string
	done chan struct{}
	once sync.Once
}

func newSender(l *Lines, ping time.Duration) *sender {
	s := &sender{l: l, out: make(chan string, upQueue), done: make(chan struct{})}
	safe.Go("uplink write", s.writeAll)
	safe.Go("uplink ping", func() { s.ping(ping) })
	return s
}

// send queues a line; it never waits for the control plane.
func (s *sender) send(line string) error {
	select {
	case <-s.done:
		return errOffline
	default:
	}
	select {
	case s.out <- line:
		return nil
	case <-s.done:
		return errOffline
	default:
	}
	// Full: a control plane behind in a burst gets a moment; one that reads nothing is dropped.
	wait := time.NewTimer(upQueueWait)
	defer wait.Stop()
	select {
	case s.out <- line:
		return nil
	case <-s.done:
		return errOffline
	case <-wait.C:
		log.Printf("uplink: the control plane read none of the last %d lines in %s; dropped", upQueue, upQueueWait)
		s.drop()
		return errOffline
	}
}

func (s *sender) writeAll() {
	for {
		select {
		case <-s.done:
			return
		case line := <-s.out:
			if err := s.l.Write(context.Background(), line); err != nil {
				log.Printf("uplink: a write to the control plane failed: %v; dropped", err)
				s.drop()
				return
			}
		}
	}
}

// ping pings the control plane every interval; with no pong within as long again, the link goes.
func (s *sender) ping(every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-s.done:
			return
		case <-t.C:
			ctx, cancel := context.WithTimeout(context.Background(), every)
			err := s.l.ws.Ping(ctx)
			cancel()
			if err != nil {
				select {
				case <-s.done:
				default:
					log.Printf("uplink: the control plane did not answer a ping in %s; dropped", every)
					s.drop()
				}
				return
			}
		}
	}
}

// drop ends the socket at once, without the closing handshake a stalled control plane
// would hold up; Run's read then fails, and it dials again.
func (s *sender) drop() {
	s.once.Do(func() {
		close(s.done)
		_ = s.l.ws.CloseNow()
	})
}

func (u *Uplink) Run(ctx context.Context) {
	wait := time.Second
	for ctx.Err() == nil {
		key, err := HostKey(u.Private, u.Member.ControlKey, u.Member.Host)
		if err != nil {
			log.Printf("uplink: %v", err)
			return
		}
		epoch := 0
		l, _, err := Join(ctx, u.Member.URL, u.Member.Pin, Credentials{
			Identity: "h:" + u.Member.Host, Key: key, Kind: "host", ControlKey: u.Member.ControlKey, Epoch: &epoch,
		})
		if err != nil {
			log.Printf("uplink: could not reach the control plane: %v", err)
			if u.OnChange != nil {
				u.OnChange(false, err.Error())
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(wait):
			}
			wait = min(wait*2, 30*time.Second)
			continue
		}
		wait = time.Second
		ping := u.pingEvery
		if ping <= 0 {
			ping = upPing
		}
		out := newSender(l, ping)
		u.mu.Lock()
		u.out = out
		u.channels = map[int]*channel{}
		u.mu.Unlock()
		hello := u.Hello
		hello.Host = new(wire.HostID(u.Member.Host))
		u.Tell("host/hello", hello)
		log.Printf("uplink: connected to the control plane as %s", u.Member.Host)
		if u.OnChange != nil {
			u.OnChange(true, "")
		}
		for {
			line, err := l.Read(ctx)
			if err != nil {
				break
			}
			u.receive(line)
		}
		out.drop()
		u.mu.Lock()
		open := u.channels
		u.channels = nil
		u.out = nil
		u.mu.Unlock()
		for _, c := range open {
			c.end(false)
		}
		log.Printf("uplink: the control plane went; %d channels closed", len(open))
		if u.OnChange != nil {
			u.OnChange(false, "")
		}
	}
}

func (u *Uplink) write(line string) error {
	u.mu.Lock()
	out := u.out
	u.mu.Unlock()
	if out == nil {
		return errOffline
	}
	return out.send(line)
}

type offline struct{}

func (offline) Error() string { return "this host is not connected to its control plane" }

var errOffline = offline{}

// Tell sends a request on channel 0 whose answer nothing waits for (host/hello).
func (u *Uplink) Tell(method string, params any) {
	id := u.nextID.Add(1)
	p, _ := json.Marshal(params)
	m, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p)})
	_ = u.write(channelLine(0, string(m)))
}

// AskError is the control plane's error answer to Ask, as it said it.
type AskError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *AskError) Error() string { return e.Message }

type askReply struct {
	result json.RawMessage
	err    *AskError
}

// askWait is how long Ask waits for an answer: a provider may take a while to make a
// workspace, never this long.
const askWait = 2 * time.Minute

// Ask sends a request on channel 0 and waits for its answer (host/workspaces, #1444): the
// result, an *AskError when the control plane refused it, or an error when it is not
// connected or did not answer.
func (u *Uplink) Ask(ctx context.Context, method string, params any) (json.RawMessage, error) {
	id := u.nextID.Add(1)
	p, err := json.Marshal(params)
	if err != nil {
		return nil, err
	}
	m, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": id, "method": method, "params": json.RawMessage(p)})
	wait := make(chan askReply, 1)
	u.mu.Lock()
	if u.asks == nil {
		u.asks = map[int64]chan askReply{}
	}
	u.asks[id] = wait
	u.mu.Unlock()
	defer func() { u.mu.Lock(); delete(u.asks, id); u.mu.Unlock() }()
	if err := u.write(channelLine(0, string(m))); err != nil {
		return nil, err
	}
	select {
	case r := <-wait:
		if r.err != nil {
			return nil, r.err
		}
		return r.result, nil
	case <-time.After(askWait):
		return nil, errors.New("the control plane did not answer")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// answered hands a reply on channel 0 to the Ask waiting for it; false when it is not one.
func (u *Uplink) answered(message string) bool {
	var r struct {
		ID     *int64          `json:"id"`
		Method string          `json:"method"`
		Result json.RawMessage `json:"result"`
		Error  *AskError       `json:"error"`
	}
	if json.Unmarshal([]byte(message), &r) != nil || r.ID == nil || r.Method != "" {
		return false
	}
	u.mu.Lock()
	wait := u.asks[*r.ID]
	delete(u.asks, *r.ID)
	u.mu.Unlock()
	if wait == nil {
		return false
	}
	wait <- askReply{result: r.Result, err: r.Error}
	return true
}

func channelLine(n int, message string) string {
	return `{"c":` + strconv.Itoa(n) + `,"m":` + message + `}`
}

func (u *Uplink) receive(line string) {
	// The fast path: {"c":N,"m":…} written by the Swift side with m last.
	if strings.HasPrefix(line, `{"c":`) {
		rest := line[5:]
		i := 0
		for i < len(rest) && rest[i] >= '0' && rest[i] <= '9' {
			i++
		}
		if n, err := strconv.Atoi(rest[:i]); err == nil && strings.HasPrefix(rest[i:], `,"m":`) && strings.HasSuffix(rest, "}") {
			u.message(n, rest[i+5:len(rest)-1])
			return
		}
	}
	var frame struct {
		C     *int              `json:"c"`
		M     json.RawMessage   `json:"m"`
		Open  *wire.ChannelOpen `json:"open"`
		Close bool              `json:"close"`
	}
	if err := json.Unmarshal([]byte(line), &frame); err != nil || frame.C == nil {
		return
	}
	switch {
	case frame.M != nil:
		u.message(*frame.C, string(frame.M))
	case frame.Open != nil:
		if *frame.C <= 0 {
			return
		}
		c := &channel{number: *frame.C, up: u, in: make(chan string, 1024)}
		if frame.Open.Tunnel != nil {
			ref := ""
			if frame.Open.TunnelRef != nil {
				ref = *frame.Open.TunnelRef
			}
			u.mu.Lock()
			wait := u.tunnels[ref]
			delete(u.tunnels, ref)
			port := 0
			if wait == nil && u.Lend != nil {
				port = u.Lend(*frame.Open.Tunnel)
			}
			if (wait != nil || port > 0) && u.channels != nil {
				u.channels[c.number] = c
			}
			u.mu.Unlock()
			if wait != nil {
				wait <- c
				return
			}
			if port <= 0 {
				log.Printf("uplink: a tunnel for %s was opened that this host did not ask for; it lends no sign-in", *frame.Open.Tunnel)
				_ = u.write(`{"c":` + strconv.Itoa(*frame.C) + `,"close":true}`)
				return
			}
			// The lender's end: the tunnel to its relay on loopback.
			runtime := *frame.Open.Tunnel
			safe.Go("relay lend", func() {
				conn, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(port), 10*time.Second)
				if err != nil {
					log.Printf("relay: %v", err)
					c.end(true)
					return
				}
				log.Printf("relay: a tunnel for %s opened", runtime)
				Pipe(conn, c)
			})
			return
		}
		if frame.Open.Device != nil {
			c.device = string(*frame.Open.Device)
		}
		c.fanOut = frame.Open.FanOut != nil && *frame.Open.FanOut
		u.mu.Lock()
		old := u.channels[c.number]
		if u.channels != nil {
			u.channels[c.number] = c
		}
		u.mu.Unlock()
		if old != nil {
			old.end(false)
		}
		safe.Go("channel", func() { u.Accept(c) })
	case frame.Close:
		u.mu.Lock()
		c := u.channels[*frame.C]
		delete(u.channels, *frame.C)
		u.mu.Unlock()
		if c != nil {
			c.end(false)
		}
	}
}

func (u *Uplink) message(n int, message string) {
	if n == 0 {
		// A reply to an Ask; projects/detect from an older control plane is said done.
		// Replies to Tell are not waited on.
		if u.answered(message) {
			return
		}
		if strings.Contains(message, `"projects/detect"`) {
			u.Tell("projects/detected", map[string]int{"added": 0})
			return
		}
		var told struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if u.Told != nil && json.Unmarshal([]byte(message), &told) == nil && told.ID == nil && told.Method != "" {
			u.Told(told.Method, told.Params)
		}
		return
	}
	u.mu.Lock()
	c := u.channels[n]
	u.mu.Unlock()
	if c != nil {
		c.yield(message)
	}
}

type channel struct {
	number int
	up     *Uplink
	in     chan string
	device string
	// fanOut is whether the control plane reads fan-out frames on this channel's uplink.
	fanOut bool
	once   sync.Once
	closed atomic.Bool
}

// FanOuter is a connection a broadcast can reach in one frame with the others on its
// uplink (#167).
type FanOuter interface {
	FanOutRoute() (*Uplink, int, bool)
}

// FanOutRoute is the channel's uplink and number, when its control plane reads fan-out
// frames and it is still open.
func (c *channel) FanOutRoute() (*Uplink, int, bool) {
	return c.up, c.number, c.fanOut && !c.closed.Load()
}

// WriteFanOut writes one notification for every channel named (ControlWire.fanOut).
func (u *Uplink) WriteFanOut(channels []int, line string) error {
	ns := make([]string, len(channels))
	for i, n := range channels {
		ns[i] = strconv.Itoa(n)
	}
	return u.write(`{"f":[` + strings.Join(ns, ",") + `],"m":` + line + `}`)
}

func (c *channel) Write(line string) error {
	if c.closed.Load() {
		return errOffline
	}
	return c.up.write(channelLine(c.number, line))
}

func (c *channel) In() <-chan string { return c.in }
func (c *channel) Device() string    { return c.device }

func (c *channel) yield(line string) {
	if c.closed.Load() {
		return
	}
	defer func() { _ = recover() }() // closed under us: the line goes nowhere
	select {
	case c.in <- line:
	default:
		log.Printf("uplink: closing channel %d, too much unread", c.number)
		c.end(true)
	}
}

func (c *channel) Close() { c.end(true) }

func (c *channel) end(tell bool) {
	c.once.Do(func() {
		c.closed.Store(true)
		close(c.in)
		if tell {
			_ = c.up.write(`{"c":` + strconv.Itoa(c.number) + `,"close":true}`)
		}
		c.up.mu.Lock()
		if c.up.channels != nil && c.up.channels[c.number] == c {
			delete(c.up.channels, c.number)
		}
		c.up.mu.Unlock()
	})
}

// OpenTunnel asks the control plane for a tunnel to the host that lends runtime's sign-in
// (T091): tunnel/open on channel 0, then an open frame with the same ref. Its lines are
// bytes, base64 in a JSON string.
func (u *Uplink) OpenTunnel(ctx context.Context, runtime string) (Conn, error) {
	ref := strings.ToLower(newRef())
	wait := make(chan *channel, 1)
	u.mu.Lock()
	if u.tunnels == nil {
		u.tunnels = map[string]chan *channel{}
	}
	u.tunnels[ref] = wait
	u.mu.Unlock()
	defer func() { u.mu.Lock(); delete(u.tunnels, ref); u.mu.Unlock() }()
	u.Tell("tunnel/open", map[string]string{"runtime": runtime, "ref": ref})
	select {
	case c := <-wait:
		return c, nil
	case <-time.After(15 * time.Second):
		return nil, errors.New("the control plane did not open the tunnel")
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func newRef() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b)
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

// Broadcast writes a notification to every open channel, channel by channel, which every
// control plane reads. The daemon's own broadcasts go as fan-out frames (#167).
func (u *Uplink) Broadcast(line string) {
	u.mu.Lock()
	var cs []*channel
	for _, c := range u.channels {
		cs = append(cs, c)
	}
	u.mu.Unlock()
	for _, c := range cs {
		_ = c.Write(line)
	}
}
