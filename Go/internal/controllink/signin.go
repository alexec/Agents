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
	s, err := OpenSignIn(ctx, base, pin, controlKey, kind)
	if err != nil {
		return nil, err
	}
	defer s.Close()
	s.Waiting = waiting
	raw, err := s.Call(ctx, "signIn/providers", map[string]any{})
	if err != nil {
		return nil, err
	}
	var providers wire.SignInProviders
	if err := json.Unmarshal(raw, &providers); err != nil {
		return nil, err
	}
	provider, token, err := with(providers, s.Nonce())
	if err != nil {
		return nil, err
	}
	raw, err = s.Call(ctx, "signIn/pair", wire.SignInPair{Provider: provider, Token: token, Name: name, Kind: wire.ClientKind(kind)})
	if err != nil {
		return nil, err
	}
	var admitted wire.Admitted
	if json.Unmarshal(raw, &admitted) != nil || admitted.Client == nil {
		return nil, fmt.Errorf("signIn/pair: %s", raw)
	}
	return s.Membership(*admitted.Client)
}

// SignInByApproval pairs a browser by approval (#2097): signIn/ask with the account typed,
// waiting is told the code to show, and it pairs once the person types it on one of their
// clients and approves.
func SignInByApproval(ctx context.Context, base, pin string, controlKey []byte, name, account string,
	waiting func(wire.SignInWaiting)) (*ClientMembership, error) {
	s, err := OpenSignIn(ctx, base, pin, controlKey, "browser")
	if err != nil {
		return nil, err
	}
	defer s.Close()
	s.Waiting = waiting
	raw, err := s.Call(ctx, "signIn/ask", wire.SignInAsk{Account: account, Name: name})
	if err != nil {
		return nil, err
	}
	var admitted wire.Admitted
	if json.Unmarshal(raw, &admitted) != nil || admitted.Client == nil {
		return nil, fmt.Errorf("signIn/ask: %s", raw)
	}
	return s.Membership(*admitted.Client)
}

// SignInOrg pairs a client by an org provider (#1002, D2, D3): signIn/orgStart, then
// browse opens the address it gives in a browser and says the ticket the browser came
// back with, then signIn/ticket on the same connection.
func SignInOrg(ctx context.Context, base, pin string, controlKey []byte, name, kind, provider string,
	browse func(url string) (ticket string, err error)) (*ClientMembership, error) {
	s, err := OpenSignIn(ctx, base, pin, controlKey, kind)
	if err != nil {
		return nil, err
	}
	defer s.Close()
	raw, err := s.Call(ctx, "signIn/orgStart", wire.SignInOrgStart{Provider: provider, Purpose: wire.SignInOrgPurposePair,
		ReturnTo: wire.SignInOrgReturnApp})
	if err != nil {
		return nil, err
	}
	var started wire.SignInOrgStarted
	if err := json.Unmarshal(raw, &started); err != nil {
		return nil, err
	}
	ticket, err := browse(started.URL)
	if err != nil {
		return nil, err
	}
	k := wire.ClientKind(kind)
	raw, err = s.Call(ctx, "signIn/ticket", wire.SignInTicket{Ticket: ticket, Name: &name, Kind: &k})
	if err != nil {
		return nil, err
	}
	var paired wire.SignInTicketResult
	if json.Unmarshal(raw, &paired) != nil || paired.Client == nil {
		return nil, fmt.Errorf("signIn/ticket: %s", raw)
	}
	return s.Membership(*paired.Client)
}

// SignInSession is an s: connection that has proved its new key, before it is paired.
type SignInSession struct {
	// Waiting is told control/signInWaiting (a GitHub sign-in's code).
	Waiting func(wire.SignInWaiting)

	l          *Lines
	id         string
	private    []byte
	controlKey []byte
	helloNonce []byte
	base, pin  string
	name       string
	n          int
}

// OpenSignIn dials as s:<a new UUID> with a new key and proves it (#995).
func OpenSignIn(ctx context.Context, base, pin string, controlKey []byte, kind string) (*SignInSession, error) {
	return OpenSignInAs(ctx, base, pin, controlKey, kind, strings.ToUpper(newRef()), NewPrivateKey())
}

// OpenSignInAs dials as s:<id> with the key private and proves it: as the web page does
// when it comes back from its org provider with a ticket (#1002, FR-027).
func OpenSignInAs(ctx context.Context, base, pin string, controlKey []byte, kind, id string, private []byte) (*SignInSession, error) {
	return openSignIn(ctx, base, pin, "", controlKey, kind, id, private)
}

// OpenPageSignIn dials as the page on the control plane's own domain does (#1459): its
// socket, with the page's Origin, as s:<id> with the key private (#1002, FR-027).
func OpenPageSignIn(ctx context.Context, base, kind, id string, private []byte) (*SignInSession, error) {
	origin, err := Origin(base)
	if err != nil {
		return nil, err
	}
	return openSignIn(ctx, base, "", origin, nil, kind, id, private)
}

func openSignIn(ctx context.Context, base, pin, page string, controlKey []byte, kind, id string, private []byte) (*SignInSession, error) {
	origin, err := Origin(base)
	if err != nil {
		return nil, err
	}
	l, err := dial(ctx, base, pin, page)
	if err != nil {
		return nil, err
	}
	fail := func(err error) (*SignInSession, error) {
		l.Close()
		return nil, err
	}
	rctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	line, err := l.Read(rctx)
	if err != nil {
		return fail(fmt.Errorf("no hello: %w", err))
	}
	h, ok := ParseMessage(line)
	if !ok || h.Hello == nil {
		return fail(fmt.Errorf("expected hello, got %s", line))
	}
	if controlKey == nil {
		if controlKey, err = FromB64URL(h.Hello.Control); err != nil || !ValidPublicKey(controlKey) {
			return fail(Refuse(BadMessage))
		}
	}
	helloNonce, err := FromB64URL(h.Hello.Nonce)
	if err != nil {
		return fail(Refuse(BadMessage))
	}
	public, _ := PublicKey(private)
	key, err := ClientKey(private, controlKey, id)
	if err != nil {
		return fail(err)
	}
	auth, expect, err := Answer(h.Hello, Identity{'s', id}, key, origin, kind, controlKey, "", nil)
	if err != nil {
		return fail(err)
	}
	auth.PublicKey = public
	if err := l.Write(ctx, Message{Auth: auth}.Line()); err != nil {
		return fail(err)
	}
	if line, err = l.Read(rctx); err != nil {
		return fail(fmt.Errorf("no ok: %w", err))
	}
	m, ok := ParseMessage(line)
	switch {
	case !ok:
		return fail(fmt.Errorf("expected ok, got %s", line))
	case m.OK == nil:
		return fail(Refuse(m.Refused))
	}
	// The control plane proved it holds the key the nonce is bound to.
	if err := Check(m.OK, expect); err != nil {
		return fail(err)
	}
	return &SignInSession{l: l, id: id, private: private, controlKey: controlKey, helloNonce: helloNonce, base: base, pin: pin,
		name: h.Hello.Name}, nil
}

// ID is the connection's id, which the client keeps once paired.
func (s *SignInSession) ID() string { return s.id }

// Private is the key the connection proved.
func (s *SignInSession) Private() []byte { return s.private }

// Nonce is what a provider's ID token names on this connection (R2).
func (s *SignInSession) Nonce() string { return SignInNonce(s.controlKey, s.helloNonce) }

// Close closes the connection.
func (s *SignInSession) Close() { s.l.Close() }

// Call asks the control plane on the connection and waits for its answer.
func (s *SignInSession) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	s.n++
	n := s.n
	p, _ := json.Marshal(params)
	req, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": n, "method": method, "params": json.RawMessage(p)})
	if err := s.l.Write(ctx, string(req)); err != nil {
		return nil, err
	}
	for {
		line, err := s.l.Read(ctx)
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
			if json.Unmarshal(r.Params, &w) == nil && s.Waiting != nil {
				// The code this client makes itself, never the control plane's: a control
				// plane that passes the sign-in on could only pass on another key's code.
				public, _ := PublicKey(s.private)
				w.Code = ApprovalCode(public, s.controlKey)
				s.Waiting(w)
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

// Membership is what the client keeps once the control plane paired it as client.
func (s *SignInSession) Membership(client wire.UUID) (*ClientMembership, error) {
	if !strings.EqualFold(string(client), s.id) {
		return nil, fmt.Errorf("paired as %s, not %s", client, s.id)
	}
	return &ClientMembership{Client: s.id, Private: s.private, ControlKey: s.controlKey, URL: s.base, Pin: s.pin, Name: s.name}, nil
}

// approvalLetters are the letters an approval code is made of: no 0, O, 1, I or L.
const approvalLetters = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

// ApprovalCode is the code a sign-in that waits for approval shows: made from the new
// client's public key and the control key it trusts, by the client and the control plane
// each, so the new client and the card on the person's other client show the same code only
// when the key the control plane asks about is the new client's own, at the control plane
// the client dialled.
func ApprovalCode(clientPublic, controlKey []byte) string {
	return shortCode("agents-signin-approve", clientPublic, controlKey)
}

// JoinCode is the code a host that asks to join shows (#994): made from its public key, by
// the host and the control plane each, so a request that names another key shows another code.
func JoinCode(hostPublic []byte) string {
	return shortCode("agents-join-approve", hostPublic)
}

// shortCode is six letters of SHA-256(label ‖ parts), two bytes a letter: no letter is much
// likelier.
func shortCode(label string, parts ...[]byte) string {
	h := sha256.New()
	h.Write([]byte(label))
	for _, p := range parts {
		h.Write(p)
	}
	sum := h.Sum(nil)
	out := make([]byte, 6)
	for i := range out {
		v := int(sum[2*i])<<8 | int(sum[2*i+1])
		out[i] = approvalLetters[v%len(approvalLetters)]
	}
	return string(out)
}
