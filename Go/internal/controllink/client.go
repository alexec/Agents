package controllink

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// ClientMembership is what a paired client keeps to dial again.
type ClientMembership struct {
	Client     string `json:"client"`
	Private    []byte `json:"privateKey"`
	ControlKey []byte `json:"controlKey"`
	URL        string `json:"url"`
	Pin        string `json:"pin,omitempty"`
	Name       string `json:"name"`
	// What it says it has when it connects (#1748); nil says what a client declares.
	Capabilities []string `json:"-"`
}

// PairClient uses a client code once (clients/announce), as a window does.
func PairClient(ctx context.Context, code *Code, name string) (*ClientMembership, error) {
	return PairClientAs(ctx, code, name, "mac")
}

// PairClientAs is PairClient as another kind of client: "iPhone" or "iPad" for a walk's
// stand-in for a device (#1507).
func PairClientAs(ctx context.Context, code *Code, name, kind string) (*ClientMembership, error) {
	if code.Host {
		return nil, errors.New("that is a host code")
	}
	private := NewPrivateKey()
	pub, _ := PublicKey(private)
	id := strings.ToUpper(newRef())
	l, _, err := Join(ctx, code.URL, code.Pin, Credentials{Identity: "p:" + code.ID(), Key: CodeKey(code.Secret), Kind: "mac", ControlKey: code.ControlKey})
	if err != nil {
		return nil, err
	}
	defer l.Close()
	params, _ := json.Marshal(map[string]any{"id": id, "publicKey": pub, "name": name, "kind": kind})
	req, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "clients/announce", "params": json.RawMessage(params)})
	if err := l.Write(ctx, string(req)); err != nil {
		return nil, err
	}
	rctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	line, err := l.Read(rctx)
	if err != nil {
		return nil, err
	}
	var reply struct {
		Result *struct {
			Client string `json:"client"`
		} `json:"result"`
	}
	if json.Unmarshal([]byte(line), &reply) != nil || reply.Result == nil {
		return nil, fmt.Errorf("clients/announce: %s", line)
	}
	if reply.Result.Client != "" {
		id = reply.Result.Client
	}
	return &ClientMembership{Client: id, Private: private, ControlKey: code.ControlKey, URL: code.URL, Pin: code.Pin, Name: code.Name}, nil
}

// Session is a client's socket to the control plane: requests to it or to a host, and
// the notifications every host sends.
type Session struct {
	l       *Lines
	next    atomic.Int64
	mu      sync.Mutex
	waiting map[int64]chan json.RawMessage
	Notes   chan Note
	// done is closed when the socket ends: a call waiting then fails at once.
	done chan struct{}
}

type Note struct {
	Host   string
	Method string
	Params json.RawMessage
}

func DialClient(ctx context.Context, m *ClientMembership) (*Session, error) {
	key, err := ClientKey(m.Private, m.ControlKey, m.Client)
	if err != nil {
		return nil, err
	}
	epoch := 0
	capabilities := m.Capabilities
	if capabilities == nil {
		capabilities = wire.DeclaredCapabilities["client"]
	}
	l, ok, err := Join(ctx, m.URL, m.Pin, Credentials{Identity: "c:" + m.Client, Key: key, Kind: "mac", ControlKey: m.ControlKey, Epoch: &epoch,
		Capabilities: capabilities})
	if err != nil {
		return nil, err
	}
	// The control plane rotated its key (#997): trusted from now on.
	if fresh, _ := NewKey(ok, key); fresh != nil {
		m.ControlKey = fresh
	}
	s := &Session{l: l, waiting: map[int64]chan json.RawMessage{}, Notes: make(chan Note, 4096), done: make(chan struct{})}
	safe.Go("client read", func() { s.read(ctx) })
	return s, nil
}

func (s *Session) read(ctx context.Context) {
	defer close(s.done)
	defer close(s.Notes)
	for {
		line, err := s.l.Read(ctx)
		if err != nil {
			return
		}
		var f struct {
			H string          `json:"h"`
			M json.RawMessage `json:"m"`
		}
		if json.Unmarshal([]byte(line), &f) != nil {
			continue
		}
		var m struct {
			ID     *int64          `json:"id"`
			Method string          `json:"method"`
			Params json.RawMessage `json:"params"`
		}
		if json.Unmarshal(f.M, &m) != nil {
			continue
		}
		if m.Method != "" && m.ID == nil {
			select {
			case s.Notes <- Note{Host: f.H, Method: m.Method, Params: m.Params}:
			default:
			}
			continue
		}
		if m.ID != nil {
			s.mu.Lock()
			w := s.waiting[*m.ID]
			delete(s.waiting, *m.ID)
			s.mu.Unlock()
			if w != nil {
				w <- f.M
			}
		}
	}
}

// Call sends method to host ("" for the control plane itself) and returns the result.
func (s *Session) Call(ctx context.Context, host, method string, params any) (json.RawMessage, error) {
	id := s.next.Add(1)
	msg := map[string]any{"jsonrpc": "2.0", "id": id, "method": method}
	if params != nil {
		msg["params"] = params
	}
	b, _ := json.Marshal(msg)
	line := `{"m":` + string(b) + `}`
	if host != "" {
		line = `{"h":"` + host + `","m":` + string(b) + `}`
	}
	w := make(chan json.RawMessage, 1)
	s.mu.Lock()
	s.waiting[id] = w
	s.mu.Unlock()
	if err := s.l.Write(ctx, line); err != nil {
		return nil, err
	}
	select {
	case raw := <-w:
		var r struct {
			Result json.RawMessage `json:"result"`
			Error  json.RawMessage `json:"error"`
		}
		json.Unmarshal(raw, &r)
		if r.Error != nil {
			return nil, fmt.Errorf("%s", r.Error)
		}
		return r.Result, nil
	case <-s.done:
		return nil, errors.New("the control plane closed the connection")
	case <-ctx.Done():
		return nil, ctx.Err()
	case <-time.After(120 * time.Second):
		return nil, errors.New("no answer in 120 s")
	}
}

func (s *Session) Close() { s.l.Close() }
