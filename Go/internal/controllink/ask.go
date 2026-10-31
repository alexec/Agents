package controllink

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// JoinAsk is control-join-ask: what a host with no code asks to join (#994), written by
// the install script's --join.
type JoinAsk struct {
	URL    string `json:"url"`
	Pin    string `json:"pin"`
	Person string `json:"person"`
}

// AskToJoin asks a control plane to let this host join as a person, with no code (#994,
// spec 736 FR-017): it says its key, shows the short code made from that key (shown,
// JoinCode), and waits until the person approves or denies it, or 10 minutes pass. Once
// approved, it keeps the membership, and connects as h:<id> with its own key.
func AskToJoin(ctx context.Context, root string, ask JoinAsk, private []byte, hello MachineHello, shown func(code string)) (*Membership, error) {
	pin := ask.Pin
	if pin == "-" {
		pin = ""
	}
	base := strings.TrimSuffix(ask.URL, "/")
	if !AcceptableEndpoint(wire.ControlEndpoint{URL: base}) {
		return nil, fmt.Errorf("%s is not an address a host can join", base)
	}
	pub, err := PublicKey(private)
	if err != nil {
		return nil, err
	}
	client := httpsClient(pin)
	name := ""
	if hello.Name != nil {
		name = *hello.Name
	}
	body, _ := json.Marshal(wire.MachineJoinAsk{Name: name, Platform: hello.Platform, Version: &hello.Version,
		PublicKey: pub, MachineID: &hello.MachineID, Person: &ask.Person})
	var ticket wire.MachineJoinTicket
	if err := callJSON(ctx, client, http.MethodPost, base+"/v1/join", body, &ticket); err != nil {
		return nil, err
	}
	// The code made here, never the control plane's: one that passed the request on with
	// another key could only pass on that key's code.
	shown(JoinCode(pub))
	for {
		var d wire.MachineJoinDecision
		if err := callJSON(ctx, client, http.MethodGet, base+"/v1/join/"+ticket.Request, nil, &d); err != nil {
			if ctx.Err() != nil {
				return nil, ctx.Err()
			}
			// The control plane may be restarting: the request is kept in its store.
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(5 * time.Second):
			}
			continue
		}
		switch d.Result {
		case "waiting":
			continue
		case "approved":
			if d.Host == nil || len(d.ControlKey) == 0 {
				return nil, errors.New("the control plane approved the join but did not say the host")
			}
			m := &Membership{Host: string(*d.Host), ControlKey: d.ControlKey, Addresses: []string{}, URL: base, Pin: pin}
			if d.Name != nil {
				m.Name = *d.Name
			}
			return m, m.Save(root)
		case "denied":
			return nil, errors.New("the join was denied")
		default:
			return nil, errors.New("nobody approved the join within 10 minutes")
		}
	}
}

// httpsClient checks the control plane's certificate by its pin, or by TrustRoots, through
// the network's proxy (#2177).
func httpsClient(pin string) *http.Client {
	return &http.Client{Timeout: 40 * time.Second, Transport: transport(pin)}
}

func callJSON(ctx context.Context, client *http.Client, method, url string, body []byte, into any) error {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, url, reader)
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	data, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	if resp.StatusCode != http.StatusOK {
		var refusal struct {
			Error string `json:"error"`
		}
		if json.Unmarshal(data, &refusal) == nil && refusal.Error != "" {
			return errors.New(refusal.Error)
		}
		return fmt.Errorf("%s %s: %s", method, url, resp.Status)
	}
	return json.Unmarshal(data, into)
}
