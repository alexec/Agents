package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// Backups in the control plane's store (#1815): the archive is made in this machine's
// data folder as for a folder backup, sent in parts on channel 0, and deleted here. The
// control plane names the folder in the store from this host's proof; this host names
// only the backup. A restore reads the parts back into a file here and restores that.

// askStore is one backups.store/1 call of the control plane, its refusal in its own words.
func (d *Daemon) askStore(ctx context.Context, method string, params, out any) error {
	ask := d.askControl.Load()
	if ask == nil {
		return errors.New("this machine isn't on a control plane")
	}
	raw, err := (*ask)(ctx, method, params)
	var refused *controllink.AskError
	if errors.As(err, &refused) {
		return errors.New(refused.Message)
	}
	if err != nil {
		return fmt.Errorf("the control plane can't be reached: %w", err)
	}
	if out == nil {
		return nil
	}
	return json.Unmarshal(raw, out)
}

// storedBackups is every backup of this machine's owner in the store, newest first.
func (d *Daemon) storedBackups() ([]wire.Backup, error) {
	ctx, cancel := context.WithTimeout(d.ctx, backupStoreWait)
	defer cancel()
	var list wire.BackupStoreList
	if err := d.askStore(ctx, wire.CallBackupsStored.Name, wire.Empty{}, &list); err != nil {
		return []wire.Backup{}, fmt.Errorf("The control plane's backups can't be listed: %w", err)
	}
	if list.Backups == nil {
		list.Backups = []wire.Backup{}
	}
	return list.Backups, nil
}

// uploadFolder is where an archive waits to be sent: in the data folder, as it can be
// hundreds of MB.
func (d *Daemon) uploadFolder() string { return filepath.Join(d.Store.Loc.Root, "backups-upload") }

// storeBackup makes one backup and sends it to the store, which keeps the newest Keep.
func (d *Daemon) storeBackup() error {
	at := nowFunc().UTC()
	name := at.Format("20060102T150405Z")
	folder := d.uploadFolder()
	// What a backup cut off left: nothing here is wanted once its upload ends.
	os.RemoveAll(folder)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return err
	}
	defer os.RemoveAll(folder)
	archive := filepath.Join(folder, name+".tar.gz")
	m := backupManifest{Format: backupFormat, RootID: d.Store.RootID, Machine: macName(), MadeAt: wire.DateOf(at)}
	if err := d.writeBackupArchive(archive, &m, d.Store.Agents(), true); err != nil {
		return err
	}
	f, err := os.Open(archive)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	if fi.Size() > int64(backupPartBytes)*backupPartsMost {
		return fmt.Errorf("the backup is %d GB, more than the store takes (%d GB)", fi.Size()>>30, int64(backupPartBytes)*backupPartsMost>>30)
	}
	buf := make([]byte, backupPartBytes)
	var parts int64
	for {
		n, err := io.ReadFull(f, buf)
		if n > 0 {
			if err := d.askStore(d.ctx, wire.CallBackupsUpload.Name, wire.BackupStorePart{Name: name, Part: parts, Data: buf[:n]}, nil); err != nil {
				return fmt.Errorf("part %d didn't go up: %w", parts+1, err)
			}
			parts++
		}
		if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
			break
		}
		if err != nil {
			return err
		}
	}
	commit := wire.BackupStoreCommit{Name: name, Parts: parts, Machine: m.Machine, RootID: m.RootID, MadeAt: m.MadeAt,
		Bytes: fi.Size(), Agents: m.Agents, Keep: d.backupSettings().Keep}
	return d.askStore(d.ctx, wire.CallBackupsCommit.Name, commit, nil)
}

// restoreStored reads a backup's parts from the store into a file here, and restores it.
func (d *Daemon) restoreStored(id string) (wire.BackupRestoreResult, error) {
	backups, err := d.storedBackups()
	if err != nil {
		return wire.BackupRestoreResult{}, err
	}
	var listed *wire.Backup
	for i := range backups {
		if backups[i].ID == id {
			listed = &backups[i]
		}
	}
	if listed == nil {
		return wire.BackupRestoreResult{}, &Error{Code: CodeInvalidParams, Message: "There is no backup " + id + "."}
	}
	d.backupRestoring.Lock()
	defer d.backupRestoring.Unlock()
	folder := filepath.Join(d.Store.Loc.Root, "backups-download")
	os.RemoveAll(folder)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return wire.BackupRestoreResult{}, err
	}
	defer os.RemoveAll(folder)
	archive := filepath.Join(folder, "backup.tar.gz")
	f, err := os.OpenFile(archive, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return wire.BackupRestoreResult{}, err
	}
	var got int64
	for part := int64(0); got < listed.Bytes && part < backupPartsMost; part++ {
		var p wire.BackupStorePart
		if err := d.askStore(d.ctx, wire.CallBackupsDownload.Name, wire.BackupStorePartRequest{ID: id, Part: part}, &p); err != nil {
			f.Close()
			return wire.BackupRestoreResult{}, fmt.Errorf("part %d didn't come down: %w", part+1, err)
		}
		if len(p.Data) == 0 {
			break
		}
		if _, err := f.Write(p.Data); err != nil {
			f.Close()
			return wire.BackupRestoreResult{}, err
		}
		got += int64(len(p.Data))
	}
	if err := f.Close(); err != nil {
		return wire.BackupRestoreResult{}, err
	}
	if got != listed.Bytes {
		return wire.BackupRestoreResult{}, fmt.Errorf("the backup came down as %d bytes, not %d", got, listed.Bytes)
	}
	// This machine's own as the control plane says, from the host's proof.
	return d.restoreArchive(archive, listed.RootID, listed.ThisMachine, true, "")
}
