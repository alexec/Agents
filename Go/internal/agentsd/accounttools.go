package agentsd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/agentloops-dev/agents/Go/internal/controllink"
	"github.com/agentloops-dev/agents/Go/wire"
)

// manageAccounts is manage_accounts (#3967): the person's outside accounts, from Settings ▸
// You ▸ Accounts on the control plane. list (or find, with service) gives each account's id,
// service and description only (#4164); get gives one account in full; add one, or import the
// files of the old registry in ~/.agents/accounts/ (#3909) once. An account that would replace one
// with the same service and address waits for the person's yes (#4001); a new one goes in at once,
// with Ask before use on. A get of an account with Ask before use waits on a person (#4163,
// accountuse.go). remove takes accounts out (#5253): at once when an agent added each one, else
// only after the person's yes.
func (d *Daemon) manageAccounts(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	var call wire.MachineAccountsCall
	action := strings.TrimSpace(argString(args, "action"))
	switch action {
	case "", "list":
	case "get":
		id := strings.TrimSpace(argString(args, "id"))
		if id == "" {
			return "", Invalid("Nothing was done: give the account's id, as list gives it.")
		}
		listed, err := d.askAccounts(call)
		if err != nil {
			return "", err
		}
		i := slices.IndexFunc(listed.Accounts, func(a wire.OutsideAccount) bool { return accountID(a) == strings.ToLower(id) })
		if i >= 0 {
			waiting, err := d.approveAccountUse(agent, listed.Accounts[i], "get")
			if err != nil || waiting != "" {
				return waiting, err
			}
		}
		note, err := accountNote(d.withLastOps(listed.Accounts), id)
		if err == nil {
			d.accountsDone(agent, readOps(slices.DeleteFunc(listed.Accounts, func(a wire.OutsideAccount) bool {
				return accountID(a) != strings.ToLower(id)
			})))
		}
		return note, err
	case "add":
		var a wire.OutsideAccount
		raw, ok := args["account"]
		if !ok || json.Unmarshal(raw, &a) != nil || strings.TrimSpace(a.Service) == "" {
			return "", Invalid("Nothing was done: give the account, with its service.")
		}
		if a.Description == nil || strings.TrimSpace(*a.Description) == "" {
			return "", Invalid("Nothing was done: give the account a description, so that another agent can tell it from the other accounts of %s.", a.Service)
		}
		call.Add = []wire.OutsideAccount{a}
	case "remove":
		return d.removeAccounts(agent, args)
	case "import":
		found, err := oldAccounts(filepath.Join(d.personalHome(), ".agents", "accounts"))
		if err != nil {
			return "", err
		}
		call.Add = found
	default:
		return "", Invalid("Nothing was done: action is list, get, add, remove or import.")
	}
	if len(call.Add) == 0 {
		listed, err := d.askAccounts(call)
		if err != nil {
			return "", err
		}
		// A list with no service reads no account (#4157): only one filtered to the account's.
		service, project := argString(args, "service"), argString(args, "project")
		if strings.TrimSpace(service) != "" {
			d.accountsDone(agent, readOps(accountsOf(listed.Accounts, service, project)))
		}
		return accountsNote(listed.Accounts, service, project), nil
	}
	have, err := d.askAccounts(wire.MachineAccountsCall{})
	if err != nil {
		return "", err
	}
	// An agent never turns Ask before use off (#4163): a new account asks, a replaced one keeps its own.
	// A new one is this agent's (#5253), so an agent may remove it later; a replaced one keeps who
	// added it, on the control plane.
	for i := range call.Add {
		call.Add[i].AskBeforeUse = nil
		call.Add[i].AddedBy = agentRef(agent)
	}
	plan := planAccounts(have.Accounts, call.Add)
	if len(plan.changed) > 0 {
		title := d.agentWho(agent) + " wants to replace an account"
		if len(plan.changed) > 1 {
			title = fmt.Sprintf("%s wants to replace %d accounts", d.agentWho(agent), len(plan.changed))
		}
		return d.personSaysYes(agent, title, replaceQuestion(plan.changed), "Replace", func(replace bool) (string, error) {
			return d.addAccounts(agent, have, plan, replace, args)
		})
	}
	return d.addAccounts(agent, have, plan, false, args)
}

// removeAccounts is manage_accounts remove (#5253): the accounts with the ids go. One the person
// added (no addedBy) is theirs, so when any is, the whole call waits for their yes on a card.
func (d *Daemon) removeAccounts(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	var ids []string
	if raw, ok := args["ids"]; ok && json.Unmarshal(raw, &ids) != nil {
		return "", Invalid("Nothing was done: ids is a list of the accounts' ids, as list gives them.")
	}
	if id := argString(args, "id"); strings.TrimSpace(id) != "" {
		ids = append(ids, id)
	}
	if len(ids) == 0 {
		return "", Invalid("Nothing was done: give the ids of the accounts to remove, as list gives them.")
	}
	if d.askControl.Load() != nil && !d.controlHas(wire.CapMachineAccounts2) {
		return "", &Error{Code: wire.FailureNotSupported, Message: "Nothing was done: the control plane needs an update to remove an account."}
	}
	have, err := d.askAccounts(wire.MachineAccountsCall{})
	if err != nil {
		return "", err
	}
	var gone []wire.OutsideAccount
	persons := 0
	for _, id := range ids {
		id = strings.ToLower(strings.TrimSpace(id))
		i := slices.IndexFunc(have.Accounts, func(a wire.OutsideAccount) bool { return accountID(a) == id })
		if i < 0 {
			return "", Invalid("Nothing was done: there is no account with the id %s. list gives the ids.", id)
		}
		if slices.ContainsFunc(gone, func(a wire.OutsideAccount) bool { return accountID(a) == id }) {
			continue
		}
		gone = append(gone, have.Accounts[i])
		if have.Accounts[i].AddedBy == nil {
			persons++
		}
	}
	remove := func() (string, error) {
		var keys []wire.AccountKey
		var ops []wire.AccountOperation
		for _, a := range gone {
			keys = append(keys, wire.AccountKey{Service: a.Service, Address: a.Address})
			ops = append(ops, wire.AccountOperation{What: wire.AccountOperationWhatRemoved, Service: a.Service, Address: a.Address})
		}
		ops = byAgent(agent, ops)
		listed, err := d.askAccounts(wire.MachineAccountsCall{Remove: keys, Ops: ops})
		if err != nil {
			return "", err
		}
		d.noteAccountOps(agent, ops)
		return fmt.Sprintf("Removed %d. ", len(gone)) + accountsNote(listed.Accounts, "", ""), nil
	}
	if persons == 0 {
		return remove()
	}
	title := d.agentWho(agent) + " wants to remove an account"
	if len(gone) > 1 {
		title = fmt.Sprintf("%s wants to remove %d accounts", d.agentWho(agent), len(gone))
	}
	return d.personSaysYes(agent, title, removeQuestion(gone), "Remove", func(yes bool) (string, error) {
		if !yes {
			return "Removed none: the person did not say Remove.", nil
		}
		return remove()
	})
}

// removeQuestion is the card's question: each account, by its service, address and description.
func removeQuestion(gone []wire.OutsideAccount) string {
	var b strings.Builder
	if len(gone) == 1 {
		b.WriteString("Remove this account from Settings ▸ You ▸ Accounts?")
	} else {
		fmt.Fprintf(&b, "Remove these %d accounts from Settings ▸ You ▸ Accounts?", len(gone))
	}
	b.WriteString(" The account on the service stays; only its record goes.\n")
	for _, a := range gone {
		b.WriteString("\n- " + a.Service)
		if a.Address != nil && *a.Address != "" {
			b.WriteString(" (" + *a.Address + ")")
		}
		if a.Description != nil && strings.TrimSpace(*a.Description) != "" {
			b.WriteString(": " + strings.TrimSpace(*a.Description))
		}
		if a.AddedBy != nil {
			b.WriteString(" (an agent added it)")
		}
	}
	return b.String()
}

// addAccounts sends what an add or import adds, with the accounts it replaces when replace (#4261:
// also after a late yes).
func (d *Daemon) addAccounts(agent wire.UUID, have wire.OutsideAccounts, plan accountsPlan, replace bool, args map[string]json.RawMessage) (string, error) {
	send := plan.added
	if replace {
		for _, c := range plan.changed {
			send = append(send, c.to)
		}
	}
	listed := have
	if len(send) > 0 {
		ops := byAgent(agent, plan.ops(replace))
		var err error
		if listed, err = d.askAccounts(wire.MachineAccountsCall{Add: send, Ops: ops}); err != nil {
			return "", err
		}
		d.noteAccountOps(agent, ops)
	}
	return plan.note(replace) + accountsNote(listed.Accounts, argString(args, "service"), argString(args, "project")), nil
}

// accountsPlan is what an add or import does to the person's accounts: those that are new, those
// that would replace one (and so wait for a yes), and how many are as they are already.
type accountsPlan struct {
	added   []wire.OutsideAccount
	changed []accountChange
	same    int
}

type accountChange struct {
	from, to wire.OutsideAccount
	fields   []string // "plan: Free → Pro", in the order of the account's fields
}

func planAccounts(have, add []wire.OutsideAccount) accountsPlan {
	var plan accountsPlan
	for _, a := range add {
		i := slices.IndexFunc(have, func(h wire.OutsideAccount) bool {
			return strings.EqualFold(h.Service, a.Service) && strings.EqualFold(deref(h.Address), deref(a.Address))
		})
		if i < 0 {
			plan.added = append(plan.added, a)
			continue
		}
		a.AskBeforeUse = have[i].AskBeforeUse
		if fields := accountFields(have[i], a); len(fields) > 0 {
			plan.changed = append(plan.changed, accountChange{from: have[i], to: a, fields: fields})
		} else {
			plan.same++
		}
	}
	return plan
}

// accountFields is each field that differs, as "name: old → new", "(none)" for an absent value.
func accountFields(from, to wire.OutsideAccount) []string {
	fields := func(a wire.OutsideAccount) map[string]any {
		var m map[string]any
		raw, _ := json.Marshal(a)
		_ = json.Unmarshal(raw, &m)
		return m
	}
	old, now := fields(from), fields(to)
	show := func(v any) string {
		switch v := v.(type) {
		case nil:
			return "(none)"
		case string:
			return v
		default:
			raw, _ := json.Marshal(v)
			return string(raw)
		}
	}
	var out []string
	for _, name := range []string{"service", "address", "username", "description", "plan", "monthlyCostUsd", "card", "secret", "twoFactor", "issue", "made", "tokenExpires", "notes", "projects"} {
		if a, b := show(old[name]), show(now[name]); a != b {
			out = append(out, name+": "+a+" → "+b)
		}
	}
	return out
}

func replaceQuestion(changed []accountChange) string {
	var b strings.Builder
	b.WriteString("Replace ")
	if len(changed) == 1 {
		b.WriteString("this account?")
	} else {
		fmt.Fprintf(&b, "these %d accounts?", len(changed))
	}
	for _, c := range changed {
		b.WriteString("\n\n" + c.from.Service)
		if c.from.Address != nil {
			b.WriteString(" (" + *c.from.Address + ")")
		}
		for _, f := range c.fields {
			b.WriteString("\n- " + f)
		}
	}
	return b.String()
}

// ops are the operations an add or import did: each new account, and each replaced one.
func (p accountsPlan) ops(replaced bool) []wire.AccountOperation {
	var ops []wire.AccountOperation
	for _, a := range p.added {
		ops = append(ops, wire.AccountOperation{What: wire.AccountOperationWhatAdded, Service: a.Service, Address: a.Address})
	}
	if replaced {
		for _, c := range p.changed {
			ops = append(ops, wire.AccountOperation{What: wire.AccountOperationWhatEdited, Service: c.to.Service, Address: c.to.Address})
		}
	}
	return ops
}

// byAgent is ops, each with the session that did it, so the person's clients can name it.
func byAgent(agent wire.UUID, ops []wire.AccountOperation) []wire.AccountOperation {
	for i := range ops {
		ops[i].Agent = agentRef(agent)
	}
	return ops
}

func readOps(accounts []wire.OutsideAccount) []wire.AccountOperation {
	var ops []wire.AccountOperation
	for _, a := range accounts {
		ops = append(ops, wire.AccountOperation{What: wire.AccountOperationWhatRead, Service: a.Service, Address: a.Address})
	}
	return ops
}

// accountsDone records reads that went by a call that changed nothing, and tells the control
// plane, for its audit. The answer is given already: a failure here is only logged.
func (d *Daemon) accountsDone(agent wire.UUID, ops []wire.AccountOperation) {
	if len(ops) == 0 {
		return
	}
	ops = byAgent(agent, ops)
	d.noteAccountOps(agent, ops)
	if _, err := d.askAccounts(wire.MachineAccountsCall{Ops: ops}); err != nil {
		log.Printf("manage_accounts: the control plane was not told of %d reads: %v", len(ops), err)
	}
}

// withLastOps is the accounts, each with its last operation as this machine knows it.
func (d *Daemon) withLastOps(all []wire.OutsideAccount) []wire.OutsideAccount {
	out := slices.Clone(all)
	for i := range out {
		out[i].LastOp = d.accountLastOp(out[i])
	}
	return out
}

// note is the start of the tool's answer: what went in and what did not.
func (p accountsPlan) note(replaced bool) string {
	var said []string
	if n := len(p.added); n > 0 {
		said = append(said, fmt.Sprintf("Added %d.", n))
	}
	if n := len(p.changed); n > 0 && replaced {
		said = append(said, fmt.Sprintf("Replaced %d.", n))
	} else if n > 0 {
		said = append(said, fmt.Sprintf("Kept %d as they were: the person did not say Replace.", n))
	}
	if p.same > 0 {
		said = append(said, fmt.Sprintf("%d had no change.", p.same))
	}
	return strings.Join(said, " ") + " "
}

func (d *Daemon) askAccounts(call wire.MachineAccountsCall) (wire.OutsideAccounts, error) {
	var listed wire.OutsideAccounts
	ask := d.askControl.Load()
	if ask == nil {
		return listed, &Error{Code: wire.FailureNotSupported, Message: "This machine isn’t on a control plane, so it has no accounts."}
	}
	if !d.controlHas(wire.CapMachineAccounts1) {
		return listed, &Error{Code: wire.FailureNotSupported, Message: "Nothing was done: the control plane needs an update to do this."}
	}
	out, err := (*ask)(d.ctx, wire.CallMachineAccounts.Name, call)
	var refused *controllink.AskError
	if errors.As(err, &refused) {
		return listed, &Error{Code: refused.Code, Message: "Nothing was done: " + refused.Message}
	}
	if err != nil {
		return listed, &Error{Code: wire.FailureNotSupported, Message: "Nothing was done: " + err.Error() + "."}
	}
	if err := json.Unmarshal(out, &listed); err != nil {
		return listed, &Error{Code: wire.FailureNotSupported, Message: "Nothing was done: the control plane's answer could not be read."}
	}
	return listed, nil
}

// oldAccounts reads the registry's files (#3909), whose fields are snake_case.
func oldAccounts(dir string) ([]wire.OutsideAccount, error) {
	paths, _ := filepath.Glob(filepath.Join(dir, "*.json"))
	if len(paths) == 0 {
		return nil, Invalid("Nothing was done: there are no files in %s.", dir)
	}
	slices.Sort(paths)
	var found []wire.OutsideAccount
	for _, path := range paths {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil, err
		}
		var old map[string]any
		if err := json.Unmarshal(raw, &old); err != nil {
			return nil, Invalid("Nothing was done: %s is not valid JSON.", filepath.Base(path))
		}
		found = append(found, fromOld(old))
	}
	return found, nil
}

func fromOld(old map[string]any) wire.OutsideAccount {
	str := func(key string) *string {
		switch v := old[key].(type) {
		case string:
			if v != "" {
				return &v
			}
		case float64:
			s := strconv.FormatFloat(v, 'f', -1, 64)
			if key == "issue" {
				s = "#" + s
			}
			return &s
		}
		return nil
	}
	a := wire.OutsideAccount{Address: str("address"), Plan: str("plan"), Card: str("card"), Secret: str("secret"),
		TwoFactor: str("two_factor"), Issue: str("issue"), Made: str("made"), TokenExpires: str("token_expires"), Notes: str("notes")}
	if s := str("service"); s != nil {
		a.Service = *s
	}
	if cost, ok := old["monthly_cost_usd"].(float64); ok {
		a.MonthlyCostUsd = &cost
	}
	return a
}

// accountID is an account's id (#4164): from its service and address, which name it on the control
// plane too (usersettings.accountIndex), so it needs no field of its own and does not show the address.
func accountID(a wire.OutsideAccount) string {
	address := ""
	if a.Address != nil {
		address = *a.Address
	}
	sum := sha256.Sum256([]byte(strings.ToLower(a.Service) + "#" + strings.ToLower(address)))
	return hex.EncodeToString(sum[:4])
}

// accountLine is what list shows of an account: no address, plan, cost, secret, card or notes.
// Asks is its Ask before use (#4163): a get of it waits on a person.
type accountLine struct {
	ID          string `json:"id"`
	Service     string `json:"service"`
	Description string `json:"description"`
	Asks        bool   `json:"asksBeforeUse"`
}

const noDescription = "No description"

// accountsOf is the accounts of service and project, each only when named.
func accountsOf(all []wire.OutsideAccount, service, project string) []wire.OutsideAccount {
	service, project = strings.TrimSpace(service), strings.TrimSpace(project)
	var rows []wire.OutsideAccount
	for _, a := range all {
		if service != "" && !strings.Contains(strings.ToLower(a.Service), strings.ToLower(service)) {
			continue
		}
		if project != "" && len(a.Projects) > 0 && !slices.ContainsFunc(a.Projects, func(p string) bool { return strings.EqualFold(p, project) }) {
			continue
		}
		rows = append(rows, a)
	}
	return rows
}

// accountsNote is the accounts, a line each, those of service and project only when named.
func accountsNote(all []wire.OutsideAccount, service, project string) string {
	var b strings.Builder
	service = strings.TrimSpace(service)
	rows := accountsOf(all, service, project)
	if len(rows) == 0 {
		if service != "" {
			return b.String() + "There is no account for " + service + "."
		}
		return b.String() + "There are no accounts."
	}
	fmt.Fprintf(&b, "%d accounts (get one with its id for the rest):\n", len(rows))
	for _, a := range rows {
		row := accountLine{ID: accountID(a), Service: a.Service, Description: noDescription, Asks: accountAsks(a)}
		if a.Description != nil && strings.TrimSpace(*a.Description) != "" {
			row.Description = *a.Description
		}
		line, _ := json.Marshal(row)
		b.Write(line)
		b.WriteByte('\n')
	}
	return strings.TrimSuffix(b.String(), "\n")
}

// accountNote is the account with the id, in full, with its id.
func accountNote(all []wire.OutsideAccount, id string) (string, error) {
	for _, a := range all {
		if accountID(a) != strings.ToLower(id) {
			continue
		}
		raw, err := json.Marshal(a)
		if err != nil {
			return "", err
		}
		var full map[string]any
		if err := json.Unmarshal(raw, &full); err != nil {
			return "", err
		}
		full["id"] = accountID(a)
		line, err := json.Marshal(full)
		return string(line), err
	}
	return "", Invalid("Nothing was done: there is no account with the id %s. list gives the ids.", id)
}
