package agentsd

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	goruntime "runtime"
	"slices"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Backups of this machine's data (#1810): its agents, their transcripts, and its usage and
// time history, as one .tar.gz, never a secret. It goes to one of two targets:
//
//   - a folder: <folder>/<root id>/<made at>.tar.gz with a .json beside it that says what
//     is in it, so a list reads no archive. The folder is <root>/backups unless the person
//     names another (a second disk, a synced folder). The Mac's default.
//   - the control plane's store (#1815): the archive is made here, then sent in parts of
//     backupPartBytes (backups/upload, then backups/commit) and deleted here. A server's
//     default, since a cloud machine that is deleted takes its data folder with it.
//
// A new machine of the same person that reads the same target can restore one: its agents
// come back archived, and keep the root they were made under, so they are shown and never
// run here (refuseToRun).

const (
	backupSettingsFile = "backup-settings.json"
	backupKeepDefault  = 3
	backupKeepMost     = 10
	backupCheckEvery   = time.Hour
	backupFirstCheck   = 10 * time.Minute
	backupFormat       = 1
	backupPartsMost    = 1024
	// backupStoreWait bounds a list of the store, so a control plane that does not answer
	// does not hold the state up.
	backupStoreWait = 10 * time.Second
	// backupEntryMost bounds one file in an archive: a transcript is far less, and an
	// archive made by hand (an import, #1001) can say any size. An agent's files go to disk
	// as they are read (#2428).
	backupEntryMost = 1 << 30
	// backupHeldMost bounds a file an archive's reader holds in memory: a record or a
	// root file, all small.
	backupHeldMost = 16 << 20
)

// backupPartBytes is one backups/upload: a JSON-RPC line of about 11 MB in base64, well
// under the link's 64 MB. A test makes it smaller.
var backupPartBytes = 8 << 20

// backupAgentFiles are the files of an agent's folder a backup carries: the record, the
// transcript, and what the transcript points at. Anything else there is left out.
var backupAgentFiles = []string{"agent.json", "transcript.jsonl", "turns.jsonl", "app-tools.jsonl", "said.json"}

// backupRootFiles are the root's files a backup carries.
var backupRootFiles = []string{"usage-history.json", "time-history.json", erasedFile}

type backupState struct {
	backupMu sync.Mutex
	// backupMaking is a backup being made; only one at a time.
	backupMaking bool
	backupError  string
	// backupDone is closed when the backup being made ends.
	backupDone chan struct{}
	// backupRestoring is held by a restore from the store: one download folder.
	backupRestoring sync.Mutex
}

// backupManifest is the .json beside a backup, and its first entry.
type backupManifest struct {
	Format  int       `json:"format"`
	RootID  string    `json:"rootID"`
	Machine string    `json:"machine"`
	MadeAt  wire.Date `json:"madeAt"`
	Agents  int64     `json:"agents"`
	Bytes   int64     `json:"bytes,omitempty"`
}

func (d *Daemon) registerBackups() {
	On(d, wire.CallBackupsState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.BackupState, error) {
		return d.backupsState(), nil
	})
	On(d, wire.CallBackupsConfigure, func(ctx context.Context, c *Client, s wire.BackupSettings) (wire.BackupState, error) {
		if err := d.configureBackups(s); err != nil {
			return wire.BackupState{}, err
		}
		st := d.backupsState()
		Broadcast(d, wire.NotifyBackupsChanged, st)
		return st, nil
	})
	On(d, wire.CallBackupsMake, func(ctx context.Context, c *Client, r wire.BackupMakeRequest) (wire.BackupState, error) {
		// A provider's delete waits for the backup (#1815); a person's Back Up Now does not.
		if r.Wait != nil && *r.Wait {
			if err := d.backupAndWait(ctx); err != nil {
				return wire.BackupState{}, &Error{Code: wire.FailureBusy, Message: "The backup failed: " + err.Error()}
			}
			return d.backupsState(), nil
		}
		if !d.startBackup() {
			return wire.BackupState{}, &Error{Code: wire.FailureBusy, Message: "A backup is already being made."}
		}
		return d.backupsState(), nil
	})
	On(d, wire.CallBackupsRestore, func(ctx context.Context, c *Client, r wire.BackupRestoreRequest) (wire.BackupRestoreResult, error) {
		return d.restoreBackup(r.ID)
	})
}

// MARK: settings

func (d *Daemon) backupSettingsPath() string {
	return filepath.Join(d.Store.Loc.Root, backupSettingsFile)
}

// backupSettings is backup-settings.json, this machine's own: a value it cannot read is
// the default, so a file from a later build never turns backups off.
func (d *Daemon) backupSettings() wire.BackupSettings {
	s := wire.BackupSettings{Every: wire.BackupEveryDaily, Keep: backupKeepDefault}
	if b, err := os.ReadFile(d.backupSettingsPath()); err == nil {
		var read wire.BackupSettings
		if json.Unmarshal(b, &read) == nil {
			s.Every = read.Every
			if read.Keep >= 1 && read.Keep <= backupKeepMost {
				s.Keep = read.Keep
			}
			if read.Folder != nil && filepath.IsAbs(*read.Folder) {
				s.Folder = read.Folder
			}
			s.Target = read.Target
		}
	}
	if s.Every == "" {
		s.Every = wire.BackupEveryDaily
	}
	return s
}

func (d *Daemon) configureBackups(s wire.BackupSettings) error {
	if s.Keep < 1 || s.Keep > backupKeepMost {
		return &Error{Code: CodeInvalidParams, Message: fmt.Sprintf("Keep 1 to %d backups.", backupKeepMost)}
	}
	if s.Folder != nil {
		if *s.Folder == "" {
			s.Folder = nil
		} else if !filepath.IsAbs(*s.Folder) {
			return &Error{Code: CodeInvalidParams, Message: "The backup folder must be a full path."}
		} else {
			clean := filepath.Clean(*s.Folder)
			s.Folder = &clean
		}
	}
	b, err := json.MarshalIndent(s, "", "  ")
	if err != nil {
		return err
	}
	if err := store.WriteAtomically(d.backupSettingsPath(), b, 0o600); err != nil {
		return err
	}
	// Fewer kept takes effect now, not at the next backup.
	d.pruneBackups(s.Keep)
	return nil
}

// backupTarget is where backups go: the settings', else the control plane's store for a
// server linked to one (a cloud machine's data folder goes with the machine), else the
// folder.
func (d *Daemon) backupTarget() wire.BackupTarget {
	if t := d.backupSettings().Target; t != nil {
		if *t == wire.BackupTargetControl && d.askControl.Load() == nil {
			return wire.BackupTargetFolder
		}
		return *t
	}
	if d.askControl.Load() != nil && goruntime.GOOS != "darwin" {
		return wire.BackupTargetControl
	}
	return wire.BackupTargetFolder
}

func (d *Daemon) backupFolder() string {
	if f := d.backupSettings().Folder; f != nil {
		return *f
	}
	return filepath.Join(d.Store.Loc.Root, "backups")
}

// MARK: the list

func (d *Daemon) backupsState() wire.BackupState {
	d.backupMu.Lock()
	making, lastError := d.backupMaking, d.backupError
	d.backupMu.Unlock()
	settings := d.backupSettings()
	target := d.backupTarget()
	settings.Target = &target
	backups, err := d.listBackups()
	if err != nil && lastError == "" {
		lastError = err.Error()
	}
	s := wire.BackupState{Settings: settings, Folder: d.backupFolder(), Backups: backups, Making: making,
		CanUseControl: new(d.askControl.Load() != nil)}
	if lastError != "" {
		s.LastError = &lastError
	}
	if target == wire.BackupTargetFolder && d.backupOnSameDisk() {
		s.SameDisk = new(true)
	}
	return s
}

// backupOnSameDisk says the backup folder is on the disk of this machine's data, and not a
// synced folder (#2139): a backup there undoes a mistake, but goes with the disk.
func (d *Daemon) backupOnSameDisk() bool {
	folder := d.backupFolder()
	return !syncedFolder(folder) && sameDevice(folder, d.Store.Loc.Root)
}

// syncedFolder is a folder that a Mac syncs to another place: iCloud Drive, or a File
// Provider's (Dropbox, Google Drive, OneDrive), which are on the Mac's own disk.
func syncedFolder(path string) bool {
	path = filepath.ToSlash(path)
	return strings.Contains(path, "/Library/Mobile Documents/") || strings.Contains(path, "/Library/CloudStorage/")
}

// sameDevice says two paths are on one device, each read where it is, or where its nearest
// folder that is there is. A test stands in for a second disk.
var sameDevice = func(a, b string) bool {
	da, okA := deviceOf(a)
	db, okB := deviceOf(b)
	return okA && okB && da == db
}

func deviceOf(path string) (uint64, bool) {
	for {
		if info, err := os.Stat(path); err == nil {
			if st, ok := info.Sys().(*syscall.Stat_t); ok {
				return uint64(st.Dev), true //nolint:unconvert // int32 on darwin
			}
			return 0, false
		}
		parent := filepath.Dir(path)
		if parent == path {
			return 0, false
		}
		path = parent
	}
}

// listBackups is every backup in the target, this machine's and others', newest first.
func (d *Daemon) listBackups() ([]wire.Backup, error) {
	if d.backupTarget() == wire.BackupTargetControl {
		return d.storedBackups()
	}
	return d.folderBackups(), nil
}

// folderBackups is every backup in the folder, this machine's and others', newest first.
// Only one whose .json and archive are both there is listed.
func (d *Daemon) folderBackups() []wire.Backup {
	folder := d.backupFolder()
	out := []wire.Backup{}
	roots, _ := os.ReadDir(folder)
	for _, r := range roots {
		if !r.IsDir() || strings.HasPrefix(r.Name(), ".") {
			continue
		}
		files, _ := os.ReadDir(filepath.Join(folder, r.Name()))
		for _, f := range files {
			name, ok := strings.CutSuffix(f.Name(), ".tar.gz")
			if !ok || strings.HasPrefix(name, ".") {
				continue
			}
			b, ok := d.readBackup(r.Name() + "/" + name)
			if ok {
				out = append(out, b)
			}
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].MadeAt != out[j].MadeAt {
			return out[i].MadeAt > out[j].MadeAt
		}
		return out[i].ID > out[j].ID
	})
	return out
}

// backupPaths are a backup's archive and its .json, from its id <root id>/<name>; false
// for an id that is not one.
func (d *Daemon) backupPaths(id string) (archive, manifest string, ok bool) {
	root, name, found := strings.Cut(id, "/")
	if !found || root == "" || name == "" || strings.ContainsAny(name, `/\`) || strings.ContainsAny(root, `/\`) ||
		strings.HasPrefix(root, ".") || strings.HasPrefix(name, ".") {
		return "", "", false
	}
	base := filepath.Join(d.backupFolder(), root, name)
	return base + ".tar.gz", base + ".json", true
}

func (d *Daemon) readBackup(id string) (wire.Backup, bool) {
	archive, manifest, ok := d.backupPaths(id)
	if !ok {
		return wire.Backup{}, false
	}
	fi, err := os.Stat(archive)
	if err != nil || !fi.Mode().IsRegular() {
		return wire.Backup{}, false
	}
	b, err := os.ReadFile(manifest)
	if err != nil {
		return wire.Backup{}, false
	}
	var m backupManifest
	if json.Unmarshal(b, &m) != nil || m.RootID == "" {
		return wire.Backup{}, false
	}
	return wire.Backup{ID: id, Machine: m.Machine, RootID: m.RootID, MadeAt: m.MadeAt, Bytes: fi.Size(), Agents: m.Agents,
		ThisMachine: m.RootID == d.Store.RootID}, true
}

// MARK: making one

// StartBackups makes a backup when the last one of this machine is older than the
// schedule says, checked a few minutes after the start, out of its way, and every hour.
func (d *Daemon) StartBackups() { safe.Go("backups", d.backupClock) }

func (d *Daemon) backupClock() {
	wait := backupFirstCheck
	for {
		select {
		case <-d.ctx.Done():
			return
		case <-time.After(wait):
		}
		d.backupIfDue()
		wait = backupCheckEvery
	}
}

func (d *Daemon) backupIfDue() {
	every := map[wire.BackupEvery]time.Duration{wire.BackupEveryDaily: 24 * time.Hour, wire.BackupEveryWeekly: 7 * 24 * time.Hour}
	gap, on := every[d.backupSettings().Every]
	if !on {
		return
	}
	backups, err := d.listBackups()
	if err != nil {
		return
	}
	for _, b := range backups {
		if b.ThisMachine {
			if nowFunc().Sub(b.MadeAt.Time()) < gap {
				return
			}
			break
		}
	}
	d.startBackup()
}

// startBackup makes a backup off the caller's goroutine and says the state when it ends;
// false when one is being made already.
func (d *Daemon) startBackup() bool {
	if !d.claimBackup() {
		return false
	}
	safe.Go("backup", func() { d.runBackup() })
	return true
}

// backupAndWait makes a backup and answers when it is made: after the one being made
// ends, if there is one, as that one may be older than what the caller wants kept.
func (d *Daemon) backupAndWait(ctx context.Context) error {
	for {
		d.backupMu.Lock()
		done := d.backupDone
		d.backupMu.Unlock()
		if d.claimBackup() {
			return d.runBackup()
		}
		if done == nil {
			continue
		}
		select {
		case <-done:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
}

// claimBackup marks a backup as being made; false when one is already.
func (d *Daemon) claimBackup() bool {
	d.backupMu.Lock()
	if d.backupMaking {
		d.backupMu.Unlock()
		return false
	}
	d.backupMaking = true
	d.backupDone = make(chan struct{})
	d.backupMu.Unlock()
	Broadcast(d, wire.NotifyBackupsChanged, d.backupsState())
	return true
}

// runBackup makes the backup claimBackup claimed, and says the state when it ends.
func (d *Daemon) runBackup() error {
	var err error
	if d.backupTarget() == wire.BackupTargetControl {
		err = d.storeBackup()
	} else {
		_, err = d.makeBackup()
	}
	d.backupMu.Lock()
	d.backupMaking = false
	d.backupError = ""
	if err != nil {
		d.backupError = "The last backup failed: " + err.Error()
		log.Printf("backup: %v", err)
	}
	close(d.backupDone)
	d.backupMu.Unlock()
	Broadcast(d, wire.NotifyBackupsChanged, d.backupsState())
	return err
}

// makeBackup writes one backup to the folder and keeps the newest Keep of this machine's.
func (d *Daemon) makeBackup() (wire.Backup, error) {
	at := nowFunc().UTC()
	name := at.Format("20060102T150405Z")
	id := d.Store.RootID + "/" + name
	archive, manifest, ok := d.backupPaths(id)
	if !ok {
		return wire.Backup{}, errors.New("this machine's root has no id")
	}
	if err := os.MkdirAll(filepath.Dir(archive), 0o700); err != nil {
		return wire.Backup{}, err
	}
	m := backupManifest{Format: backupFormat, RootID: d.Store.RootID, Machine: macName(), MadeAt: wire.DateOf(at)}
	tmp := filepath.Join(filepath.Dir(archive), "."+name+".tar.gz.tmp")
	if err := d.writeBackupArchive(tmp, &m, d.Store.Agents(), true); err != nil {
		os.Remove(tmp)
		return wire.Backup{}, err
	}
	if fi, err := os.Stat(tmp); err == nil {
		m.Bytes = fi.Size()
	}
	if err := os.Rename(tmp, archive); err != nil {
		os.Remove(tmp)
		return wire.Backup{}, err
	}
	b, _ := json.MarshalIndent(m, "", "  ")
	if err := store.WriteAtomically(manifest, b, 0o600); err != nil {
		os.Remove(archive)
		return wire.Backup{}, err
	}
	d.pruneBackups(d.backupSettings().Keep)
	made, _ := d.readBackup(id)
	return made, nil
}

// writeBackupArchive writes agents to path, with the root's files when withRoot: a backup
// carries them, an export of some agents (#1001) does not.
func (d *Daemon) writeBackupArchive(path string, m *backupManifest, agents []wire.Agent, withRoot bool) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	m.Agents = int64(len(agents))
	head, _ := json.Marshal(m)
	if err := addTarFile(tw, "manifest.json", head, m.MadeAt.Time()); err != nil {
		return err
	}
	for _, a := range agents {
		if err := d.ctx.Err(); err != nil {
			return err
		}
		for _, file := range backupAgentFiles {
			p := filepath.Join(d.Store.Loc.Agent(string(a.ID)), file)
			err := addTarFileFrom(tw, "agents/"+string(a.ID)+"/"+file, p)
			if errors.Is(err, os.ErrNotExist) {
				continue
			} else if err != nil {
				return err
			}
		}
	}
	for _, file := range backupRootFiles {
		if !withRoot {
			break
		}
		b, err := os.ReadFile(filepath.Join(d.Store.Loc.Root, file))
		if errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			return err
		}
		if err := addTarFile(tw, file, b, nowFunc()); err != nil {
			return err
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	if err := gz.Close(); err != nil {
		return err
	}
	return f.Sync()
}

// addTarFileFrom copies the file at p into the archive as name, streamed (#2428): a
// .jsonl one up to its last whole line, so an entry being written as the backup reads it
// is left out rather than torn.
func addTarFileFrom(tw *tar.Writer, name, p string) error {
	f, err := os.Open(p)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	size := fi.Size()
	if strings.HasSuffix(p, ".jsonl") {
		if size, err = wholeLinesSize(f, size); err != nil {
			return err
		}
	}
	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: size, ModTime: nowFunc(), Typeflag: tar.TypeReg}); err != nil {
		return err
	}
	_, err = io.CopyN(tw, io.NewSectionReader(f, 0, size), size)
	return err
}

// wholeLinesSize is how much of f's first size bytes ends at a newline: it reads back
// from the end a block at a time.
func wholeLinesSize(f *os.File, size int64) (int64, error) {
	buf := make([]byte, 64<<10)
	for end := size; end > 0; {
		start := max(end-int64(len(buf)), 0)
		b := buf[:end-start]
		if _, err := f.ReadAt(b, start); err != nil {
			return 0, err
		}
		if i := bytes.LastIndexByte(b, '\n'); i >= 0 {
			return start + int64(i) + 1, nil
		}
		end = start
	}
	return 0, nil
}

func addTarFile(tw *tar.Writer, name string, b []byte, at time.Time) error {
	if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o600, Size: int64(len(b)), ModTime: at, Typeflag: tar.TypeReg}); err != nil {
		return err
	}
	_, err := tw.Write(b)
	return err
}

// pruneBackups keeps the newest keep of this machine's backups and deletes the rest,
// with any a cut-off backup left half-written. Other machines' backups are theirs.
func (d *Daemon) pruneBackups(keep int64) {
	mine := filepath.Join(d.backupFolder(), d.Store.RootID)
	files, _ := os.ReadDir(mine)
	var names []string
	for _, f := range files {
		if strings.HasPrefix(f.Name(), ".") && strings.HasSuffix(f.Name(), ".tmp") {
			if fi, err := f.Info(); err == nil && nowFunc().Sub(fi.ModTime()) > 24*time.Hour {
				os.Remove(filepath.Join(mine, f.Name()))
			}
			continue
		}
		if name, ok := strings.CutSuffix(f.Name(), ".tar.gz"); ok {
			names = append(names, name)
		}
	}
	// Names are their times, so they sort oldest first.
	slices.Sort(names)
	for len(names) > int(keep) {
		os.Remove(filepath.Join(mine, names[0]+".json"))
		os.Remove(filepath.Join(mine, names[0]+".tar.gz"))
		names = names[1:]
	}
}

// MARK: restoring one

// restoreBackup brings a backup's agents back, archived. One this machine has already is
// skipped, never overwritten. The usage and time history come back only to a machine
// that has none of its own.
func (d *Daemon) restoreBackup(id string) (wire.BackupRestoreResult, error) {
	if d.backupTarget() == wire.BackupTargetControl {
		return d.restoreStored(id)
	}
	listed, ok := d.readBackup(id)
	if !ok {
		return wire.BackupRestoreResult{}, &Error{Code: CodeInvalidParams, Message: "There is no backup " + id + "."}
	}
	archive, _, _ := d.backupPaths(id)
	// The folder, not the manifest, says whose backup it is.
	folder, _, _ := strings.Cut(id, "/")
	return d.restoreArchive(archive, listed.RootID, folder == d.Store.RootID, true, "")
}

// restoredElsewhere is the root a record from another machine's backup is stamped with
// when that backup names this root: never this one, so it is never run here.
const restoredElsewhere = "restored"

// restoreArchive restores the archive at path; madeIn is the root that made it, and mine
// whether it is this machine's own backup. An import (#1001) takes no root files
// (withRoot false): an export has none, and one made by hand must not change this
// machine's history or its erased list. into, when not empty, is the folder every
// agent is put in (#2389); empty keeps each agent's own.
func (d *Daemon) restoreArchive(archive, madeIn string, mine, withRoot bool, into string) (wire.BackupRestoreResult, error) {
	res := wire.BackupRestoreResult{}
	f, err := os.Open(archive)
	if err != nil {
		return res, err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return res, fmt.Errorf("the backup can't be read: %w", err)
	}
	tr := tar.NewReader(gz)
	// madeIn, the root that made it, is from the .json the list read. A record from
	// another machine's backup is stamped with it, whatever it says, so it is never run
	// here.
	// One agent's files are held until the next agent's begin: a backup is written agent
	// by agent. Its record goes in last, so a restore cut off leaves a folder with no
	// record, which the store does not load. Its other files wait in staging, on disk, not
	// in memory (#2428).
	staging, err := os.MkdirTemp(d.Store.Loc.Root, ".restore-")
	if err != nil {
		return res, err
	}
	defer os.RemoveAll(staging)
	var held wire.UUID
	var record []byte
	files := map[string]string{}
	drop := func() {
		for _, p := range files {
			os.Remove(p)
		}
		held, record, files = "", nil, map[string]string{}
	}
	// An agent this machine deleted is never restored (#1001).
	d.erasures.mu.Lock()
	erased := d.readErasedLocked()
	d.erasures.mu.Unlock()
	flush := func() error {
		if held == "" {
			return nil
		}
		if _, gone := erased[held]; gone {
			drop()
			res.Skipped++
			return nil
		}
		restored, err := d.restoreAgent(held, record, files, madeIn, mine, into)
		drop()
		if err != nil {
			return err
		}
		if restored {
			res.Restored++
		} else {
			res.Skipped++
		}
		return nil
	}
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return res, fmt.Errorf("the backup can't be read: %w", err)
		}
		if h.Typeflag != tar.TypeReg {
			continue
		}
		if !withRoot && !strings.HasPrefix(h.Name, "agents/") {
			continue
		}
		if h.Size > backupEntryMost {
			return res, fmt.Errorf("the backup can't be read: %s is more than %d MB", h.Name, backupEntryMost>>20)
		}
		switch {
		case h.Name == erasedFile:
			b, err := readHeld(tr, h)
			if err != nil {
				return res, err
			}
			d.takeErasedList(b)
		case slices.Contains(backupRootFiles, h.Name):
			b, err := readHeld(tr, h)
			if err != nil {
				return res, err
			}
			p := filepath.Join(d.Store.Loc.Root, h.Name)
			if _, err := os.Stat(p); errors.Is(err, os.ErrNotExist) {
				if err := store.WriteAtomically(p, b, 0o600); err != nil {
					return res, err
				}
			}
		case strings.HasPrefix(h.Name, "agents/"):
			parts := strings.Split(h.Name, "/")
			if len(parts) != 3 || !slices.Contains(backupAgentFiles, parts[2]) || !backupAgentID(parts[1]) {
				continue
			}
			id := wire.UUID(strings.ToUpper(parts[1]))
			if id != held {
				if err := flush(); err != nil {
					return res, err
				}
				held = id
			}
			if parts[2] == "agent.json" {
				if record, err = readHeld(tr, h); err != nil {
					return res, err
				}
				continue
			}
			p := filepath.Join(staging, parts[2])
			if err := writeStaged(p, tr, h.Size); err != nil {
				return res, err
			}
			files[parts[2]] = p
		}
	}
	return res, flush()
}

// restoreAgent writes one agent's folder and saves its record archived; false when this
// machine has it already or the record can't be read. into, when not empty, is the folder
// it is put in: its worktree, which was on the machine that made it, is left behind.
func (d *Daemon) restoreAgent(id wire.UUID, raw []byte, files map[string]string, madeIn string, mine bool, into string) (bool, error) {
	if raw == nil || d.Store.Agent(id) != nil {
		return false, nil
	}
	if _, err := os.Stat(d.Store.Loc.Record(string(id))); err == nil {
		return false, nil
	}
	var a wire.Agent
	if err := diskjson.Unmarshal(raw, &a); err != nil {
		return false, nil
	}
	a.ID = id
	// A backup from before #2617 names the worktree's folder "project" (#2709).
	store.FillFolder(&a, raw)
	if into != "" {
		a.Cwd, a.Worktree = store.FolderURL(into), nil
	}
	// Made under the root that made the backup. This machine's own record keeps what it
	// says; one from another machine never names this root, and brings no MCP servers and
	// no runtime session or account: those belong to the set-up that made it.
	if mine {
		if a.MadeInRoot == nil && madeIn != "" {
			a.MadeInRoot = &madeIn
		}
	} else {
		from := madeIn
		if from == "" || from == d.Store.RootID {
			from = restoredElsewhere
		}
		a.MadeInRoot = &from
		a.McpServers, a.RuntimeSessionID, a.AccountID = nil, nil, nil
	}
	if a.State != wire.AgentStateArchived {
		r := wire.AgentArchivedReasonByUser
		a.State, a.ArchivedReason = wire.AgentStateArchived, &r
		if a.EndedReason == nil {
			e := wire.EndedReasonImported
			a.EndedReason = &e
		}
	}
	// Archived now, so retention keeps it its full time from the restore.
	t := now()
	a.ArchivedAt = &t
	a.EventWait, a.PendingMove, a.ArchiveRequest, a.AfterTurn = nil, nil, nil, nil
	folder := d.Store.Loc.Agent(string(id))
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return false, err
	}
	for name, p := range files {
		if err := os.Rename(p, filepath.Join(folder, name)); err != nil {
			return false, err
		}
	}
	if err := d.Store.Save(a); err != nil {
		return false, err
	}
	d.tellChanged(a, nil)
	return true, nil
}

// readHeld reads an archive's entry into memory: a record or a root file, at most
// backupHeldMost.
func readHeld(tr *tar.Reader, h *tar.Header) ([]byte, error) {
	if h.Size > backupHeldMost {
		return nil, fmt.Errorf("the backup can't be read: %s is more than %d MB", h.Name, backupHeldMost>>20)
	}
	return io.ReadAll(io.LimitReader(tr, h.Size))
}

// writeStaged copies an archive's entry of size bytes to a new file at p, synced, so the
// rename into the agent's folder leaves a whole file.
func writeStaged(p string, r io.Reader, size int64) error {
	f, err := os.OpenFile(p, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, err = io.CopyN(f, r, size)
	if err == nil {
		err = f.Sync()
	}
	if cerr := f.Close(); err == nil {
		err = cerr
	}
	return err
}

func backupAgentID(s string) bool {
	return len(s) == 36 && strings.Count(s, "-") == 4 && !strings.ContainsAny(s, `/\.`)
}
