package hosted

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// Backup and restore of one account (#2226, spec 1003 FR-041). The disk's daily snapshot
// keeps the whole service; these put one account back without the rest going back too:
//
//	<dir>/<account>/account.json   its record in hosted/v1/accounts/
//	<dir>/<account>/records.jsonl  every record under accounts/<id>/, one {"key","data"} a line
//
// Its control key is sealed in its own prefix, so a restore needs the same KMS key.

// stopWithin is how long a running service takes, at most, to stop a suspended copy.
const stopWithin = 70 * time.Second

type backedUp struct {
	Key  string `json:"key"`
	Data []byte `json:"data"`
}

// Backup copies each account in ids, or every account when there are none, into dir, and
// gives the ids it copied.
func (a Admin) Backup(ctx context.Context, dir string, ids []string) ([]string, error) {
	if len(ids) == 0 {
		list, err := a.Accounts(ctx)
		if err != nil {
			return nil, err
		}
		for _, acc := range list {
			ids = append(ids, acc.ID)
		}
	}
	var done []string
	for _, id := range ids {
		if err := a.backUp(ctx, dir, id); err != nil {
			return done, fmt.Errorf("%s: %w", id, err)
		}
		done = append(done, id)
	}
	return done, nil
}

func (a Admin) backUp(ctx context.Context, dir, id string) error {
	if !validID(id) {
		return fmt.Errorf("%q is not an account's id", id)
	}
	o, err := a.Store.Get(ctx, accountKey(id))
	if err != nil {
		return err
	}
	if o == nil {
		return errors.New("there is no such account")
	}
	into := filepath.Join(dir, id)
	if err := os.MkdirAll(into, 0o700); err != nil {
		return err
	}
	// Written beside, then moved, so a backup cut short leaves the one before whole.
	tmp, err := os.CreateTemp(into, ".records-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	w := bufio.NewWriter(tmp)
	enc := json.NewEncoder(w)
	st := accountStore(a.Store, id)
	keys, err := st.List(ctx, "")
	if err != nil {
		_ = tmp.Close()
		return err
	}
	for _, k := range keys {
		r, err := st.Get(ctx, k.Key)
		if err != nil {
			_ = tmp.Close()
			return err
		}
		if r == nil {
			continue
		}
		if err := enc.Encode(backedUp{Key: k.Key, Data: r.Data}); err != nil {
			_ = tmp.Close()
			return err
		}
	}
	if err := w.Flush(); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tmp.Name(), filepath.Join(into, "records.jsonl")); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(into, "account.json"), o.Data, 0o600)
}

// Delete deletes an account and its control plane's records, as Delete Account does. It
// must be suspended a minute first, so no running copy writes after the delete.
func (a Admin) Delete(ctx context.Context, id string) error {
	acc, err := a.accounts().get(ctx, id)
	if err != nil {
		return err
	}
	if acc == nil {
		return fmt.Errorf("there is no account %q", id)
	}
	if acc.Suspended == nil {
		return fmt.Errorf("%s is running: suspend it first (agents-hosted admin suspend %s deleting), then delete it", id, id)
	}
	if a.now().Sub(acc.Suspended.At) < stopWithin {
		return fmt.Errorf("%s was suspended %s ago: its control plane may still be running; try again in a minute", id, a.now().Sub(acc.Suspended.At).Round(time.Second))
	}
	return a.accounts().remove(ctx, acc)
}

// Restore makes one account's records what dir holds for it: each record put back, and
// each record it did not hold deleted. Nothing outside accounts/<id>/ changes, except an
// account that was deleted: its record, and its GitHub user's link, come back.
//
// The account must be suspended, or gone, so no running copy writes over it: suspend,
// restore, unsuspend.
func (a Admin) Restore(ctx context.Context, dir, id string) (int, error) {
	if !validID(id) {
		return 0, fmt.Errorf("%q is not an account's id", id)
	}
	from := filepath.Join(dir, id)
	data, err := os.ReadFile(filepath.Join(from, "account.json"))
	if err != nil {
		return 0, fmt.Errorf("no backup of %s in %s: %w", id, dir, err)
	}
	var backed Account
	if err := json.Unmarshal(data, &backed); err != nil || backed.ID != id {
		return 0, fmt.Errorf("%s/account.json is not %s's record", from, id)
	}
	now, err := a.accounts().get(ctx, id)
	if err != nil {
		return 0, err
	}
	if now != nil && now.Suspended == nil {
		return 0, fmt.Errorf("%s is running: suspend it first (agents-hosted admin suspend %s restoring), restore, then unsuspend it", id, id)
	}
	// A running service stops a suspended copy within a minute (sweepAccounts).
	if now != nil && a.now().Sub(now.Suspended.At) < stopWithin {
		return 0, fmt.Errorf("%s was suspended %s ago: its control plane may still be running; try again in a minute", id, a.now().Sub(now.Suspended.At).Round(time.Second))
	}
	if now == nil {
		// The GitHub user may have signed up again since: then this backup is not theirs to
		// take back, and the operator decides.
		if o, err := a.Store.Get(ctx, gitHubKey(backed.GitHub.ID)); err != nil {
			return 0, err
		} else if o != nil {
			var link struct {
				Account string `json:"account"`
			}
			if json.Unmarshal(o.Data, &link) == nil && link.Account != id {
				return 0, fmt.Errorf("GitHub user %d has another account now, %s: delete it first", backed.GitHub.ID, link.Account)
			}
		}
	}

	f, err := os.Open(filepath.Join(from, "records.jsonl"))
	if err != nil {
		return 0, err
	}
	defer f.Close()
	st := accountStore(a.Store, id)
	kept := map[string]bool{}
	scan := bufio.NewScanner(f)
	scan.Buffer(make([]byte, 0, 1<<20), 64<<20)
	for scan.Scan() {
		var r backedUp
		if err := json.Unmarshal(scan.Bytes(), &r); err != nil || r.Key == "" {
			return len(kept), fmt.Errorf("%s/records.jsonl line %d is not a record", from, len(kept)+1)
		}
		if _, err := st.Put(ctx, r.Key, r.Data, store.Always); err != nil {
			return len(kept), err
		}
		kept[r.Key] = true
	}
	if err := scan.Err(); err != nil {
		return len(kept), err
	}
	keys, err := st.List(ctx, "")
	if err != nil {
		return len(kept), err
	}
	for _, k := range keys {
		if !kept[k.Key] {
			if err := st.Delete(ctx, k.Key); err != nil {
				return len(kept), err
			}
		}
	}
	// Its size is counted again at its next start.
	if err := a.Store.Delete(ctx, usageKey(id)); err != nil {
		return len(kept), err
	}
	if now == nil {
		link, _ := json.Marshal(map[string]string{"account": id})
		if _, err := a.Store.Put(ctx, gitHubKey(backed.GitHub.ID), link, store.Absent); err != nil && !store.IsConflict(err) {
			return len(kept), err
		}
		if _, err := a.Store.Put(ctx, accountKey(id), data, store.Absent); err != nil && !store.IsConflict(err) {
			return len(kept), err
		}
	}
	return len(kept), nil
}
