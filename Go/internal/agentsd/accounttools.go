package agentsd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// manageAccounts is manage_accounts (#3967): the person's outside accounts, from Settings ▸
// You ▸ Accounts on the control plane. list (or find, with service) gives each account's id,
// service and description only (#4164); get gives one account in full; add one, or import the
// files of the old registry in ~/.agents/accounts/ (#3909) once.
func (d *Daemon) manageAccounts(_ wire.UUID, args map[string]json.RawMessage) (string, error) {
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
		return accountNote(listed.Accounts, id)
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
	case "import":
		found, err := oldAccounts(filepath.Join(d.personalHome(), ".agents", "accounts"))
		if err != nil {
			return "", err
		}
		call.Add = found
	default:
		return "", Invalid("Nothing was done: action is list, get, add or import.")
	}
	listed, err := d.askAccounts(call)
	if err != nil {
		return "", err
	}
	return accountsNote(listed.Accounts, argString(args, "service"), argString(args, "project"), action, len(call.Add)), nil
}

func (d *Daemon) askAccounts(call wire.MachineAccountsCall) (wire.OutsideAccounts, error) {
	var listed wire.OutsideAccounts
	ask := d.askControl.Load()
	if ask == nil {
		return listed, &Error{Code: wire.FailureNotSupported, Message: "This machine isn’t on a control plane, so it has no accounts."}
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
type accountLine struct {
	ID          string `json:"id"`
	Service     string `json:"service"`
	Description string `json:"description"`
}

const noDescription = "No description"

// accountsNote is the accounts, a line each, those of service and project only when named.
func accountsNote(all []wire.OutsideAccount, service, project, action string, added int) string {
	var b strings.Builder
	switch action {
	case "add":
		b.WriteString("Added. ")
	case "import":
		fmt.Fprintf(&b, "Imported %d accounts. ", added)
	}
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
	if len(rows) == 0 {
		if service != "" {
			return b.String() + "There is no account for " + service + "."
		}
		return b.String() + "There are no accounts."
	}
	fmt.Fprintf(&b, "%d accounts (get one with its id for the rest):\n", len(rows))
	for _, a := range rows {
		row := accountLine{ID: accountID(a), Service: a.Service, Description: noDescription}
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
