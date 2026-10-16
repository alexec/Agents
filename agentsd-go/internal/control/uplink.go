package control

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"log"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/alexec/agents/agentsd-go/internal/safe"
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
	lines    *Lines
	channels map[int]*channel
	nextID   atomic.Int64
	OnChange func(connected bool, problem string)
	tunnels  map[string]chan *channel
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
		u.mu.Lock()
		u.lines = l
		u.channels = map[int]*channel{}
		u.mu.Unlock()
		hello := u.Hello
		hello.Host = u.Member.Host
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
		l.Close()
		u.mu.Lock()
		open := u.channels
		u.channels = nil
		u.lines = nil
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
	l := u.lines
	u.mu.Unlock()
	if l == nil {
		return errOffline
	}
	return l.Write(context.Background(), line)
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

func channelLine(n int, message string) string {
	return `{"c":` + strconv.Itoa(n) + `,"m":` + message + `}`
}

type channelOpen struct {
	Client    string  `json:"client"`
	Device    *string `json:"device"`
	Tunnel    *string `json:"tunnel"`
	TunnelRef *string `json:"tunnelRef"`
	FanOut    *bool   `json:"fanOut"`
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
		C     *int            `json:"c"`
		M     json.RawMessage `json:"m"`
		Open  *channelOpen    `json:"open"`
		Close bool            `json:"close"`
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
			if wait != nil && u.channels != nil {
				u.channels[c.number] = c
			}
			u.mu.Unlock()
			if wait == nil {
				log.Printf("uplink: a tunnel for %s was opened that this host did not ask for; it lends no sign-in", *frame.Open.Tunnel)
				_ = u.write(`{"c":` + strconv.Itoa(*frame.C) + `,"close":true}`)
				return
			}
			wait <- c
			return
		}
		if frame.Open.Device != nil {
			c.device = *frame.Open.Device
		}
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
		// projects/detect from an older control plane is said done; replies to our own
		// requests are not waited on in this spike.
		if strings.Contains(message, `"projects/detect"`) {
			u.Tell("projects/detected", map[string]int{"added": 0})
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
	once   sync.Once
	closed atomic.Bool
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

// Broadcast writes a notification to every open channel. The Swift host uses fan-out
// frames for this (#167); this spike writes channel by channel, which every control
// plane reads.
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
