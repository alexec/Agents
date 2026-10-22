package audit

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Sinks (#1001, T8 slice d2): each audit entry this copy of the control plane writes also
// goes to each sink an admin set, within seconds. A sink is syslog (RFC 5424, framed by
// octet counting as RFC 6587 says, over TCP or TLS) or HTTP (a POST of JSON lines). Each
// sink has a queue of its own, so one that is down holds up no other. A queue keeps at
// most OutboxMost entries: when it is full the oldest goes, and the next line sent says
// how many went.
//
// A line is `{"key":…,"hash":…,"entry":…}`: the entry on one line, and the hash its
// stored bytes have in the chain, so a SIEM can follow each chain (chain, seq, prev) by
// itself; with `"dropped":N` first when entries went.

const (
	// SinksMost is how many sinks an admin may set.
	SinksMost = 4
	// OutboxMost bounds each sink's queue.
	OutboxMost = 10_000
	// sinkBatch is the most lines one send carries.
	sinkBatch = 500
	// sinkWait bounds one send.
	sinkWait = 10 * time.Second
	// sinkBackoffMost is the longest wait after a send that failed.
	sinkBackoffMost = time.Minute
)

type queued struct {
	n    int64
	key  string
	data []byte
}

// Outbox is one sink's queue.
type Outbox struct {
	mu    sync.Mutex
	most  int
	items []queued
	next  int64
	// unsaid is how many were dropped and not yet said on a line sent; dropped, since
	// the start.
	unsaid, dropped int64
	wake            chan struct{}
}

func newOutbox(most int) *Outbox { return &Outbox{most: most, wake: make(chan struct{}, 1)} }

// Add queues an entry, dropping the oldest when the queue is full.
func (o *Outbox) Add(key string, data []byte) {
	o.mu.Lock()
	if len(o.items) >= o.most {
		o.items = o.items[1:]
		o.unsaid++
		o.dropped++
	}
	o.next++
	o.items = append(o.items, queued{n: o.next, key: key, data: data})
	o.mu.Unlock()
	select {
	case o.wake <- struct{}{}:
	default:
	}
}

// peek is up to n lines from the front, the place of the last, and the drops the first
// line says.
func (o *Outbox) peek(n int) (lines [][]byte, last, said int64) {
	o.mu.Lock()
	defer o.mu.Unlock()
	for i, q := range o.items {
		if i == n {
			break
		}
		drop := int64(0)
		if i == 0 {
			drop = o.unsaid
		}
		lines = append(lines, SinkLine(q.key, q.data, drop))
		last = q.n
	}
	return lines, last, o.unsaid
}

// done takes what was sent off the front: every entry up to last, and the drops said.
func (o *Outbox) done(last, said int64) {
	o.mu.Lock()
	defer o.mu.Unlock()
	i := 0
	for i < len(o.items) && o.items[i].n <= last {
		i++
	}
	o.items = o.items[i:]
	o.unsaid = max(0, o.unsaid-said)
}

// Counts is how many wait and how many were dropped.
func (o *Outbox) Counts() (queued, dropped int64) {
	o.mu.Lock()
	defer o.mu.Unlock()
	return int64(len(o.items)), o.dropped
}

// SinkLine is one entry as a sink gets it, on one line.
func SinkLine(key string, data []byte, dropped int64) []byte {
	var b bytes.Buffer
	k, _ := json.Marshal(key)
	b.WriteString(`{`)
	if dropped > 0 {
		b.WriteString(`"dropped":` + strconv.FormatInt(dropped, 10) + `,`)
	}
	b.WriteString(`"key":`)
	b.Write(k)
	b.WriteString(`,"hash":"` + Hash(data) + `","entry":`)
	if err := json.Compact(&b, data); err != nil {
		b.WriteString(`null`)
	}
	b.WriteString(`}`)
	return b.Bytes()
}

// CheckSink says what is wrong with a sink an admin set, or nil.
func CheckSink(s wire.AuditSink) error {
	u, err := url.Parse(strings.TrimSpace(s.Address))
	if err != nil || u.Host == "" {
		return fmt.Errorf("%q is not an address", s.Address)
	}
	switch s.Kind {
	case wire.AuditSinkKindSyslog:
		if u.Scheme != "tcp" && u.Scheme != "tls" || u.Port() == "" || u.Path != "" && u.Path != "/" {
			return fmt.Errorf("a syslog sink is tcp://host:port or tls://host:port, not %q", s.Address)
		}
		if s.Token != nil && *s.Token != "" {
			return errors.New("a syslog sink takes no token")
		}
	case wire.AuditSinkKindHttp:
		local := u.Hostname() == "localhost" || net.ParseIP(u.Hostname()) != nil && net.ParseIP(u.Hostname()).IsLoopback()
		if u.Scheme != "https" && !(u.Scheme == "http" && local) {
			return fmt.Errorf("an HTTP sink is an https:// address (http:// only on this machine), not %q", s.Address)
		}
	default:
		return fmt.Errorf("%q is not a kind of sink: syslog or http", s.Kind)
	}
	return nil
}

// sender sends a batch of lines to one place.
type sender interface {
	send(ctx context.Context, lines [][]byte) error
	close()
}

type httpSender struct {
	url, token string
	client     *http.Client
}

func (h *httpSender) send(ctx context.Context, lines [][]byte) error {
	body := bytes.Join(lines, []byte("\n"))
	body = append(body, '\n')
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, h.url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-ndjson")
	if h.token != "" {
		req.Header.Set("Authorization", "Bearer "+h.token)
	}
	resp, err := h.client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode/100 != 2 {
		return fmt.Errorf("%s answered %s", h.url, resp.Status)
	}
	return nil
}

func (h *httpSender) close() { h.client.CloseIdleConnections() }

type syslogSender struct {
	addr, host, procID string
	tls                bool
	roots              *tls.Config
	conn               net.Conn
}

// syslogPRI is facility 13 (log audit) and severity 6 (informational).
const syslogPRI = 13*8 + 6

// SyslogFrame is one line as RFC 5424 says, framed by its length (RFC 6587, octet counting).
func SyslogFrame(line []byte, at time.Time, host, procID string) []byte {
	// HOSTNAME is printable US-ASCII, at most 255 of it.
	host = strings.Map(func(r rune) rune {
		if r < 33 || r > 126 {
			return '-'
		}
		return r
	}, host)
	if host == "" {
		host = "-"
	}
	if len(host) > 255 {
		host = host[:255]
	}
	msg := fmt.Sprintf("<%d>1 %s %s agents-control %s audit - ", syslogPRI, at.UTC().Format("2006-01-02T15:04:05.000000Z"),
		host, procID)
	frame := append([]byte(msg), line...)
	return append([]byte(strconv.Itoa(len(frame))+" "), frame...)
}

func (s *syslogSender) send(ctx context.Context, lines [][]byte) error {
	if s.conn == nil {
		d := net.Dialer{Timeout: sinkWait}
		var err error
		if s.tls {
			config := s.roots
			if config == nil {
				config = &tls.Config{}
			}
			s.conn, err = (&tls.Dialer{NetDialer: &d, Config: config}).DialContext(ctx, "tcp", s.addr)
		} else {
			s.conn, err = d.DialContext(ctx, "tcp", s.addr)
		}
		if err != nil {
			return err
		}
	}
	deadline, _ := ctx.Deadline()
	s.conn.SetWriteDeadline(deadline)
	var b bytes.Buffer
	now := time.Now()
	for _, l := range lines {
		b.Write(SyslogFrame(l, now, s.host, s.procID))
	}
	if _, err := s.conn.Write(b.Bytes()); err != nil {
		s.close()
		return err
	}
	return nil
}

func (s *syslogSender) close() {
	if s.conn != nil {
		s.conn.Close()
		s.conn = nil
	}
}

// Sink is one sink and its queue, sent by a goroutine of its own.
type Sink struct {
	Config wire.AuditSink
	out    *Outbox
	sender sender
	stop   chan struct{}
	ended  chan struct{}
	mu     sync.Mutex
	sentAt time.Time
	failed string
}

// SinkFrom is where a sink's lines go, as host (this control plane's name) and procID
// (this copy) name them in a syslog line. TLS, for a test, trusts its own roots.
type SinkFrom struct {
	Host, ProcID string
	TLS          *tls.Config
}

func newSink(c wire.AuditSink, out *Outbox, from SinkFrom) *Sink {
	u, _ := url.Parse(strings.TrimSpace(c.Address))
	var s sender
	if c.Kind == wire.AuditSinkKindSyslog {
		s = &syslogSender{addr: u.Host, host: from.Host, procID: from.ProcID, tls: u.Scheme == "tls", roots: from.TLS}
	} else {
		token := ""
		if c.Token != nil {
			token = *c.Token
		}
		s = &httpSender{url: u.String(), token: token, client: &http.Client{Timeout: sinkWait}}
	}
	k := &Sink{Config: c, out: out, sender: s, stop: make(chan struct{}), ended: make(chan struct{})}
	go k.run()
	return k
}

func (k *Sink) run() {
	defer close(k.ended)
	defer k.sender.close()
	backoff := time.Second
	for {
		lines, last, said := k.out.peek(sinkBatch)
		if len(lines) == 0 {
			select {
			case <-k.stop:
				return
			case <-k.out.wake:
			}
			continue
		}
		ctx, cancel := context.WithTimeout(context.Background(), sinkWait)
		err := k.sender.send(ctx, lines)
		cancel()
		k.mu.Lock()
		if err != nil {
			k.failed = err.Error()
		} else {
			k.failed, k.sentAt = "", time.Now()
		}
		k.mu.Unlock()
		if err == nil {
			k.out.done(last, said)
			backoff = time.Second
			continue
		}
		select {
		case <-k.stop:
			return
		case <-time.After(backoff):
		}
		backoff = min(backoff*2, sinkBackoffMost)
	}
}

func (k *Sink) end() {
	close(k.stop)
	<-k.ended
}

// Status is the sink as audit/sinks says it: no token, whether it has one.
func (k *Sink) Status() wire.AuditSinkStatus {
	queued, dropped := k.out.Counts()
	c := k.Config
	has := c.Token != nil && *c.Token != ""
	c.Token, c.HasToken = nil, &has
	st := wire.AuditSinkStatus{Sink: c, Queued: queued, Dropped: dropped}
	k.mu.Lock()
	defer k.mu.Unlock()
	if !k.sentAt.IsZero() {
		at := wire.DateOf(k.sentAt)
		st.SentAt = &at
	}
	if k.failed != "" {
		failed := k.failed
		st.LastError = &failed
	}
	return st
}

// Sinks is every sink this copy sends to.
type Sinks struct {
	From SinkFrom
	mu   sync.Mutex
	list []*Sink
}

func sameSink(a, b wire.AuditSink) bool {
	token := func(s wire.AuditSink) string {
		if s.Token == nil {
			return ""
		}
		return *s.Token
	}
	return a.Kind == b.Kind && strings.TrimSpace(a.Address) == strings.TrimSpace(b.Address) && token(a) == token(b)
}

// Set makes the sinks these: one already sending, unchanged, keeps its queue; one gone
// stops, and what it had queued goes with it.
func (s *Sinks) Set(configs []wire.AuditSink) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var next []*Sink
	kept := map[*Sink]bool{}
	for _, c := range configs {
		var found *Sink
		for _, k := range s.list {
			if !kept[k] && sameSink(k.Config, c) {
				found = k
				break
			}
		}
		if found == nil {
			found = newSink(c, newOutbox(OutboxMost), s.From)
		}
		kept[found] = true
		next = append(next, found)
	}
	for _, k := range s.list {
		if !kept[k] {
			k.end()
		}
	}
	s.list = next
}

// Add queues an entry for every sink.
func (s *Sinks) Add(key string, data []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, k := range s.list {
		k.out.Add(key, data)
	}
}

// State is each sink's status.
func (s *Sinks) State() []wire.AuditSinkStatus {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := []wire.AuditSinkStatus{}
	for _, k := range s.list {
		out = append(out, k.Status())
	}
	return out
}

// Stop ends every sink.
func (s *Sinks) Stop() { s.Set(nil) }
