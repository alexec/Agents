package controllink

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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
}

// HostHello is DaemonAPI.HostHello: what a host says on every connect. Implementation is
// "go" from this host (#1134), so the Hosts pane can say so; a control plane that does
// not know the field ignores it, as Swift's Codable does.
type HostHello = wire.HostHello

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
func Enroll(ctx context.Context, root string, code *Code, private []byte, hello HostHello) (*Membership, error) {
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
	params, _ := json.Marshal(wire.HostAnnounce{PublicKey: pub, Name: name, Platform: hello.Platform, Version: hello.Version,
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
