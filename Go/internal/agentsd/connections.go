package agentsd

import (
	"context"
	"crypto/subtle"
	"errors"
	"log"
	"net"
	"net/http"
	"os"
	goruntime "runtime"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/internal/emailmcp"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Connections (#1335): the person's sign-ins to tools, kept by this host. A client starts a
// sign-in (connections/sign-in), shows the code and the links, and waits
// (connections/sign-in/wait); the host polls GitHub, keeps the tokens in its own store
// (connections.ForHost) and renews them before they end. A client is told the account and
// the state, never a token. Logged: the provider and what happened, in a word.
//
// Linear (#1343) has no device flow: its grant is the authorization code with PKCE. The host
// makes the verifier and the state and keeps them; the client opens the authorize address,
// the hand-back page (connections.HandBackURL) gives the code and the state back to it, and
// it gives them to the host (connections/sign-in/complete), which checks the state and
// spends the code.
//
// GitLab (#1630) signs in by the device flow on gitlab.com, as GitHub does, or by a personal
// access token on any GitLab (connections/sign-in/token): the host checks the token with that
// GitLab and keeps it with the GitLab's address. It has no refresh: the row says when it ends.
//
// Email (#1780) has no sign-in page: the person gives an IMAP server, a user and an app
// password (connections/sign-in/email). The host signs in once to check them, and keeps them
// for the email server. An app password does not end.

var (
	// connectionWaitLimit is one long poll of connections/sign-in/wait.
	connectionWaitLimit = 25 * time.Second
	// connectionFlowKept is how long an ended sign-in can still be read.
	connectionFlowKept = 10 * time.Minute
	// codeFlowLimit is how long the person has to approve a code-flow sign-in.
	codeFlowLimit = 10 * time.Minute
)

type connectionBook struct {
	connMu    sync.Mutex
	connFlows map[wire.UUID]*connectionFlow
	// connRenew is one renewal at a time: a refresh token is single use.
	connRenew sync.Mutex
	// newDeviceFlow is the provider's flow; a test gives a fake GitHub.
	newDeviceFlow func(provider wire.ConnectionProvider) *connections.DeviceFlow
	// newCodeFlow is a code-flow provider's flow; a test gives a fake Linear.
	newCodeFlow func(provider wire.ConnectionProvider) *connections.CodeFlow
	// connStoreFor is the host's store; a test gives a file.
	connStoreFor func() (connections.Store, error)
	// gitlabHTTP checks a GitLab access token; a test gives a fake GitLab's client.
	gitlabHTTP *http.Client
	// emailCheck signs in to an IMAP server once; emailmcp.Check when nil.
	emailCheck func(context.Context, emailmcp.Account) error
}

// connectionFlow is one sign-in under way, read by every client that waits on it.
type connectionFlow struct {
	mu      sync.Mutex
	state   wire.ConnectionSignIn
	changed chan struct{} // closed and replaced at each change
	cancel  context.CancelFunc
	endedAt time.Time
	// The code flow's own: the PKCE secrets (never sent to a client), the page's origin,
	// and the flow that spends the code. completing is set while a code is being spent.
	pkce       connections.PKCE
	origin     string
	code       *connections.CodeFlow
	store      connections.Store
	completing bool
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
		return d.connectionSignIn(ctx, r.Provider, deref(r.Origin))
	})
	On(d, wire.CallConnectionsSignInWait, func(ctx context.Context, c *Client, r wire.ConnectionSignInFlowRequest) (wire.ConnectionSignIn, error) {
		return d.connectionSignInWait(ctx, r.FlowID)
	})
	On(d, wire.CallConnectionsSignInComplete, func(ctx context.Context, c *Client, r wire.ConnectionSignInCompleteRequest) (wire.ConnectionSignIn, error) {
		return d.connectionSignInComplete(ctx, r)
	})
	On(d, wire.CallConnectionsSignInToken, func(ctx context.Context, c *Client, r wire.ConnectionTokenRequest) (wire.ConnectionTokenAnswer, error) {
		return d.connectionSignInToken(ctx, r)
	})
	On(d, wire.CallConnectionsSignInEmail, func(ctx context.Context, c *Client, r wire.ConnectionEmailRequest) (wire.ConnectionTokenAnswer, error) {
		return d.connectionSignInEmail(ctx, r)
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

func knownProvider(p wire.ConnectionProvider) bool {
	return p == wire.ConnectionProviderGithub || p == wire.ConnectionProviderLinear || p == wire.ConnectionProviderGitlab ||
		p == wire.ConnectionProviderEmail
}

// connectionLocator is this host's store, for the person whose home is personalHome.
func (d *Daemon) connectionLocator() connections.Locator {
	return connections.ForHost(d.Store.Loc.Root, d.personalHome())
}

func (d *Daemon) connectionStore() (connections.Store, error) {
	if d.connStoreFor != nil {
		return d.connStoreFor()
	}
	if goruntime.GOOS != "darwin" && d.personalHome() == "" {
		return nil, invalid("This machine has no home folder to keep connections in.")
	}
	return connections.Open(d.connectionLocator())
}

func (d *Daemon) deviceFlow(p wire.ConnectionProvider) *connections.DeviceFlow {
	if d.newDeviceFlow != nil {
		return d.newDeviceFlow(p)
	}
	if p == wire.ConnectionProviderGitlab {
		return connections.NewGitLabFlow()
	}
	return connections.NewGitHubFlow()
}

func (d *Daemon) codeFlow(p wire.ConnectionProvider) *connections.CodeFlow {
	if d.newCodeFlow != nil {
		return d.newCodeFlow(p)
	}
	return connections.NewLinearFlow()
}

// refresher is the flow that renews provider's tokens.
func (d *Daemon) refresher(provider string) connections.Refresher {
	if provider == connections.Linear {
		return d.codeFlow(wire.ConnectionProvider(provider))
	}
	return d.deviceFlow(wire.ConnectionProvider(provider))
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
	if c.Workspace != "" {
		w.Workspace = &c.Workspace
	}
	if c.Provider == connections.GitHub {
		install := connections.GitHubInstallURL
		w.InstallURL = &install
	}
	if c.Refresh == "" && !c.AccessExpiresAt.IsZero() {
		w.ExpiresAt = new(wire.DateOf(c.AccessExpiresAt))
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
// the provider, so two clients show the same code. A code flow (Linear) is shared only by
// clients that hand back the same way: the Mac and the Remote, or one web page's origin.
func (d *Daemon) connectionSignIn(ctx context.Context, p wire.ConnectionProvider, origin string) (wire.ConnectionSignIn, error) {
	if !knownProvider(p) {
		return wire.ConnectionSignIn{}, invalid("Agents does not connect to " + string(p) + ".")
	}
	if p == wire.ConnectionProviderEmail {
		return wire.ConnectionSignIn{}, invalid("Email has no sign-in page: connect it with its IMAP server, user and app password.")
	}
	if origin != "" {
		o, err := connections.CleanOrigin(origin)
		if err != nil {
			return wire.ConnectionSignIn{}, invalid("The sign-in could not start: " + err.Error() + ".")
		}
		origin = o
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
		if state.Status == wire.ConnectionSignInStatusWaiting && state.Provider == p && (f.code == nil || f.origin == origin) &&
			time.Now().Before(state.ExpiresAt.Time()) {
			d.connMu.Unlock()
			return state, nil
		}
		if !ended.IsZero() && time.Since(ended) > connectionFlowKept {
			delete(d.connFlows, id)
		}
	}
	d.connMu.Unlock()
	if p == wire.ConnectionProviderLinear {
		return d.startCodeFlow(p, origin, s)
	}

	flow := d.deviceFlow(p)
	if flow.ClientID == "" {
		return wire.ConnectionSignIn{}, invalid("This build has no Agents application on " + flow.Name + ": connect with a personal access token.")
	}
	code, err := flow.Start(ctx)
	if err != nil {
		log.Printf("connections: %s sign-in did not start", p)
		return wire.ConnectionSignIn{}, invalid("The sign-in could not start: " + err.Error())
	}
	f := &connectionFlow{changed: make(chan struct{}), state: wire.ConnectionSignIn{
		FlowID: store.NewUUID(), Provider: p, Status: wire.ConnectionSignInStatusWaiting,
		Grant: wire.ConnectionSignInGrantDeviceCode, UserCode: &code.UserCode, VerificationURL: code.VerificationURL,
		ExpiresAt: wire.DateOf(code.ExpiresAt)}}
	if p == wire.ConnectionProviderGithub {
		install := connections.GitHubInstallURL
		f.state.InstallURL = &install
	}
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
		f.end(wire.ConnectionSignInStatusDenied, nil, "The sign-in was cancelled on "+flow.Name+".")
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

// startCodeFlow makes the PKCE secrets and the authorize address, and ends the sign-in as
// expired when nobody completes it in time.
func (d *Daemon) startCodeFlow(p wire.ConnectionProvider, origin string, s connections.Store) (wire.ConnectionSignIn, error) {
	flow := d.codeFlow(p)
	pkce, err := connections.NewPKCE(origin)
	if err != nil {
		return wire.ConnectionSignIn{}, invalid("The sign-in could not start: " + err.Error() + ".")
	}
	expires := time.Now().Add(codeFlowLimit)
	f := &connectionFlow{changed: make(chan struct{}), pkce: pkce, origin: origin, code: flow, store: s,
		state: wire.ConnectionSignIn{FlowID: store.NewUUID(), Provider: p, Status: wire.ConnectionSignInStatusWaiting,
			Grant: wire.ConnectionSignInGrantAuthorizationCode, VerificationURL: flow.AuthorizeURL(pkce),
			ExpiresAt: wire.DateOf(expires)}}
	run, cancel := context.WithDeadline(d.ctx, expires)
	f.cancel = cancel
	d.connMu.Lock()
	d.connFlows[f.state.FlowID] = f
	d.connMu.Unlock()
	log.Printf("connections: %s sign-in started", p)
	safe.Go("connection sign-in", func() {
		<-run.Done()
		if d.ctx.Err() == nil && errors.Is(run.Err(), context.DeadlineExceeded) {
			f.mu.Lock()
			busy := f.completing
			f.mu.Unlock()
			if !busy {
				f.end(wire.ConnectionSignInStatusExpired, nil, "The sign-in ended before it was approved. Sign in again.")
			}
		}
	})
	state, _ := f.snapshot()
	return state, nil
}

// connectionSignInComplete spends the code the hand-back page gave a client, once the state
// is the flow's own. A flow that has already ended answers with how it ended.
func (d *Daemon) connectionSignInComplete(ctx context.Context, r wire.ConnectionSignInCompleteRequest) (wire.ConnectionSignIn, error) {
	f := d.connectionFlowNamed(r.FlowID)
	if f == nil || f.code == nil {
		return wire.ConnectionSignIn{}, invalid("There is no such sign-in.")
	}
	f.mu.Lock()
	if f.state.Status != wire.ConnectionSignInStatusWaiting || f.completing {
		f.mu.Unlock()
		state, _ := f.snapshot()
		return state, nil
	}
	if subtle.ConstantTimeCompare([]byte(r.State), []byte(f.pkce.State)) != 1 {
		f.mu.Unlock()
		log.Printf("connections: %s sign-in came back with another state", f.state.Provider)
		return wire.ConnectionSignIn{}, invalid("The sign-in came back for another request. Sign in again.")
	}
	f.completing = true
	f.mu.Unlock()
	p := f.state.Provider
	name := f.code.Name
	defer f.cancel()
	switch {
	case deref(r.Error) == "access_denied":
		log.Printf("connections: %s sign-in denied", p)
		f.end(wire.ConnectionSignInStatusDenied, nil, "The sign-in was cancelled on "+name+".")
	case deref(r.Error) != "" || deref(r.Code) == "":
		log.Printf("connections: %s sign-in failed", p)
		why := name + " gave no code."
		if e := deref(r.Error); e != "" {
			why = name + " said " + e + "."
		}
		f.end(wire.ConnectionSignInStatusFailed, nil, why)
	default:
		d.spendCode(ctx, f, *r.Code)
	}
	state, _ := f.snapshot()
	return state, nil
}

func (d *Daemon) spendCode(ctx context.Context, f *connectionFlow, code string) {
	p := f.state.Provider
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	t, err := f.code.Exchange(ctx, code, f.pkce.Verifier)
	if err != nil {
		log.Printf("connections: %s code not spent", p)
		f.end(wire.ConnectionSignInStatusFailed, nil, err.Error())
		return
	}
	login, workspace, err := f.code.Account(ctx, t.Access)
	if err != nil {
		log.Printf("connections: %s account not read", p)
		f.end(wire.ConnectionSignInStatusFailed, nil, err.Error())
		return
	}
	c := t.Connection(string(p), login, time.Now())
	c.Workspace = workspace
	d.connRenew.Lock()
	err = f.store.Put(c)
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

// connectionSignInToken checks a personal access token with the GitLab at r.URL and keeps it.
// The token is in no log and no answer; a failure says what failed, in words.
func (d *Daemon) connectionSignInToken(ctx context.Context, r wire.ConnectionTokenRequest) (wire.ConnectionTokenAnswer, error) {
	if r.Provider != wire.ConnectionProviderGitlab {
		return wire.ConnectionTokenAnswer{}, invalid("Agents takes an access token only for GitLab.")
	}
	fail := func(why string) (wire.ConnectionTokenAnswer, error) {
		log.Printf("connections: %s token not taken", r.Provider)
		return wire.ConnectionTokenAnswer{Error: &why}, nil
	}
	token := strings.TrimSpace(r.Token)
	if token == "" || strings.ContainsAny(token, " \t\r\n") {
		return fail("Paste the access token: one word, such as glpat-….")
	}
	root, err := connections.GitLabRoot(deref(r.URL))
	if err != nil {
		return fail(sentence(err.Error()))
	}
	s, err := d.connectionStore()
	if err != nil {
		return wire.ConnectionTokenAnswer{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	client := d.gitlabHTTP
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	t, err := connections.CheckGitLabToken(ctx, client, root, token)
	if err != nil {
		return fail(sentence(err.Error()))
	}
	c := connections.GitLabConnection(root, token, t, time.Now())
	d.connRenew.Lock()
	err = s.Put(c)
	d.connRenew.Unlock()
	if err != nil {
		return fail(sentence(err.Error()))
	}
	log.Printf("connections: %s connected with a token", r.Provider)
	w := wireConnection(c)
	return wire.ConnectionTokenAnswer{Connection: &w}, nil
}

// connectionSignInEmail signs in to the IMAP server once with r's user and app password, and
// keeps them. The password is in no log and no answer; a failure says what failed, in words.
func (d *Daemon) connectionSignInEmail(ctx context.Context, r wire.ConnectionEmailRequest) (wire.ConnectionTokenAnswer, error) {
	fail := func(why string) (wire.ConnectionTokenAnswer, error) {
		log.Printf("connections: email not connected")
		return wire.ConnectionTokenAnswer{Error: &why}, nil
	}
	user, password := strings.TrimSpace(r.User), strings.TrimSpace(r.Password)
	if user == "" || strings.ContainsAny(user, " \t\r\n") {
		return fail("Give the user to sign in as: usually the mail address.")
	}
	if password == "" {
		return fail("Paste the app password you made for Agents.")
	}
	address, security, err := emailmcp.ParseServer(r.Server)
	if err != nil {
		return fail(sentence(err.Error()))
	}
	s, err := d.connectionStore()
	if err != nil {
		return wire.ConnectionTokenAnswer{}, err
	}
	account := emailmcp.Account{Address: address, Security: security, User: user, Password: password}
	check := d.emailCheck
	if check == nil {
		check = emailmcp.Check
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err := check(ctx, account); err != nil {
		return fail(sentence(err.Error()))
	}
	host, _, _ := net.SplitHostPort(address)
	c := connections.EmailConnection(emailmcp.ServerURL(address, security), host, user, password, time.Now())
	d.connRenew.Lock()
	err = s.Put(c)
	d.connRenew.Unlock()
	if err != nil {
		return fail(sentence(err.Error()))
	}
	log.Printf("connections: email connected")
	w := wireConnection(c)
	return wire.ConnectionTokenAnswer{Connection: &w}, nil
}

// sentence is words with a capital and a full stop.
func sentence(words string) string {
	if words == "" {
		return words
	}
	words = strings.ToUpper(words[:1]) + words[1:]
	if !strings.HasSuffix(words, ".") {
		words += "."
	}
	return words
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
		result, err := connections.RefreshIfDue(ctx, s, d.refresher(p), p, time.Now())
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
