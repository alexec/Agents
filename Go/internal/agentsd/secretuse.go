package agentsd

import (
	"context"
	"errors"
	"log"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Ask before use (#4015, the spike #4013): each use of a flagged secret waits on a person.
// The uses are only agentsd's own: fill_secret types the value into a page, set_ci_secret
// sends it to GitHub, and an HTTP MCP server's ${NAME} is filled on each request agentsd
// sends the server for a session (secretproxy.go, #4120). A use is a Needs you request of
// kind approve that names the secret, the session and the place (the field's domain,
// owner/repo, the server's name), never the value. A tool's call is held as ask_question's
// is (formHoldLimit); after the hold the agent waits on the request with wait_for_event and
// calls again. An MCP server's request is never held: a start never waits on a person.
//
// The answers:
//
//   - once: this use, and no other;
//   - session: every use at this place by this session, until it is archived or agentsd
//     restarts;
//   - always: a grant for this place, for every session, kept in the sealed record, so a
//     grant added by hand does not open (sealedSecretAD);
//   - deny: the call fails with words that say a person denied it.
//
// Only the control and device roles answer, or add and remove a grant (askBeforeUseAllowed).
// The machine lock checks that an answer through the control plane comes from a client of
// the person's lock (lockcheck.go). On Linux an answer that allows a use is also signed by
// the answering client, and the control plane releases the value's key only for it
// (#4058, secretrelease.go).

// Answers to a secret's use.
const (
	secretUseOnce    = "once"
	secretUseSession = "session"
	secretUseAlways  = "always"
	secretUseDeny    = "deny"
)

type secretUseState struct {
	secretUseMu sync.Mutex
	// secretUseHeld is each call held on a request, by the request's id: it hears the answer.
	secretUseHeld map[wire.UUID]chan string
	// secretUseOnce counts the uses a person allowed once, and secretUseSession the places
	// allowed for a session, both by secretUseKey. In memory only: a restart asks again.
	secretUseOnceLeft map[string]int
	secretUseSessions map[string]bool
}

// secretUseKey is one session's use of one secret at one place.
func secretUseKey(agent wire.UUID, name string, use wire.SecretUse, place string) string {
	return string(sessionKey(agent)) + "|" + name + "|" + grantPlace(use, place)
}

// grantPlace is a place as the sealed record keeps it: fill:<domain>, ci:<owner/repo>,
// mcp:<server>.
func grantPlace(use wire.SecretUse, place string) string { return string(use) + ":" + place }

// secretUseWords are what an agent reads when its use of a secret waits, or was refused.
func secretUseWords(r wire.RequestSecretUse, id wire.UUID) string {
	if r.Use == wire.SecretUseMCP {
		return "Nothing was sent to the MCP server " + r.Place + ": " + r.Name + " has Ask before use, and a person has not yet approved its use there. " +
			"Wait with wait_for_event, where: {\"request\": \"" + string(id) + "\"}: once they allow it, the server connects from your next turn."
	}
	what := map[wire.SecretUse]string{wire.SecretUseFill: "fill_secret", wire.SecretUseCi: "set_ci_secret"}[r.Use]
	return "Nothing was used yet: " + r.Name + " has Ask before use, and a person has not yet approved its use at " + r.Place +
		". Wait with wait_for_event, where: {\"request\": \"" + string(id) + "\"}, then call " + what + " again."
}

// errSecretUseDenied is a use a person denied, or whose request was dropped.
type errSecretUseDenied struct{ name, place string }

func (e errSecretUseDenied) Error() string {
	return "A person denied the use of " + e.name + " at " + e.place + ". Do not ask again; carry on without it, or say what you cannot do without it."
}

// approveSecretUse is whether agent may use the flagged secret name at place now. It is
// "" when it may; the words to give the agent when the request is still open; or an
// errSecretUseDenied.
func (d *Daemon) approveSecretUse(agent wire.UUID, name string, use wire.SecretUse, place string) (string, error) {
	return d.askSecretUse(agent, name, use, place, formHoldLimit)
}

// askSecretUse is approveSecretUse, the call held up to hold on its request: none at all
// for an MCP server's request.
func (d *Daemon) askSecretUse(agent wire.UUID, name string, use wire.SecretUse, place string, hold time.Duration) (string, error) {
	// A domain and a GitHub repo are the same in any case.
	place = strings.ToLower(strings.TrimSpace(place))
	if place == "" {
		return "", errors.New("nothing names where " + name + " would go, so no person can approve it")
	}
	if d.secretUseAllowed(agent, name, use, place) {
		return "", nil
	}
	ask := wire.RequestSecretUse{Name: name, Use: use, Place: place}
	if d.isSessionSecret(agent, name) {
		ask.SessionOnly = new(true)
	}
	if d.needsRelease(agent, name) {
		ask.NeedsSignature = new(true)
	}
	id, ok := d.openSecretUseRequest(agent, ask)
	if !ok {
		return "", errors.New("this session cannot ask a person now")
	}
	held := make(chan string, 1)
	d.secretUseMu.Lock()
	if d.secretUseHeld == nil {
		d.secretUseHeld = map[wire.UUID]chan string{}
	}
	d.secretUseHeld[id] = held
	d.secretUseMu.Unlock()
	defer func() {
		d.secretUseMu.Lock()
		delete(d.secretUseHeld, id)
		d.secretUseMu.Unlock()
	}()
	// Answered before the hold began (a request this session opened before).
	if rec := d.request(id); rec != nil && rec.State != wire.RequestStateOpen {
		return d.afterSecretUse(agent, ask, id)
	}
	if hold <= 0 {
		return secretUseWords(ask, id), nil
	}
	timer := time.NewTimer(hold)
	defer timer.Stop()
	select {
	case <-held:
		return d.afterSecretUse(agent, ask, id)
	case <-timer.C:
		return secretUseWords(ask, id), nil
	case <-d.ctx.Done():
		return secretUseWords(ask, id), nil
	}
}

// afterSecretUse is the held call once its request ended.
func (d *Daemon) afterSecretUse(agent wire.UUID, ask wire.RequestSecretUse, id wire.UUID) (string, error) {
	if d.secretUseAllowed(agent, ask.Name, ask.Use, ask.Place) {
		return "", nil
	}
	if rec := d.request(id); rec != nil && rec.State == wire.RequestStateOpen {
		return secretUseWords(ask, id), nil
	}
	return "", errSecretUseDenied{ask.Name, ask.Place}
}

// secretUseAllowed is whether a person allowed this use already: a grant, this session's,
// or once (which this use takes).
func (d *Daemon) secretUseAllowed(agent wire.UUID, name string, use wire.SecretUse, place string) bool {
	if a := d.Store.Agent(agent); a == nil || a.State == wire.AgentStateArchived {
		return false
	}
	key := secretUseKey(agent, name, use, place)
	d.secretUseMu.Lock()
	if d.secretUseSessions[key] {
		d.secretUseMu.Unlock()
		return true
	}
	if d.secretUseOnceLeft[key] > 0 {
		d.secretUseOnceLeft[key]--
		if d.secretUseOnceLeft[key] == 0 {
			delete(d.secretUseOnceLeft, key)
		}
		d.secretUseMu.Unlock()
		return true
	}
	d.secretUseMu.Unlock()
	if d.isSessionSecret(agent, name) {
		return false
	}
	home := d.personalHome()
	if home == "" {
		return false
	}
	// A grant counts only in a record that opens: one added by hand does not
	// (sealedSecretAD binds the grants).
	s, ok := readSealedSecrets(home).Secrets[name]
	if !ok || !slices.Contains(s.Grants, grantPlace(use, place)) {
		return false
	}
	_, err := d.openSealedSecret(sealedLocal, name, s)
	return err == nil
}

// isSessionSecret is whether name is the session's own (#3548), not this machine's.
func (d *Daemon) isSessionSecret(agent wire.UUID, name string) bool {
	_, ok := d.readSessionSecrets(agent).Secrets[name]
	return ok
}

// openSecretUseRequest is the open request for this use: the one the session opened
// before, when it is still open, so a call made again does not ask twice.
func (d *Daemon) openSecretUseRequest(agent wire.UUID, ask wire.RequestSecretUse) (wire.UUID, bool) {
	a := d.Store.Agent(agent)
	if a == nil || a.State == wire.AgentStateArchived {
		return "", false
	}
	d.requests.mu.Lock()
	for _, r := range d.requests.byID {
		if s := r.Detail.SecretUse; s != nil && r.State == wire.RequestStateOpen && r.AskedBy != nil &&
			sessionKey(*r.AskedBy) == sessionKey(agent) && s.Name == ask.Name && s.Use == ask.Use && s.Place == ask.Place {
			id := r.ID
			d.requests.mu.Unlock()
			return id, true
		}
	}
	at := now()
	asker := agent
	title := map[wire.SecretUse]string{wire.SecretUseFill: "Fill " + ask.Name + " on " + ask.Place,
		wire.SecretUseCi:  "Set " + ask.Name + " as a CI secret in " + ask.Place,
		wire.SecretUseMCP: "Send " + ask.Name + " to the MCP server " + ask.Place}[ask.Use]
	r := &wire.Request{ID: store.NewUUID(), Kind: wire.RequestKindApprove, Source: wire.RequestSourceSecretUse,
		State: wire.RequestStateOpen, Title: title, Detail: wire.RequestDetail{SecretUse: &ask},
		Folder: string(store.FolderURL(folderPath(a))), AskedBy: &asker,
		Waiters: []wire.RequestWaiter{{Agent: asker, Since: at}}, AskedAt: at}
	if d.requests.byID == nil {
		d.requests.byID = map[wire.UUID]*wire.Request{}
	}
	d.requests.byID[r.ID] = r
	d.saveRequestLocked(r)
	c := copyRequest(r)
	d.requests.mu.Unlock()
	log.Printf("secret use: %s asks to use %s at %s", agent, ask.Name, grantPlace(ask.Use, ask.Place))
	Broadcast(d, wire.NotifyRequestsChanged, wire.RequestUpdate{Request: c})
	d.raiseRequestEvent("request.opened", c, nil, nil)
	d.reconsider() // its banner (#4017)
	return r.ID, true
}

// answerSecretUse is requests/answer for a secret's use: it keeps what the person allowed,
// ends the request, and wakes the call held on it.
func (d *Daemon) answerSecretUse(rec wire.Request, a *wire.RequestSecretUseAnswer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	if a == nil {
		return wire.RequestUpdate{}, Invalid("This request takes a secretUse answer: once, session, always or deny.")
	}
	ask := *rec.Detail.SecretUse
	if ask.Use == wire.SecretUseTerminal {
		return d.answerTerminalUse(rec, a, by)
	}
	if a.Action == secretUseHour {
		return wire.RequestUpdate{}, Invalid("Allow for 1 Hour is for a terminal's request; this one takes once, session, always or deny.")
	}
	if rec.AskedBy == nil {
		return wire.RequestUpdate{}, Invalid("This request has no session.")
	}
	agent := *rec.AskedBy
	key := secretUseKey(agent, ask.Name, ask.Use, ask.Place)
	summary := map[string]string{secretUseOnce: "Allowed once", secretUseSession: "Allowed for this session",
		secretUseAlways: "Allowed always at " + ask.Place, secretUseDeny: "Denied"}[a.Action]
	if summary == "" {
		return wire.RequestUpdate{}, Invalid("The answer is once, session, always or deny.")
	}
	if a.Action != secretUseDeny {
		if err := d.releaseForAnswer(rec, a); err != nil {
			return wire.RequestUpdate{}, err
		}
	}
	always := a.Action == secretUseAlways && !d.isSessionSecret(agent, ask.Name)
	if always {
		if err := d.changeGrant(ask.Name, ask.Use, ask.Place, true); err != nil {
			return wire.RequestUpdate{}, err
		}
	}
	d.secretUseMu.Lock()
	switch a.Action {
	case secretUseOnce:
		if d.secretUseOnceLeft == nil {
			d.secretUseOnceLeft = map[string]int{}
		}
		d.secretUseOnceLeft[key]++
	case secretUseSession, secretUseAlways:
		if !always {
			if d.secretUseSessions == nil {
				d.secretUseSessions = map[string]bool{}
			}
			d.secretUseSessions[key] = true
		}
	}
	d.secretUseMu.Unlock()
	if ask.Use == wire.SecretUseMCP {
		d.secretProxyAnswered(agent, ask, a.Action, always)
	}
	if a.Action == secretUseDeny {
		d.secretDenied(agent, ask.Name, ask.Use, ask.Place)
	}
	if !d.endRequest(rec.ID, wire.RequestStateAnswered, &summary, "", by) {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already."}
	}
	log.Printf("secret use: %s at %s for %s: %s", ask.Name, grantPlace(ask.Use, ask.Place), agent, a.Action)
	d.secretUseEnded(rec.ID)
	after := d.request(rec.ID)
	if after == nil {
		after = &rec
	}
	return wire.RequestUpdate{Request: *after}, nil
}

// secretUseEnded wakes the call held on a request that ended: answered or dropped.
func (d *Daemon) secretUseEnded(id wire.UUID) {
	d.terminalEnded(id)
	d.secretUseMu.Lock()
	held := d.secretUseHeld[id]
	d.secretUseMu.Unlock()
	if held != nil {
		select {
		case held <- "":
		default:
		}
	}
}

// forgetSessionSecretUses drops what a person allowed an archived session.
func (d *Daemon) forgetSessionSecretUses(agent wire.UUID) {
	d.forgetSecretProxy(agent)
	prefix := string(sessionKey(agent)) + "|"
	d.secretUseMu.Lock()
	defer d.secretUseMu.Unlock()
	for k := range d.secretUseSessions {
		if strings.HasPrefix(k, prefix) {
			delete(d.secretUseSessions, k)
		}
	}
	for k := range d.secretUseOnceLeft {
		if strings.HasPrefix(k, prefix) {
			delete(d.secretUseOnceLeft, k)
		}
	}
	d.forgetReleased(sealedSessionStore(agent))
}

// changeGrant adds or takes away a grant: the record is sealed again, with its grants in
// the associated data.
func (d *Daemon) changeGrant(name string, use wire.SecretUse, place string, add bool) error {
	home := d.personalHome()
	if home == "" {
		return Invalid("This machine has no personal home to keep secrets in.")
	}
	d.sealedSecretsMu.Lock()
	defer d.sealedSecretsMu.Unlock()
	f := readSealedSecrets(home)
	s, ok := f.Secrets[name]
	if !ok || s.NoAsk {
		return Invalid("%s does not have Ask before use on this machine.", name)
	}
	g := grantPlace(use, place)
	grants := slices.DeleteFunc(slices.Clone(s.Grants), func(x string) bool { return x == g })
	if add {
		grants = append(grants, g)
	}
	sealed, err := d.regrant(sealedLocal, name, s, grants)
	if err != nil {
		return Invalid("%s does not open on this machine, so its grants were left as they are.", name)
	}
	sealed.From, sealed.SetAt = s.From, s.SetAt
	f.Secrets[name] = sealed
	if err := writeSealedSecrets(home, f); err != nil {
		return Invalid("sealed.json could not be written.")
	}
	return nil
}

// secretGrants is secrets/grants: every grant of a record that opens.
func (d *Daemon) secretGrants() wire.SecretGrants {
	out := wire.SecretGrants{Grants: []wire.SecretGrant{}}
	home := d.personalHome()
	if home == "" {
		return out
	}
	f := readSealedSecrets(home)
	names := make([]string, 0, len(f.Secrets))
	for n := range f.Secrets {
		names = append(names, n)
	}
	slices.Sort(names)
	for _, n := range names {
		s := f.Secrets[n]
		if len(s.Grants) == 0 {
			continue
		}
		if _, err := d.openOuter(sealedLocal, n, s); err != nil {
			continue
		}
		for _, g := range s.Grants {
			use, place, ok := strings.Cut(g, ":")
			if ok {
				out.Grants = append(out.Grants, wire.SecretGrant{Name: n, Use: wire.SecretUse(use), Place: place})
			}
		}
	}
	return out
}

func validGrant(g wire.SecretGrant) error {
	if !secretAskName.MatchString(g.Name) {
		return Invalid("A secret's name is letters, digits and underscores, e.g. GITLAB_PASSWORD.")
	}
	if g.Use != wire.SecretUseFill && g.Use != wire.SecretUseCi && g.Use != wire.SecretUseMCP {
		return Invalid("A grant's use is fill, ci or mcp.")
	}
	if strings.TrimSpace(g.Place) == "" || strings.ContainsAny(g.Place, " \t\n") {
		return Invalid("A grant's place is a domain for a fill, owner/repo for CI, or the server's name for an MCP server.")
	}
	return nil
}

func (d *Daemon) registerSecretUse() {
	grant := func(add bool) func(context.Context, *Client, wire.SecretGrantChange) (wire.SecretGrants, error) {
		return func(_ context.Context, c *Client, r wire.SecretGrantChange) (wire.SecretGrants, error) {
			if !askBeforeUseAllowed(c) {
				return wire.SecretGrants{}, &Error{Code: CodeNotPermitted, Message: "Only a person's own client changes a secret's grants."}
			}
			g := r.Grant
			g.Name, g.Place = strings.TrimSpace(g.Name), strings.ToLower(strings.TrimSpace(g.Place))
			if err := validGrant(g); err != nil {
				return wire.SecretGrants{}, err
			}
			if err := d.changeGrant(g.Name, g.Use, g.Place, add); err != nil {
				return wire.SecretGrants{}, err
			}
			log.Printf("secret use: %s %s %s", g.Name, map[bool]string{true: "allowed always at", false: "no longer allowed at"}[add], grantPlace(g.Use, g.Place))
			return d.secretGrants(), nil
		}
	}
	On(d, wire.CallSecretsAddGrant, grant(true))
	On(d, wire.CallSecretsRemoveGrant, grant(false))
	On(d, wire.CallSecretsGrants, func(_ context.Context, c *Client, _ wire.Empty) (wire.SecretGrants, error) {
		if !askBeforeUseAllowed(c) {
			return wire.SecretGrants{}, &Error{Code: CodeNotPermitted, Message: "Only a person's own client reads a secret's grants."}
		}
		return d.secretGrants(), nil
	})
}
