package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// A control plane's backup (#2137): its store, and what is kept beside the store, which a
// restore needs as well. A store alone does not start (another key's), and a home with no
// certificate makes a new one, which every member refuses (it holds the old pin).
//
//	<backup>/store/        every record, sealed keys too (BackupStore)
//	<backup>/control-key   the control key, raw, 0600: when it is in a file, not sealed in
//	                       the store by a KMS
//	<backup>/secrets-key   the local key that seals secrets (people's, providers'), 0600
//	<backup>/tls/          cert.pem and key.pem, the certificate members are pinned to
//	<backup>/apns.p8       the APNs key, when there is one
//	<backup>/backup.json   what is in it
//
// A restore puts each file back where a home keeps it, and the store into the home's store
// or one named. The backup holds keys in clear: keep it as safe as the home.

// BackupFileName is the backup's own list of what is in it.
const BackupFileName = "backup.json"

// HomeParts is where a control plane keeps what a restore needs, besides the store. An
// empty path is a part this control plane does not have.
type HomeParts struct {
	ControlKey string
	// GivenKey is the control key handed in (Agents Host keeps it in the keychain): the
	// backup holds it as control-key, whatever ControlKey's file holds.
	GivenKey   []byte
	SecretsKey string
	// The certificate and its key: a self-signed one's, or one given by path.
	TLSCert, TLSKey string
	APNsKey         string
}

// HomePartsIn is where a home keeps them: what serve --home uses.
func HomePartsIn(home string) HomeParts {
	return HomeParts{ControlKey: filepath.Join(home, "control-key"), SecretsKey: filepath.Join(home, "secrets-key"),
		TLSCert: filepath.Join(home, "tls", "cert.pem"), TLSKey: filepath.Join(home, "tls", "key.pem"),
		APNsKey: filepath.Join(home, "apns.p8")}
}

// BackupList is backup.json.
type BackupList struct {
	Made    time.Time `json:"made"`
	Records int       `json:"records"`
	// Files is each part kept, by its name in the backup.
	Files []string `json:"files"`
	// Kept is, after a restore, each part left as it was where it goes.
	Kept []string `json:"-"`
}

// backupFiles is each part's name in a backup.
func backupFiles(p HomeParts) []struct{ from, name string } {
	return []struct{ from, name string }{
		{p.ControlKey, "control-key"}, {p.SecretsKey, "secrets-key"},
		{p.TLSCert, filepath.Join("tls", "cert.pem")}, {p.TLSKey, filepath.Join("tls", "key.pem")},
		{p.APNsKey, "apns.p8"},
	}
}

// Backup writes a backup of st and the parts into to, a folder that is missing or empty.
// Run it with no copy changing the store, or the store copy says what changed under it.
func Backup(ctx context.Context, st store.Store, parts HomeParts, to string) (*BackupList, error) {
	if entries, err := os.ReadDir(to); err == nil && len(entries) > 0 {
		return nil, fmt.Errorf("%s is not empty: give a new folder for the backup", to)
	}
	if err := os.MkdirAll(filepath.Join(to, "tls"), 0o700); err != nil {
		return nil, err
	}
	os.Chmod(to, 0o700)
	list := &BackupList{Made: time.Now().UTC(), Files: []string{}}
	if parts.GivenKey != nil {
		if err := os.WriteFile(filepath.Join(to, "control-key"), parts.GivenKey, 0o600); err != nil {
			return nil, err
		}
		list.Files = append(list.Files, "control-key")
	}
	for _, f := range backupFiles(parts) {
		if f.from == "" || parts.GivenKey != nil && f.name == "control-key" {
			continue
		}
		data, err := os.ReadFile(f.from)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if err := os.WriteFile(filepath.Join(to, f.name), data, 0o600); err != nil {
			return nil, err
		}
		list.Files = append(list.Files, f.name)
	}
	copied, _, err := BackupStore(ctx, st, store.NewFolder(filepath.Join(to, "store")))
	if err != nil {
		return nil, fmt.Errorf("the store: %w", err)
	}
	list.Records = copied
	data, _ := json.MarshalIndent(list, "", "  ")
	if err := os.WriteFile(filepath.Join(to, BackupFileName), append(data, '\n'), 0o600); err != nil {
		return nil, err
	}
	return list, nil
}

// Restore puts a backup back: each part where parts says, and the records into st, which
// must be empty. A part already there is not overwritten: a restore goes into a new home.
// One that is there already the same is left, and so is an APNs key given as a secret (a
// cloud machine's, read only): Kept says which were left. With newKeeper, the control key
// sealed by the old KMS is left out, for the key exported with the backup to be sealed by a
// new one; what the old KMS sealed (people's and providers' secrets) does not open.
func Restore(ctx context.Context, from string, parts HomeParts, st store.Store, newKeeper bool) (*BackupList, error) {
	data, err := os.ReadFile(filepath.Join(from, BackupFileName))
	if err != nil {
		return nil, fmt.Errorf("%s is not a backup: it has no %s", from, BackupFileName)
	}
	var list BackupList
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, fmt.Errorf("%s: %w", BackupFileName, err)
	}
	left := map[string]bool{}
	for _, f := range backupFiles(parts) {
		if f.from == "" {
			continue
		}
		mine, err := os.ReadFile(filepath.Join(from, f.name))
		if err != nil {
			continue
		}
		there, err := os.ReadFile(f.from)
		switch {
		case errors.Is(err, os.ErrNotExist):
		case err == nil && string(there) == string(mine), f.name == "apns.p8":
			left[f.name] = true
			list.Kept = append(list.Kept, f.from)
		default:
			return nil, fmt.Errorf("%s is there already: restore into a new home", f.from)
		}
	}
	// The sealed keys too: a restore at the same keeper needs them.
	copyAll := BackupStore
	if newKeeper {
		copyAll = CopyStore
	}
	if _, _, err := copyAll(ctx, store.NewFolder(filepath.Join(from, "store")), st); err != nil {
		return nil, fmt.Errorf("the store: %w", err)
	}
	for _, f := range backupFiles(parts) {
		if f.from == "" || left[f.name] {
			continue
		}
		data, err := os.ReadFile(filepath.Join(from, f.name))
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		if err := os.MkdirAll(filepath.Dir(f.from), 0o700); err != nil {
			return nil, err
		}
		mode := os.FileMode(0o600)
		if filepath.Base(f.from) == "cert.pem" {
			mode = 0o644
		}
		if err := os.WriteFile(f.from, data, mode); err != nil {
			return nil, err
		}
	}
	return &list, nil
}
