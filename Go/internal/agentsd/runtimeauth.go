package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

// Signing a runtime in and out, and choosing its provider (DaemonCore+Runtimes): each call
// starts the runtime, asks, and lets it go again. None of it belongs to an agent.

func (d *Daemon) registerRuntimeAuth() {
	On(d, wire.CallRuntimesAuthenticate, func(ctx context.Context, c *Client, r wire.AuthenticateRequest) (wire.RuntimeAccount, error) {
		// Antigravity under its terms refused is not signed in either (#999, FR-017).
		if err := noticeRefusal(d.orgPolicy(), r.RuntimeID); err != nil {
			return wire.RuntimeAccount{}, err
		}
		if r.AccountID != nil && *r.AccountID != "" {
			return d.authenticateAccount(ctx, r.RuntimeID, *r.AccountID, r.MethodID)
		}
		return d.authenticate(ctx, r.RuntimeID, r.MethodID)
	})
	On(d, wire.CallRuntimesLogout, func(ctx context.Context, c *Client, r wire.RuntimeRequest) ([]wire.UUID, error) {
		return d.logOut(ctx, r.RuntimeID)
	})
	On(d, wire.CallRuntimesSetProvider, func(ctx context.Context, c *Client, r wire.SetProviderRequest) (wire.RuntimeAccount, error) {
		return d.setProvider(ctx, r.RuntimeID, r.ProviderID)
	})
	On(d, wire.CallRuntimesDisableProvider, func(ctx context.Context, c *Client, r wire.SetProviderRequest) (wire.RuntimeAccount, error) {
		return d.disableProvider(ctx, r.RuntimeID, r.ProviderID)
	})
}

// accountHandshake starts the runtime for an account call and notes what its handshake
// says about signing in (noteAccount): the methods, and whether it can log out.
func (d *Daemon) accountHandshake(ctx context.Context, runtimeID string) (*acp.Session, error) {
	s, _, err := d.handshake(ctx, runtimeID, &probe{commands: make(chan []wire.SlashCommand, 1)})
	if err != nil {
		return nil, err
	}
	methods := authMethods(s.Init.AuthMethods)
	d.updateAccount(runtimeID, func(a *wire.RuntimeAccount) {
		// A handshake does not prove a sign-in, so it does not take back a refusal.
		if a.State != wire.RuntimeAccountStateNeedsSignIn {
			a.State = wire.RuntimeAccountStateReady
		}
		a.AuthMethods, a.CanLogOut, a.CheckedAt = methods, s.CanLogOut(), now()
	})
	return s, nil
}

// updateAccount changes the runtime's account and tells every window (runtime/account).
func (d *Daemon) updateAccount(runtimeID string, change func(*wire.RuntimeAccount)) wire.RuntimeAccount {
	d.allowMu.Lock()
	if d.accounts == nil {
		d.accounts = map[string]wire.RuntimeAccount{}
	}
	a, ok := d.accounts[runtimeID]
	if !ok {
		a = wire.RuntimeAccount{RuntimeID: runtimeID, State: wire.RuntimeAccountStateUnknown, AuthMethods: []wire.ACPAuthMethod{},
			Providers: []wire.ACPProviderInfo{}, CheckedAt: now()}
	}
	change(&a)
	d.accounts[runtimeID] = a
	d.allowMu.Unlock()
	Broadcast(d, wire.NotifyRuntimeAccount, a)
	return a
}

func (d *Daemon) markNeedsSignIn(runtimeID string) {
	d.updateAccount(runtimeID, func(a *wire.RuntimeAccount) { a.State, a.CheckedAt = wire.RuntimeAccountStateNeedsSignIn, now() })
}

// authenticate is runtimes/authenticate. A method the runtime says needs a terminal is
// handed back as the command to run, not run: it is interactive, and it is the person's.
func (d *Daemon) authenticate(ctx context.Context, runtimeID, methodID string) (wire.RuntimeAccount, error) {
	// Signing in can open a browser and wait for the person.
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	s, err := d.accountHandshake(ctx, runtimeID)
	if err != nil {
		return wire.RuntimeAccount{}, err
	}
	defer s.Stop()
	for _, m := range authMethods(s.Init.AuthMethods) {
		if m.ID != methodID {
			continue
		}
		if command := terminalCommand(m); command != "" {
			return wire.RuntimeAccount{}, &Error{Code: wire.FailureNeedsSignIn, Message: "Run this in a terminal: " + command,
				Data: map[string]any{"command": command, "runtimeID": runtimeID}}
		}
	}
	if err := s.Authenticate(ctx, methodID); err != nil {
		d.markNeedsSignIn(runtimeID)
		return wire.RuntimeAccount{}, &Error{Code: wire.FailureNeedsSignIn, Message: "That did not sign in: " + rpcMessage(err)}
	}
	return d.updateAccount(runtimeID, func(a *wire.RuntimeAccount) { a.State, a.CheckedAt = wire.RuntimeAccountStateReady, now() }), nil
}

// authenticateAccount is runtimes/authenticate for an added account (#840): the runtime
// started on the account's folder signs in there. The runtime's own account is not
// touched, and the account's state is its folder's, so the answer is the runtime's.
func (d *Daemon) authenticateAccount(ctx context.Context, runtimeID, accountID, methodID string) (wire.RuntimeAccount, error) {
	p := d.accountProfile(runtimeID, accountID)
	if p == nil {
		return wire.RuntimeAccount{}, Invalid("There is no such account.")
	}
	ctx, cancel := context.WithTimeout(ctx, 10*time.Minute)
	defer cancel()
	s, _, err := d.handshakeAs(ctx, runtimeID, p, &probe{commands: make(chan []wire.SlashCommand, 1)})
	if err != nil {
		return wire.RuntimeAccount{}, err
	}
	defer s.Stop()
	for _, m := range authMethods(s.Init.AuthMethods) {
		if m.ID == methodID && terminalCommand(m) != "" {
			// The runtime's own command signs in its own folder: the account's names its folder.
			q := *p
			d.readSignIn(&q)
			if q.SignInCommand == nil {
				return wire.RuntimeAccount{}, Invalid("Sign in to this account in a terminal on this machine.")
			}
			return wire.RuntimeAccount{}, &Error{Code: wire.FailureNeedsSignIn, Message: "Run this in a terminal: " + *q.SignInCommand,
				Data: map[string]any{"command": *q.SignInCommand, "runtimeID": runtimeID}}
		}
	}
	if err := s.Authenticate(ctx, methodID); err != nil {
		return wire.RuntimeAccount{}, &Error{Code: wire.FailureNeedsSignIn, Message: "That did not sign in: " + rpcMessage(err)}
	}
	d.tellAccountProfiles()
	d.allowMu.Lock()
	a, ok := d.accounts[runtimeID]
	d.allowMu.Unlock()
	if !ok {
		a = wire.RuntimeAccount{RuntimeID: runtimeID, State: wire.RuntimeAccountStateUnknown, AuthMethods: []wire.ACPAuthMethod{},
			Providers: []wire.ACPProviderInfo{}, CheckedAt: now()}
	}
	return a, nil
}

// logOut is runtimes/logout, after stopping the agents that are using the runtime: they
// are mid-conversation, so it answers which.
func (d *Daemon) logOut(ctx context.Context, runtimeID string) ([]wire.UUID, error) {
	if runtimeByID(runtimeID) == nil {
		return nil, &Error{Code: CodeRuntimeNotFound, Message: "There is no runtime called " + runtimeID + "."}
	}
	stopped := []wire.UUID{}
	for _, a := range d.Store.Agents() {
		if a.RuntimeID == runtimeID && holdsRuntime(a.State) {
			d.live(a.ID).cancel()
			d.dropLeases(a.ID, "holderStopped")
			d.endWait(a.ID, "stopped", false)
			stopped = append(stopped, a.ID)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	s, err := d.accountHandshake(ctx, runtimeID)
	if err != nil {
		return nil, err
	}
	defer s.Stop()
	if err := s.LogOut(ctx); err != nil {
		return nil, accountFailure(runtimeID, "sign out", err)
	}
	d.updateAccount(runtimeID, func(a *wire.RuntimeAccount) {
		a.SignedInAs, a.State, a.CheckedAt = nil, wire.RuntimeAccountStateNeedsSignIn, now()
	})
	return stopped, nil
}

// setProvider is runtimes/setProvider.
func (d *Daemon) setProvider(ctx context.Context, runtimeID, providerID string) (wire.RuntimeAccount, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	s, err := d.accountHandshake(ctx, runtimeID)
	if err != nil {
		return wire.RuntimeAccount{}, err
	}
	defer s.Stop()
	listed, err := s.Providers(ctx)
	if err != nil {
		return wire.RuntimeAccount{}, accountFailure(runtimeID, "choose a provider", err)
	}
	p, ok := providerNamed(listed, providerID)
	if !ok {
		return wire.RuntimeAccount{}, Invalid("%s has no provider called %s.", runtimeByID(runtimeID).Name, providerID)
	}
	if p.Current == nil {
		return wire.RuntimeAccount{}, Invalid("%s has no address set up for %s yet. Set it up in %s first.", providerID, runtimeByID(runtimeID).Name, runtimeByID(runtimeID).Name)
	}
	if err := s.SetProvider(ctx, p); err != nil {
		return wire.RuntimeAccount{}, accountFailure(runtimeID, "choose a provider", err)
	}
	return d.updateAccount(runtimeID, func(a *wire.RuntimeAccount) {
		a.Providers = providerInfos(listed)
		a.CurrentProviderID = &providerID
	}), nil
}

// disableProvider is runtimes/disableProvider. The list is asked for again afterwards
// rather than edited here: where the runtime routes next is its decision.
func (d *Daemon) disableProvider(ctx context.Context, runtimeID, providerID string) (wire.RuntimeAccount, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	s, err := d.accountHandshake(ctx, runtimeID)
	if err != nil {
		return wire.RuntimeAccount{}, err
	}
	defer s.Stop()
	listed, err := s.Providers(ctx)
	if err != nil {
		return wire.RuntimeAccount{}, accountFailure(runtimeID, "turn a provider off", err)
	}
	if p, ok := providerNamed(listed, providerID); ok && p.Required {
		return wire.RuntimeAccount{}, Invalid("%s is required by this runtime and cannot be turned off.", providerID)
	}
	if err := s.DisableProvider(ctx, providerID); err != nil {
		return wire.RuntimeAccount{}, accountFailure(runtimeID, "turn a provider off", err)
	}
	after, err := s.Providers(ctx)
	return d.updateAccount(runtimeID, func(a *wire.RuntimeAccount) {
		if err == nil {
			a.Providers, a.CurrentProviderID = providerInfos(after), currentProvider(after)
		} else if a.CurrentProviderID != nil && *a.CurrentProviderID == providerID {
			a.CurrentProviderID = nil
		}
	}), nil
}

// accountFailure is a runtime's refusal, or its want of the call, in the window's words.
func accountFailure(runtimeID, what string, err error) error {
	name := runtimeID
	if rt := runtimeByID(runtimeID); rt != nil {
		name = rt.Name
	}
	if errors.Is(err, acp.ErrNotSupported) {
		return &Error{Code: CodeNotSupported, Message: name + " cannot " + what + " from here."}
	}
	return &Error{Code: CodeServer, Message: name + " did not " + what + ": " + rpcMessage(err)}
}

// rpcMessage is the runtime's own message, without the SDK's wrapping.
func rpcMessage(err error) string {
	var re *sdk.RequestError
	if errors.As(err, &re) && re.Message != "" {
		return re.Message
	}
	return err.Error()
}

// authMethods is the handshake's methods as the wire has them: id, name, description, _meta.
func authMethods(in []sdk.AuthMethod) []wire.ACPAuthMethod {
	out := []wire.ACPAuthMethod{}
	for _, m := range in {
		b, err := json.Marshal(m)
		if err != nil {
			continue
		}
		var w wire.ACPAuthMethod
		if json.Unmarshal(b, &w) == nil && w.ID != "" {
			out = append(out, w)
		}
	}
	return out
}

// terminalCommand is the command a method's _meta.terminal-auth names (Copilot), each
// word as a shell reads it back; "" for a method the runtime signs in by itself.
func terminalCommand(m wire.ACPAuthMethod) string {
	var meta struct {
		Auth *struct {
			Command *string  `json:"command"`
			Args    []string `json:"args"`
		} `json:"terminal-auth"`
	}
	if len(m.Meta) == 0 || json.Unmarshal(m.Meta, &meta) != nil || meta.Auth == nil || meta.Auth.Command == nil {
		return ""
	}
	words := []string{shellWord(*meta.Auth.Command)}
	for _, a := range meta.Auth.Args {
		words = append(words, shellWord(a))
	}
	return strings.Join(words, " ")
}

// shellWord is a word as it is when it is plain, single-quoted when it is not, so a path
// under "Application Support" pastes into Terminal whole.
func shellWord(w string) string {
	if w == "" {
		return "''"
	}
	for _, r := range w {
		if !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("-_./=:@%+,", r)) {
			return "'" + strings.ReplaceAll(w, "'", `'\''`) + "'"
		}
	}
	return w
}

func providerNamed(ps []sdk.UnstableProviderInfo, id string) (sdk.UnstableProviderInfo, bool) {
	for _, p := range ps {
		if p.Id == id {
			return p, true
		}
	}
	return sdk.UnstableProviderInfo{}, false
}

// providerInfos is the runtime's providers as the pane draws them: configured is a
// provider with routing, and its protocol is the one it routes with, or the first it takes.
func providerInfos(ps []sdk.UnstableProviderInfo) []wire.ACPProviderInfo {
	out := []wire.ACPProviderInfo{}
	for _, p := range ps {
		configured := p.Current != nil
		info := wire.ACPProviderInfo{ID: p.Id, Configured: &configured}
		switch {
		case p.Current != nil:
			proto := string(p.Current.ApiType)
			info.Protocol = &proto
		case len(p.Supported) > 0:
			proto := string(p.Supported[0])
			info.Protocol = &proto
		}
		out = append(out, info)
	}
	return out
}

// currentProvider is the one provider with routing, when only one has it.
func currentProvider(ps []sdk.UnstableProviderInfo) *string {
	var current *string
	for _, p := range ps {
		if p.Current != nil {
			if current != nil {
				return nil
			}
			id := p.Id
			current = &id
		}
	}
	return current
}
