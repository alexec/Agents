package usersettings

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"github.com/alexec/agents/Go/wire"
)

// Settings ▸ You ▸ Accounts (#3967): the person's outside accounts, the accounts part of their
// settings, so they go by the same store and path as the rest. A record holds no secret,
// only the name of one in Settings ▸ You ▸ Secrets (#3403, principle 7).

// looksSecret is a value that looks like a secret: a known token prefix, a card number, a
// PEM key. As scripts/accounts.sh check had it (#3909).
var looksSecret = regexp.MustCompile(`(glpat-|dop_v1_|xox[abp]-|xapp-|ghp_|github_pat_|AKIA[0-9A-Z]{12}` +
	`|-----BEGIN|\b(?:\d[ -]?){13,19}\b)`)

// checkAccounts is the accounts part, refused when it is not an OutsideAccounts, an account
// has no service, or a value looks like a secret.
func checkAccounts(value json.RawMessage) error {
	var part wire.OutsideAccounts
	d := json.NewDecoder(bytes.NewReader(value))
	d.DisallowUnknownFields()
	if err := d.Decode(&part); err != nil {
		return fmt.Errorf("%w: The accounts are not a list of accounts: %v", ErrInvalid, err)
	}
	for _, a := range part.Accounts {
		if strings.TrimSpace(a.Service) == "" {
			return fmt.Errorf("%w: An account has no service.", ErrInvalid)
		}
		for _, v := range accountTexts(a) {
			if looksSecret.MatchString(v) {
				return fmt.Errorf("%w: A value of %s looks like a secret. Keep it in Settings ▸ You ▸ Secrets and give its name.", ErrInvalid, a.Service)
			}
		}
	}
	return nil
}

func accountTexts(a wire.OutsideAccount) []string {
	texts := []string{a.Service}
	for _, p := range []*string{a.Description, a.Address, a.Plan, a.Card, a.Secret, a.TwoFactor, a.Issue, a.Made, a.TokenExpires, a.Notes} {
		if p != nil {
			texts = append(texts, *p)
		}
	}
	return append(texts, a.Projects...)
}

// Accounts is the person's outside accounts.
func (b *Book) Accounts(ctx context.Context, user string) (wire.OutsideAccounts, error) {
	part := wire.OutsideAccounts{Accounts: []wire.OutsideAccount{}}
	s, err := b.Settings(ctx, user)
	if err != nil || !partSent(s.Accounts) {
		return part, err
	}
	if err := json.Unmarshal(s.Accounts, &part); err != nil {
		return part, err
	}
	if part.Accounts == nil {
		part.Accounts = []wire.OutsideAccount{}
	}
	return part, nil
}

// AddAccounts adds each account to the person's, or puts it in place of the one with the same
// service and address. It says whether anything changed.
func (b *Book) AddAccounts(ctx context.Context, user string, add []wire.OutsideAccount) (wire.OutsideAccounts, bool, error) {
	part, err := b.Accounts(ctx, user)
	if err != nil || len(add) == 0 {
		return part, false, err
	}
	for _, a := range add {
		i := accountIndex(part.Accounts, a)
		if i < 0 {
			part.Accounts = append(part.Accounts, a)
		} else {
			part.Accounts[i] = a
		}
	}
	raw, err := json.Marshal(part)
	if err != nil {
		return part, false, err
	}
	changed, err := b.SetPart(ctx, user, wire.UserSettingsPartNameAccounts, raw)
	return part, changed, err
}

func accountIndex(accounts []wire.OutsideAccount, a wire.OutsideAccount) int {
	for i, have := range accounts {
		if strings.EqualFold(have.Service, a.Service) && strings.EqualFold(text(have.Address), text(a.Address)) {
			return i
		}
	}
	return -1
}

func text(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}
