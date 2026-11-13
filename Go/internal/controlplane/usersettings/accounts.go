package usersettings

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/wire"
)

// Settings ▸ You ▸ Accounts (#3967): the person's outside accounts, the accounts part of their
// settings, so they go by the same store and path as the rest. A record holds no secret,
// only the name of one in Settings ▸ You ▸ Secrets (#3403, principle 7).

// looksSecret is a value that looks like a secret: a known token prefix, a card number, a
// PEM key. As scripts/accounts.sh check had it (#3909).
var looksSecret = regexp.MustCompile(`(glpat-|dop_v1_|xox[abp]-|xapp-|ghp_|github_pat_|AKIA[0-9A-Z]{12}` +
	`|-----BEGIN|\b(?:\d[ -]?){13,19}\b)`)

// MaxSecretDescription is the longest description a secret keeps (#4167), in characters:
// one or two sentences.
const MaxSecretDescription = 300

// CheckSecretDescription is a secret's description (#4167), trimmed, or an error when it is
// too long, more than one line, or looks like a secret: it is kept in clear, beside the name.
func CheckSecretDescription(d *string) (string, error) {
	if d == nil {
		return "", nil
	}
	text := strings.TrimSpace(*d)
	switch {
	case utf8.RuneCountInString(text) > MaxSecretDescription:
		return "", fmt.Errorf("%w: A secret's description is at most %d characters.", ErrInvalid, MaxSecretDescription)
	case strings.ContainsAny(text, "\n\r\x00"):
		return "", fmt.Errorf("%w: A secret's description is one line.", ErrInvalid)
	case looksSecret.MatchString(text):
		return "", fmt.Errorf("%w: The description looks like a secret. Say what the secret is for, never its value.", ErrInvalid)
	}
	return text, nil
}

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
	for _, p := range []*string{a.Description, a.Address, a.Username, a.Plan, a.Card, a.Secret, a.TwoFactor, a.Issue, a.Made, a.TokenExpires, a.Notes} {
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
// service and address. It says whether anything changed. An account that takes another's place
// keeps its made and, when it differs, is edited now (#4157). No lastOp is stored: a machine
// gives it.
func (b *Book) AddAccounts(ctx context.Context, user string, add []wire.OutsideAccount, now time.Time) (wire.OutsideAccounts, bool, error) {
	part, err := b.Accounts(ctx, user)
	if err != nil || len(add) == 0 {
		return part, false, err
	}
	for _, a := range add {
		a.LastOp = nil
		i := accountIndex(part.Accounts, a)
		if i < 0 {
			a.Edited = nil
			part.Accounts = append(part.Accounts, a)
			continue
		}
		have := part.Accounts[i]
		if a.Made == nil {
			a.Made = have.Made
		}
		a.Edited = have.Edited
		if !sameAccount(have, a) {
			at := wire.DateOf(now)
			a.Edited = &at
		}
		part.Accounts[i] = a
	}
	raw, err := json.Marshal(part)
	if err != nil {
		return part, false, err
	}
	changed, err := b.SetPart(ctx, user, wire.UserSettingsPartNameAccounts, raw)
	return part, changed, err
}

// stampAccounts is the accounts part to keep, from what was kept (#4160): no lastOp, which a
// machine gives; an account that takes another's place keeps its made, and its edited unless
// it differs, when it is edited now. So an Edit… on a client is edited as an add is.
func stampAccounts(had, value json.RawMessage, now time.Time) json.RawMessage {
	var old, part wire.OutsideAccounts
	if json.Unmarshal(value, &part) != nil {
		return value
	}
	_ = json.Unmarshal(had, &old)
	for i, a := range part.Accounts {
		a.LastOp = nil
		j := accountIndex(old.Accounts, a)
		if j < 0 {
			a.Edited = nil
			part.Accounts[i] = a
			continue
		}
		have := old.Accounts[j]
		if a.Made == nil {
			a.Made = have.Made
		}
		// AddAccounts stamps its own time; a client sends back the edited it read.
		stamped := a.Edited != nil && (have.Edited == nil || *a.Edited != *have.Edited)
		switch {
		case sameAccount(have, a):
			a.Edited = have.Edited
		case !stamped:
			at := wire.DateOf(now)
			a.Edited = &at
		}
		part.Accounts[i] = a
	}
	raw, err := json.Marshal(part)
	if err != nil {
		return value
	}
	return raw
}

// sameAccount is whether two accounts are the same, but for when they were last changed.
func sameAccount(a, b wire.OutsideAccount) bool {
	a.Edited, a.LastOp, b.Edited, b.LastOp = nil, nil, nil, nil
	x, _ := json.Marshal(a)
	y, _ := json.Marshal(b)
	return bytes.Equal(x, y)
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
