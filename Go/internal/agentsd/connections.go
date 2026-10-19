package agentsd

import (
	"context"
	"errors"
	"log"
	"os"
	goruntime "runtime"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Connections (#1335): the person's sign-ins to tools, kept by this host. A client starts a
// sign-in (connections/sign-in), shows the code and the links, and waits
// (connections/sign-in/wait); the host polls GitHub, keeps the tokens in its own store
// (connections.ForHost) and renews them before they end. A client is told the account and
// the state, never a token. Logged: the provider and what happened, in a word.

var (
	// connectionWaitLimit is one long poll of connections/sign-in/wait.
	connectionWaitLimit = 25 * time.Second
	// connectionFlowKept is how long an ended sign-in can still be read.
	connectionFlowKept = 10 * time.Minute
)

type connectionBook struct {
	connMu    sync.Mutex
	connFlows map[wire.UUID]*connectionFlow
	// connRenew is one renewal at a time: a refresh token is single use.
	connRenew sync.Mutex
	// newDeviceFlow is the provider's flow; a test gives a fake GitHub.
	newDeviceFlow func(provider wire.ConnectionProvider) *connections.DeviceFlow
	// connStoreFor is the host's store; a test gives a file.
	connStoreFor func() (connections.Store, error)
}

// connectionFlow is one sign-in under way, read by every client that waits on it.
type connectionFlow struct {
	mu      sync.Mutex
	state   wire.ConnectionSignIn
	changed chan struct{} // closed and replaced at each change
	cancel  context.CancelFunc
	endedAt time.Time
}

func (f *connectionFlow) snapshot() (wire.ConnectionSignIn, chan struct{}) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.state, f.changed
}

func (f *connectionFlow) end(status wire.ConnectionSignInStatus, c *wire.Connection, message string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.state.Status != wire.ConnectionSignInStatusWaiting {
		return
	}
	f.state.Status, f.state.Connection = status, c
	if message != "" {
		f.state.Message = &message
	}
	f.endedAt = time.Now()
	close(f.changed)
	f.changed = make(chan struct{})
}

func (d *Daemon) registerConnections() {
	On(d, wire.CallConnectionsList, func(ctx context.Context, c *Client, _ wire.Empty) (wire.ConnectionsList, error) {
		return d.connectionsList()
	})
	On(d, wire.CallConnectionsSignIn, func(ctx context.Context, c *Client, r wire.ConnectionProviderRequest) (wire.ConnectionSignIn, error) {
		return d.connectionSignIn(ctx, r.Provider)
	})
	On(d, wire.CallConnectionsSignInWait, func(ctx context.Context, c *Client, r wire.ConnectionSignInFlowRequest) (wire.ConnectionSignIn, error) {
		return d.connectionSignInWait(ctx, r.FlowID)
	})
	On(d, wire.CallConnectionsSignInCancel, func(ctx context.Context, c *Client, r wire.ConnectionSignInFlowRequest) (wire.ConnectionSignIn, error) {
		f := d.connectionFlowNamed(r.FlowID)
		if f == nil {
			return wire.ConnectionSignIn{}, invalid("There is no such sign-in.")
		}
		f.end(wire.ConnectionSignInStatusCancelled, nil, "")
		f.cancel()
		state, _ := f.snapshot()
		return state, nil
	})
	On(d, wire.CallConnectionsDisconnect, func(ctx context.Context, c *Client, r wire.ConnectionProviderRequest) (wire.ConnectionDisconnectAnswer, error) {
		if !knownProvider(r.Provider) {
			return wire.ConnectionDisconnectAnswer{}, invalid("Agents does not connect to " + string(r.Provider) + ".")
		}
		s, err := d.connectionStore()
		if err == nil {
			d.connRenew.Lock()
			err = s.Delete(string(r.Provider))
			d.connRenew.Unlock()
		}
		if err != nil {
			log.Printf("connections: %s disconnect failed", r.Provider)
			why := err.Error()
			return wire.ConnectionDisconnectAnswer{Error: &why}, nil
		}
		log.Printf("connections: %s disconnected", r.Provider)
		return wire.ConnectionDisconnectAnswer{}, nil
	})
}

func knownProvider(p wire.ConnectionProvider) bool { return p == wire.ConnectionProviderGithub }

// connectionLocator is this host's store, for the person whose home is personalHome.
func (d *Daemon) connectionLocator() connections.Locator {
	return connections.ForHost(d.Store.Loc.Root, d.personalHome())
}

func (d *Daemon) connectionStore() (connections.Store, error) {
	if d.connStoreFor != nil {
		return d.connStoreFor()
	}
	if goruntime.GOOS != "darwin" && d.personalHome() == "" {
		return nil, invalid("This host has no home folder to keep connections in.")
	}
	return connections.Open(d.connectionLocator())
}

func (d *Daemon) deviceFlow(p wire.ConnectionProvider) *connections.DeviceFlow {
	if d.newDeviceFlow != nil {
		return d.newDeviceFlow(p)
	}
	return connections.NewGitHubFlow()
}

func wireConnection(c connections.Connection) wire.Connection {
	w := wire.Connection{Provider: wire.ConnectionProvider(c.Provider), State: wire.ConnectionStateConnected,
		ConnectedAt: wire.DateOf(c.ConnectedAt)}
	if c.SignInAgain {
		w.State = wire.ConnectionStateSignInAgain
	}
	if c.Login != "" {
		w.Login = &c.Login
	}
	if c.Provider == connections.GitHub {
		install := connections.GitHubInstallURL
		w.InstallURL = &install
	}
	return w
}

func (d *Daemon) connectionsList() (wire.ConnectionsList, error) {
	s, err := d.connectionStore()
	if err != nil {
		return wire.ConnectionsList{}, err
	}
	all, err := connections.List(s)
	if err != nil {
		return wire.ConnectionsList{}, err
	}
	out := wire.ConnectionsList{Connections: []wire.Connection{}}
	for _, c := range all {
		out.Connections = append(out.Connections, wireConnection(c))
	}
	return out, nil
}

func (d *Daemon) connectionFlowNamed(id wire.UUID) *connectionFlow {
	d.connMu.Lock()
	defer d.connMu.Unlock()
	return d.connFlows[id]
}

// connectionSignIn starts the device flow, or answers with the one already waiting for
// the provider, so two clients show the same code.
func (d *Daemon) connectionSignIn(ctx context.Context, p wire.ConnectionProvider) (wire.ConnectionSignIn, error) {
	if !knownProvider(p) {
		return wire.ConnectionSignIn{}, invalid("Agents does not connect to " + string(p) + ".")
	}
	s, err := d.connectionStore()
	if err != nil {
		return wire.ConnectionSignIn{}, err
	}
	d.connMu.Lock()
	if d.connFlows == nil {
		d.connFlows = map[wire.UUID]*connectionFlow{}
	}
	for id, f := range d.connFlows {
		state, _ := f.snapshot()
		f.mu.Lock()
		ended := f.endedAt
		f.mu.Unlock()
		if state.Status == wire.ConnectionSignInStatusWaiting && state.Provider == p && time.Now().Before(state.ExpiresAt.Time()) {
			d.connMu.Unlock()
			return state, nil
		}
		if !ended.IsZero() && time.Since(ended) > connectionFlowKept {
			delete(d.connFlows, id)
		}
	}
	d.connMu.Unlock()

	flow := d.deviceFlow(p)
	code, err := flow.Start(ctx)
	if err != nil {
		log.Printf("connections: %s sign-in did not start", p)
		return wire.ConnectionSignIn{}, invalid("The sign-in could not start: " + err.Error())
	}
	install := connections.GitHubInstallURL
	f := &connectionFlow{changed: make(chan struct{}), state: wire.ConnectionSignIn{
		FlowID: store.NewUUID(), Provider: p, Status: wire.ConnectionSignInStatusWaiting,
		UserCode: code.UserCode, VerificationURL: code.VerificationURL, InstallURL: &install,
		ExpiresAt: wire.DateOf(code.ExpiresAt)}}
	run, cancel := context.WithDeadline(d.ctx, code.ExpiresAt.Add(time.Minute))
	f.cancel = cancel
	d.connMu.Lock()
	d.connFlows[f.state.FlowID] = f
	d.connMu.Unlock()
	log.Printf("connections: %s sign-in started", p)
	safe.Go("connection sign-in", func() {
		defer cancel()
		d.finishConnection(run, f, flow, s, code)
	})
	state, _ := f.snapshot()
	return state, nil
}

func (d *Daemon) finishConnection(ctx context.Context, f *connectionFlow, flow *connections.DeviceFlow, s connections.Store, code connections.DeviceCode) {
	p := f.state.Provider
	t, err := flow.Wait(ctx, code)
	switch {
	case errors.Is(err, connections.ErrExpired):
		log.Printf("connections: %s sign-in expired", p)
		f.end(wire.ConnectionSignInStatusExpired, nil, "The code expired before it was approved. Sign in again.")
		return
	case errors.Is(err, connections.ErrDenied):
		log.Printf("connections: %s sign-in denied", p)
		f.end(wire.ConnectionSignInStatusDenied, nil, "The sign-in was cancelled on GitHub.")
		return
	case err != nil:
		if ctx.Err() == nil {
			log.Printf("connections: %s sign-in failed", p)
		}
		f.end(wire.ConnectionSignInStatusFailed, nil, err.Error())
		return
	}
	login, err := flow.Login(ctx, t.Access)
	if err != nil {
		log.Printf("connections: %s account not read", p)
		f.end(wire.ConnectionSignInStatusFailed, nil, err.Error())
		return
	}
	c := t.Connection(string(p), login, time.Now())
	d.connRenew.Lock()
	err = s.Put(c)
	d.connRenew.Unlock()
	if err != nil {
		log.Printf("connections: %s not kept", p)
		f.end(wire.ConnectionSignInStatusFailed, nil, err.Error())
		return
	}
	log.Printf("connections: %s connected", p)
	w := wireConnection(c)
	f.end(wire.ConnectionSignInStatusConnected, &w, "")
}

// connectionSignInWait answers when the sign-in has ended, or after one long poll.
func (d *Daemon) connectionSignInWait(ctx context.Context, id wire.UUID) (wire.ConnectionSignIn, error) {
	f := d.connectionFlowNamed(id)
	if f == nil {
		return wire.ConnectionSignIn{}, invalid("There is no such sign-in.")
	}
	state, changed := f.snapshot()
	if state.Status != wire.ConnectionSignInStatusWaiting {
		return state, nil
	}
	t := time.NewTimer(connectionWaitLimit)
	defer t.Stop()
	select {
	case <-changed:
	case <-t.C:
	case <-ctx.Done():
	}
	state, _ = f.snapshot()
	return state, nil
}

// StartConnections tells every process this host starts where its store is (a locator,
// never a secret), and renews each connection before its token ends.
func (d *Daemon) StartConnections() {
	_ = os.Setenv(connections.EnvName, string(d.connectionLocator()))
	safe.Go("connections", d.connectionClock)
}

func (d *Daemon) connectionClock() {
	d.renewConnections()
	t := time.NewTicker(time.Minute)
	defer t.Stop()
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-t.C:
			d.renewConnections()
		}
	}
}

func (d *Daemon) renewConnections() {
	s, err := d.connectionStore()
	if err != nil {
		return
	}
	d.connRenew.Lock()
	defer d.connRenew.Unlock()
	for _, p := range connections.Providers {
		ctx, cancel := context.WithTimeout(d.ctx, 30*time.Second)
		result, err := connections.RefreshIfDue(ctx, s, d.deviceFlow(wire.ConnectionProvider(p)), p, time.Now())
		cancel()
		switch {
		case result == connections.Renewed:
			log.Printf("connections: %s renewed", p)
		case result == connections.Refused:
			log.Printf("connections: %s refused the renewal: sign in again", p)
		case err != nil:
			log.Printf("connections: %s renewal failed", p)
		}
	}
}
