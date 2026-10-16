package daemon

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"

	"github.com/alexec/agents/agentsd-go/internal/control"
)

// Tunneler opens a tunnel to the host that lends a runtime's sign-in.
type Tunneler interface {
	OpenTunnel(ctx context.Context, runtime string) (control.Conn, error)
}

// relay is a sign-in lent by another host (056, T091): a TCP gate on loopback the runtime
// is pointed at, each of whose connections is a tunnel through the control plane to the
// lender's TLS relay. TLS ends on the lender; this host and the control plane see ciphertext.
type relay struct {
	port    int
	standIn string
	caFile  string
	ln      net.Listener
}

type relayOffer struct {
	Runtime       string `json:"runtime"`
	SocketPath    string `json:"socketPath"`
	CACertificate string `json:"caCertificate"`
	StandIn       string `json:"standIn"`
}

func (d *Daemon) SetTunneler(t Tunneler) { d.tunneler = t }

func (d *Daemon) relayFor(runtime string) *relay {
	d.mu.Lock()
	defer d.mu.Unlock()
	return d.relays[runtime]
}

func (d *Daemon) offerRelay(o relayOffer) error {
	if d.tunneler == nil {
		return &RPCError{Code: -32000, Message: "this host has no control plane to tunnel through"}
	}
	dir := filepath.Join(d.Root, "runtimes")
	os.MkdirAll(dir, 0o700)
	ca := filepath.Join(dir, o.Runtime+"-relay-ca.pem")
	if err := os.WriteFile(ca, []byte(o.CACertificate), 0o600); err != nil {
		return err
	}
	d.mu.Lock()
	old := d.relays[o.Runtime]
	d.mu.Unlock()
	if old != nil {
		old.standIn, old.caFile = o.StandIn, ca
		return nil
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return err
	}
	r := &relay{port: ln.Addr().(*net.TCPAddr).Port, standIn: o.StandIn, caFile: ca, ln: ln}
	d.mu.Lock()
	if d.relays == nil {
		d.relays = map[string]*relay{}
	}
	d.relays[o.Runtime] = r
	d.mu.Unlock()
	log.Printf("relay: %s's sign-in is lent; gate on 127.0.0.1:%d", o.Runtime, r.port)
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go d.pump(o.Runtime, c)
		}
	}()
	return nil
}

// pump carries one TCP connection through one tunnel: bytes as base64 JSON strings, 32 KiB at most.
func (d *Daemon) pump(runtime string, c net.Conn) {
	defer c.Close()
	t, err := d.tunneler.OpenTunnel(d.ctx, runtime)
	if err != nil {
		log.Printf("relay: %v", err)
		return
	}
	var once sync.Once
	done := func() { once.Do(func() { t.Close(); c.Close() }) }
	go func() {
		defer done()
		for line := range t.In() {
			var s string
			if json.Unmarshal([]byte(line), &s) != nil {
				continue
			}
			b, err := base64.StdEncoding.DecodeString(s)
			if err != nil {
				continue
			}
			if _, err := c.Write(b); err != nil {
				return
			}
		}
	}()
	buf := make([]byte, 32<<10)
	for {
		n, err := c.Read(buf)
		if n > 0 {
			if t.Write(strconv.Quote(base64.StdEncoding.EncodeToString(buf[:n]))) != nil {
				break
			}
		}
		if err != nil {
			break
		}
	}
	done()
}

// signedIn says whether this machine has Claude's own sign-in.
func ownClaudeSignIn() bool {
	if os.Getenv("CLAUDE_CODE_OAUTH_TOKEN") != "" || os.Getenv("ANTHROPIC_API_KEY") != "" {
		return true
	}
	home, _ := os.UserHomeDir()
	_, err := os.Stat(filepath.Join(home, ".claude", ".credentials.json"))
	return err == nil
}
