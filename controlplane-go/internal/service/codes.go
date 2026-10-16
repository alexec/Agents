package service

import (
	"context"
	"encoding/json"
	"time"

	"github.com/alexec/agents/controlplane-go/internal/auth"
	"github.com/alexec/agents/controlplane-go/internal/records"
	"github.com/alexec/agents/controlplane-go/internal/store"
)

// Codes are ControlCodes: stored by id with nothing secret, used once at any copy.
type Codes struct {
	Store   store.Store
	Private []byte
	Public  []byte
	URL     string
	Pin     string
	Name    string
}

type storedCode struct {
	Purpose string         `json:"purpose"`
	Browser *bool          `json:"browser,omitempty"`
	Owner   *string        `json:"owner,omitempty"`
	Expires records.Stamp `json:"expires"`
}

type spent struct {
	PublicKey []byte  `json:"publicKey"`
	Client    *string `json:"client,omitempty"`
	Host      *string `json:"host,omitempty"`
	replayed  bool
}

func codeKey(id string) string  { return "v1/codes/" + id + ".json" }
func spentKey(id string) string { return "v1/codes/" + id + ".spent" }

// Shown is DaemonAPI.ControlCodeShown, with the date as Swift's default encoder writes it.
type Shown struct {
	Text    string  `json:"text"`
	Expires float64 `json:"expires"`
	Command *string `json:"command,omitempty"`
	expires time.Time
}

const lifetime = 5 * time.Minute

func (c *Codes) Issue(ctx context.Context, host, browser bool, life time.Duration) (*Shown, error) {
	id, secret := auth.MakeCodeSecret(c.Private)
	expires := time.Now().Add(life).UTC().Truncate(time.Millisecond)
	s := storedCode{Purpose: "client", Expires: records.Stamp{Time: expires}}
	if host {
		s.Purpose = "host"
	} else if browser {
		yes := true
		s.Browser = &yes
	}
	b, _ := json.MarshalIndent(s, "", "  ")
	if _, err := c.Store.Put(ctx, codeKey(id), b, store.Absent); err != nil {
		return nil, err
	}
	code := &auth.Code{Host: host, ControlKey: c.Public, Secret: secret, URL: c.URL, Pin: c.Pin, Name: c.Name}
	shown := &Shown{Text: code.Text(), Expires: records.RefDate(expires), expires: expires}
	if host {
		// The one line a server runs to install the host and join (T070).
		cmd := installCommand(c.URL, c.Pin, shown.Text)
		shown.Command = &cmd
	}
	return shown, nil
}

// Stored is a code as stored, refused if unknown, expired or (unless spentToo) spent.
func (c *Codes) Stored(ctx context.Context, id string, spentToo bool) (*storedCode, error) {
	o, err := c.Store.Get(ctx, codeKey(id))
	if err != nil {
		return nil, auth.Refuse(auth.Unavailable)
	}
	var s storedCode
	if o == nil || json.Unmarshal(o.Data, &s) != nil {
		return nil, auth.Refuse(auth.Unknown)
	}
	if !s.Expires.After(time.Now()) {
		return nil, auth.Refuse(auth.Expired)
	}
	if !spentToo {
		if o, _ := c.Store.Get(ctx, spentKey(id)); o != nil {
			return nil, auth.Refuse(auth.Spent)
		}
	}
	return &s, nil
}

// Spend uses a code: the first to write its .spent wins. The same key spending it again
// is the same join tried again (#212), given the earlier spend.
func (c *Codes) Spend(ctx context.Context, id string, by spent) (*spent, error) {
	b, _ := json.MarshalIndent(by, "", "  ")
	_, err := c.Store.Put(ctx, spentKey(id), b, store.Absent)
	if err == nil {
		return &by, nil
	}
	if !store.IsConflict(err) {
		return nil, err
	}
	o, _ := c.Store.Get(ctx, spentKey(id))
	var earlier spent
	if o == nil || json.Unmarshal(o.Data, &earlier) != nil || len(by.PublicKey) == 0 || string(earlier.PublicKey) != string(by.PublicKey) {
		return nil, auth.Refuse(auth.Spent)
	}
	earlier.replayed = true
	return &earlier, nil
}
