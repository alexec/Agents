package agentsd

import (
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
// You ▸ Accounts on the control plane. list (or find, with service), add one, or import the files
// of the old registry in ~/.agents/accounts/ (#3909) once.
func (d *Daemon) manageAccounts(_ wire.UUID, args map[string]json.RawMessage) (string, error) {
	var call wire.MachineAccountsCall
	action := strings.TrimSpace(argString(args, "action"))
	switch action {
	case "", "list":
	case "add":
		var a wire.OutsideAccount
		raw, ok := args["account"]
		if !ok || json.Unmarshal(raw, &a) != nil || strings.TrimSpace(a.Service) == "" {
			return "", Invalid("Nothing was done: give the account, with its service.")
		}
		call.Add = []wire.OutsideAccount{a}
	case "import":
		found, err := oldAccounts(filepath.Join(d.personalHome(), ".agents", "accounts"))
		if err != nil {
			return "", err
		}
		call.Add = found
	default:
		return "", Invalid("Nothing was done: action is list, add or import.")
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
	total := 0.0
	fmt.Fprintf(&b, "%d accounts:\n", len(rows))
	for _, a := range rows {
		line, _ := json.Marshal(a)
		b.Write(line)
		b.WriteByte('\n')
		if a.MonthlyCostUsd != nil {
			total += *a.MonthlyCostUsd
		}
	}
	fmt.Fprintf(&b, "$%s a month.", strconv.FormatFloat(total, 'f', -1, 64))
	return b.String()
}
