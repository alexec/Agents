package agentsd

import (
	"log"
	"slices"
	"strings"

	"github.com/agentloops-dev/agents/Go/wire"
)

// Ask before use on an account (#4163): an agent's manage_accounts get of an account that asks
// waits on a person, as a secret's use does (secretuse.go): a Needs you request of kind approve,
// use account, that names the account, the session and the call, with the same answers. Once and
// For this session are kept in agentsd's memory, by the account's id; Always turns the account's
// Ask before use off, in the person's settings, so it is for every session. An account is not a
// secret, so the flag is not sealed: agentsd enforces it. list never waits: it shows only each
// account's id, service and description (#4164). An add of a new account does not wait, and asks
// before use; a replace waits on the person's Replace already (#4001), which counts.

// accountAsks is whether an account has Ask before use: absent is on.
func accountAsks(a wire.OutsideAccount) bool { return a.AskBeforeUse == nil || *a.AskBeforeUse }

// accountName is how a person's client names the account on its request: service and address.
func accountName(a wire.OutsideAccount) string {
	if a.Address != nil && strings.TrimSpace(*a.Address) != "" {
		return a.Service + " (" + *a.Address + ")"
	}
	return a.Service
}

// accountCall is the request's manage_accounts call: get, when it says none.
func accountCall(r wire.RequestSecretUse) string {
	if r.Call != nil && *r.Call != "" {
		return *r.Call
	}
	return "get"
}

// errAccountUseDenied is a read a person denied, or whose request was dropped.
type errAccountUseDenied struct{ name string }

func (e errAccountUseDenied) Error() string {
	return "A person denied your read of the account " + e.name + ". Do not ask again; carry on without it, or say what you cannot do without it."
}

// approveAccountUse is whether agent may make call on the account now: "" when it may; the
// words to give the agent when the request is still open; or an errAccountUseDenied.
func (d *Daemon) approveAccountUse(agent wire.UUID, a wire.OutsideAccount, call string) (string, error) {
	if !accountAsks(a) {
		return "", nil
	}
	ask := wire.RequestSecretUse{Name: accountName(a), Use: wire.SecretUseAccount, Place: accountID(a), Call: &call}
	if d.secretUseAllowed(agent, ask.Name, ask.Use, ask.Place) {
		return "", nil
	}
	return d.holdOnUse(agent, ask, formHoldLimit)
}

// answerAccountUse is requests/answer for an account's read: once, session, always or deny.
func (d *Daemon) answerAccountUse(rec wire.Request, a *wire.RequestSecretUseAnswer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	if rec.AskedBy == nil {
		return wire.RequestUpdate{}, Invalid("This request has no session.")
	}
	ask := *rec.Detail.SecretUse
	summary := map[string]string{secretUseOnce: "Allowed once", secretUseSession: "Allowed for this session",
		secretUseAlways: "Allowed always: Ask before use is off", secretUseDeny: "Denied"}[a.Action]
	if summary == "" {
		return wire.RequestUpdate{}, Invalid("The answer is once, session, always or deny.")
	}
	agent := *rec.AskedBy
	if a.Action == secretUseAlways {
		if err := d.stopAccountAsking(ask.Place); err != nil {
			return wire.RequestUpdate{}, err
		}
	}
	key := secretUseKey(agent, ask.Name, ask.Use, ask.Place)
	d.secretUseMu.Lock()
	switch a.Action {
	case secretUseOnce:
		if d.secretUseOnceLeft == nil {
			d.secretUseOnceLeft = map[string]int{}
		}
		d.secretUseOnceLeft[key]++
	case secretUseSession, secretUseAlways:
		// Always also for this session, so the held call goes on before the settings come back.
		if d.secretUseSessions == nil {
			d.secretUseSessions = map[string]bool{}
		}
		d.secretUseSessions[key] = true
	}
	d.secretUseMu.Unlock()
	if !d.endRequest(rec.ID, wire.RequestStateAnswered, &summary, "", by) {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already."}
	}
	log.Printf("account use: %s for %s: %s", ask.Place, agent, a.Action)
	d.secretUseEnded(rec.ID)
	after := d.request(rec.ID)
	if after == nil {
		after = &rec
	}
	return wire.RequestUpdate{Request: *after}, nil
}

// stopAccountAsking turns Ask before use off for the account with the id, on the control plane.
func (d *Daemon) stopAccountAsking(id string) error {
	have, err := d.askAccounts(wire.MachineAccountsCall{})
	if err != nil {
		return err
	}
	i := slices.IndexFunc(have.Accounts, func(a wire.OutsideAccount) bool { return accountID(a) == id })
	if i < 0 {
		return Invalid("Nothing was allowed: that account is no longer in Settings ▸ You ▸ Accounts.")
	}
	a := have.Accounts[i]
	a.AskBeforeUse, a.LastOp = new(false), nil
	_, err = d.askAccounts(wire.MachineAccountsCall{Add: []wire.OutsideAccount{a}})
	return err
}
