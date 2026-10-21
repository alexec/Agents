package controllink

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/signin"
	"github.com/alexec/agents/Go/wire"
)

// SignInNonce is the nonce a client signs in with (#995, R2): made by the client itself
// from the control key it trusts and the challenge, never taken from the control plane,
// so a token made for one control plane is no good at another.
func SignInNonce(controlKey, challenge []byte) string {
	sum := sha256.Sum256(controlKey)
	return signin.Nonce(hex.EncodeToString(sum[:8]), challenge)
}

// SignInWith is what a client does with its provider: given the providers turned on and
// the nonce, it signs in and says the provider and its token.
type SignInWith func(providers wire.SignInProviders, nonce string) (provider, token string, err error)

// SignIn pairs a client with no code (#995): it dials as s:<a new UUID> with a new key,
// signs in with its provider on that connection, and is paired as the person the sign-in
// names. A GitHub sign-in waits for Approve on another of the person's clients; waiting
// is told the code it shows. controlKey is the key the client already trusts, or nil to
// take the hello's (a URL alone, behind TLS).
func SignIn(ctx context.Context, base, pin string, controlKey []byte, name, kind string, with SignInWith,
	waiting func(wire.SignInWaiting)) (*ClientMembership, error) {
	origin, err := Origin(base)
	if err != nil {
		return nil, err
	}
	l, err := Dial(ctx, base, pin)
	if err != nil {
		return nil, err
	}
	defer l.Close()
	rctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	line, err := l.Read(rctx)
	if err != nil {
		return nil, fmt.Errorf("no hello: %w", err)
	}
	h, ok := ParseMessage(line)
	if !ok || h.Hello == nil {
		return nil, fmt.Errorf("expected hello, got %s", line)
	}
	if controlKey == nil {
		if controlKey, err = FromB64URL(h.Hello.Control); err != nil || !ValidPublicKey(controlKey) {
			return nil, Refuse(BadMessage)
		}
	}
	helloNonce, err := FromB64URL(h.Hello.Nonce)
	if err != nil {
		return nil, Refuse(BadMessage)
	}
	private := NewPrivateKey()
	public, _ := PublicKey(private)
	id := strings.ToUpper(newRef())
	key, err := ClientKey(private, controlKey, id)
	if err != nil {
		return nil, err
	}
	auth, expect, err := Answer(h.Hello, Identity{'s', id}, key, origin, kind, controlKey, "", nil)
	if err != nil {
		return nil, err
	}
	auth.PublicKey = public
	if err := l.Write(ctx, Message{Auth: auth}.Line()); err != nil {
		return nil, err
	}
	if line, err = l.Read(rctx); err != nil {
		return nil, fmt.Errorf("no ok: %w", err)
	}
	m, ok := ParseMessage(line)
	switch {
	case !ok:
		return nil, fmt.Errorf("expected ok, got %s", line)
	case m.OK == nil:
		return nil, Refuse(m.Refused)
	}
	// The control plane proved it holds the key the nonce is bound to.
	if err := Check(m.OK, expect); err != nil {
		return nil, err
	}
	call := func(n int, method string, params any) (json.RawMessage, error) {
		p, _ := json.Marshal(params)
		req, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": n, "method": method, "params": json.RawMessage(p)})
		if err := l.Write(ctx, string(req)); err != nil {
			return nil, err
		}
		for {
			line, err := l.Read(ctx)
			if err != nil {
				return nil, err
			}
			var r struct {
				ID     *int            `json:"id"`
				Method string          `json:"method"`
				Params json.RawMessage `json:"params"`
				Result json.RawMessage `json:"result"`
				Error  *struct {
					Code    int    `json:"code"`
					Message string `json:"message"`
				} `json:"error"`
			}
			if json.Unmarshal([]byte(line), &r) != nil {
				return nil, fmt.Errorf("%s: %s", method, line)
			}
			if r.ID == nil && r.Method == "control/signInWaiting" {
				var w wire.SignInWaiting
				if json.Unmarshal(r.Params, &w) == nil && waiting != nil {
					waiting(w)
				}
				continue
			}
			if r.ID == nil || *r.ID != n {
				continue
			}
			if r.Error != nil {
				return nil, fmt.Errorf("%d %s", r.Error.Code, r.Error.Message)
			}
			return r.Result, nil
		}
	}
	raw, err := call(1, "signIn/providers", map[string]any{})
	if err != nil {
		return nil, err
	}
	var providers wire.SignInProviders
	if err := json.Unmarshal(raw, &providers); err != nil {
		return nil, err
	}
	provider, token, err := with(providers, SignInNonce(controlKey, helloNonce))
	if err != nil {
		return nil, err
	}
	raw, err = call(2, "signIn/pair", wire.SignInPair{Provider: provider, Token: token, Name: name, Kind: wire.ClientKind(kind)})
	if err != nil {
		return nil, err
	}
	var admitted wire.Admitted
	if json.Unmarshal(raw, &admitted) != nil || admitted.Client == nil || !strings.EqualFold(string(*admitted.Client), id) {
		return nil, fmt.Errorf("signIn/pair: %s", raw)
	}
	return &ClientMembership{Client: id, Private: private, ControlKey: controlKey, URL: base, Pin: pin, Name: h.Hello.Name}, nil
}
