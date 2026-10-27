package controllink

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Membership is control-host.json, in the Swift ControlMembership's own shape ([]byte is
// base64 as JSONEncoder writes Data), so a Swift agentsd could read the Go host's root.
type Membership struct {
	Host       string   `json:"host"`
	ControlKey []byte   `json:"controlKey"`
	Addresses  []string `json:"addresses"`
	Name       string   `json:"name"`
	URL        string   `json:"url"`
	Pin        string   `json:"pin,omitempty"`
	// Endpoints is the list the control plane last gave in ok, in the order to try, and
	// Epoch its number (R16, T125): a control plane that moves tells its members where it
	// goes, so none pairs again.
	Endpoints []wire.ControlEndpoint `json:"endpoints,omitempty"`
	Epoch     *int                   `json:"epoch,omitempty"`
}

// EndpointsToDial is ControlMembership.endpointsToDial: the list the control plane last
// gave, or the one address the code gave.
func (m *Membership) EndpointsToDial() []wire.ControlEndpoint {
	if len(m.Endpoints) > 0 {
		return m.Endpoints
	}
	if m.URL == "" {
		return nil
	}
	e := wire.ControlEndpoint{URL: m.URL}
	if m.Pin != "" {
		pin := m.Pin
		e.Pin = &pin
	}
	return []wire.ControlEndpoint{e}
}

// Adopt is ControlMembership.adopting: the list an ok gave, when it is newer than the one
// kept and every entry is one a code could carry. It says whether anything changed.
func (m *Membership) Adopt(ok *OK) bool {
	rotated := m.adoptKey(ok)
	return m.adoptEndpoints(ok) || rotated
}

// adoptKey takes the control plane's new key from an ok (#997), which Join has checked.
func (m *Membership) adoptKey(ok *OK) bool {
	if ok == nil || ok.NewKey == nil {
		return false
	}
	key, err := FromB64URL(ok.NewKey.Key)
	if err != nil || Same(key, m.ControlKey) {
		return false
	}
	m.ControlKey = key
	return true
}

func (m *Membership) adoptEndpoints(ok *OK) bool {
	if ok == nil || ok.Epoch == nil || len(ok.Endpoints) == 0 {
		return false
	}
	epoch := int(*ok.Epoch)
	if m.Epoch != nil && epoch <= *m.Epoch {
		return false
	}
	for _, e := range ok.Endpoints {
		if !AcceptableEndpoint(e) {
			return false
		}
	}
	m.Endpoints = append([]wire.ControlEndpoint(nil), ok.Endpoints...)
	m.Epoch = &epoch
	m.URL = m.Endpoints[0].URL
	m.Pin = ""
	if m.Endpoints[0].Pin != nil {
		m.Pin = *m.Endpoints[0].Pin
	}
	return true
}

// AcceptableEndpoint is ControlEndpoint.isAcceptable: what a code would accept, https, or
// http on this machine only, and a pin that is a SHA-256 in base64url.
func AcceptableEndpoint(e wire.ControlEndpoint) bool {
	u, err := url.Parse(e.URL)
	if err != nil || u.Hostname() == "" {
		return false
	}
	switch strings.ToLower(u.Scheme) {
	case "https", "wss":
	case "http":
		if h := u.Hostname(); h != "127.0.0.1" && h != "localhost" && h != "::1" {
			return false
		}
	default:
		return false
	}
	if e.Pin != nil {
		pin, err := FromB64URL(*e.Pin)
		return err == nil && len(pin) == 32
	}
	return true
}

// MachineHello is DaemonAPI.MachineHello: what a host says on every connect. Implementation is
// "go" from this host (#1134), so the Hosts pane can say so; a control plane that does
// not know the field ignores it, as Swift's Codable does.
type MachineHello = wire.MachineHello

func LoadMembership(root string) (*Membership, error) {
	b, err := os.ReadFile(filepath.Join(root, "control-host.json"))
	if err != nil {
		return nil, err
	}
	var m Membership
	return &m, json.Unmarshal(b, &m)
}

func (m *Membership) Save(root string) error {
	b, _ := json.Marshal(m)
	tmp := filepath.Join(root, ".control-host.json.tmp")
	if err := os.WriteFile(tmp, b, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, filepath.Join(root, "control-host.json"))
}

// HostPrivateKey is control-host-key: 32 raw bytes, made once.
func HostPrivateKey(root string) ([]byte, error) {
	file := filepath.Join(root, "control-host-key")
	if b, err := os.ReadFile(file); err == nil && len(b) == 32 {
		return b, nil
	}
	k := NewPrivateKey()
	return k, os.WriteFile(file, k, 0o600)
}

// Enroll uses a host code once: proves the code's key, says hosts/announce, keeps the answer.
func Enroll(ctx context.Context, root string, code *Code, private []byte, hello MachineHello) (*Membership, error) {
	if !code.Host {
		return nil, errors.New("that is not a host code")
	}
	pub, err := PublicKey(private)
	if err != nil {
		return nil, err
	}
	l, _, err := Join(ctx, code.URL, code.Pin, Credentials{
		Identity: "e:" + code.ID(), Key: CodeKey(code.Secret), Kind: "host", ControlKey: code.ControlKey,
	})
	if err != nil {
		return nil, fmt.Errorf("enrol: %w", err)
	}
	defer l.Close()
	name := ""
	if hello.Name != nil {
		name = *hello.Name
	}
	params, _ := json.Marshal(wire.MachineAnnounce{PublicKey: pub, Name: name, Platform: hello.Platform, Version: hello.Version,
		MachineID: hello.MachineID, Implementation: hello.Implementation})
	req, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "hosts/announce", "params": json.RawMessage(params)})
	if err := l.Write(ctx, string(req)); err != nil {
		return nil, err
	}
	rctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	line, err := l.Read(rctx)
	if err != nil {
		return nil, fmt.Errorf("the control plane did not answer: %w", err)
	}
	var reply struct {
		Result *wire.Admitted `json:"result"`
	}
	if err := json.Unmarshal([]byte(line), &reply); err != nil {
		return nil, err
	}
	if reply.Result == nil || reply.Result.Host == nil || *reply.Result.Host == "" {
		return nil, fmt.Errorf("hosts/announce: %s", line)
	}
	m := &Membership{Host: string(*reply.Result.Host), ControlKey: code.ControlKey, Addresses: []string{}, Name: code.Name, URL: code.URL, Pin: code.Pin}
	return m, m.Save(root)
}
