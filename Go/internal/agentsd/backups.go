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
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Backups of this machine's data (#1810): its agents, their transcripts, and its usage and
// time history, as one .tar.gz in a folder, never a secret. A backup goes in
// <folder>/<root id>/<made at>.tar.gz with a .json beside it that says what is in it, so a
// list reads no archive. The folder is <root>/backups unless the person names another (a
// second disk, a synced folder); the control plane's store comes later. A new machine of
// the same person that reads the same folder can restore one: its agents come back
// archived, and keep the root they were made under, so they are shown and never run here
// (refuseToRun).

const (
	backupSettingsFile = "backup-settings.json"
	backupKeepDefault  = 3
	backupKeepMost     = 10
	backupCheckEvery   = time.Hour
	backupFirstCheck   = 10 * time.Minute
	backupFormat       = 1
)

// backupAgentFiles are the files of an agent's folder a backup carries: the record, the
// transcript, and what the transcript points at. Anything else there is left out.
var backupAgentFiles = []string{"agent.json", "transcript.jsonl", "turns.jsonl", "app-tools.jsonl", "said.json"}

// backupRootFiles are the root's files a backup carries.
var backupRootFiles = []string{"usage-history.json", "time-history.json"}

type backupState struct {
	backupMu sync.Mutex
	// backupMaking is a backup being made; only one at a time.
	backupMaking bool
	backupError  string
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
	On(d, wire.CallBackupsMake, func(ctx context.Context, c *Client, _ wire.Empty) (wire.BackupState, error) {
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

func (d *Daemon) backupSettingsPath() string { return filepath.Join(d.Store.Loc.Root, backupSettingsFile) }

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
	s := wire.BackupState{Settings: d.backupSettings(), Folder: d.backupFolder(), Backups: d.listBackups(), Making: making}
	if lastError != "" {
		s.LastError = &lastError
	}
	return s
}

// listBackups is every backup in the folder, this machine's and others', newest first.
// Only one whose .json and archive are both there is listed.
func (d *Daemon) listBackups() []wire.Backup {
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
	for _, b := range d.listBackups() {
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
	d.backupMu.Lock()
	if d.backupMaking {
		d.backupMu.Unlock()
		return false
	}
	d.backupMaking = true
	d.backupMu.Unlock()
	Broadcast(d, wire.NotifyBackupsChanged, d.backupsState())
	safe.Go("backup", func() {
		_, err := d.makeBackup()
		d.backupMu.Lock()
		d.backupMaking = false
		d.backupError = ""
		if err != nil {
			d.backupError = "The last backup failed: " + err.Error()
			log.Printf("backup: %v", err)
		}
		d.backupMu.Unlock()
		Broadcast(d, wire.NotifyBackupsChanged, d.backupsState())
	})
	return true
}

// makeBackup writes one backup and keeps the newest Keep of this machine's.
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
	if err := d.writeBackupArchive(tmp, &m); err != nil {
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

func (d *Daemon) writeBackupArchive(path string, m *backupManifest) error {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	gz := gzip.NewWriter(f)
	tw := tar.NewWriter(gz)
	agents := d.Store.Agents()
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
			b, err := readWholeLines(p)
			if errors.Is(err, os.ErrNotExist) {
				continue
			} else if err != nil {
				return err
			}
			if err := addTarFile(tw, "agents/"+string(a.ID)+"/"+file, b, nowFunc()); err != nil {
				return err
			}
		}
	}
	for _, file := range backupRootFiles {
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

// readWholeLines reads a file; a .jsonl one up to its last whole line, so an entry being
// written as the backup reads it is left out rather than torn.
func readWholeLines(p string) ([]byte, error) {
	b, err := os.ReadFile(p)
	if err != nil || !strings.HasSuffix(p, ".jsonl") {
		return b, err
	}
	if i := bytes.LastIndexByte(b, '\n'); i >= 0 {
		return b[:i+1], nil
	}
	return b[:0], nil
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
	res := wire.BackupRestoreResult{}
	listed, ok := d.readBackup(id)
	if !ok {
		return res, &Error{Code: CodeInvalidParams, Message: "There is no backup " + id + "."}
	}
	archive, _, _ := d.backupPaths(id)
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
	// The root that made it, from the .json the list read: a record that names none is
	// stamped with it, so one from another machine is never run here.
	madeIn := listed.RootID
	// One agent's files are held until the next agent's begin: a backup is written agent
	// by agent. Its record goes in last, so a restore cut off leaves a folder with no
	// record, which the store does not load.
	var held wire.UUID
	files := map[string][]byte{}
	flush := func() error {
		if held == "" {
			return nil
		}
		restored, err := d.restoreAgent(held, files, madeIn)
		held, files = "", map[string][]byte{}
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
		b, err := io.ReadAll(io.LimitReader(tr, h.Size))
		if err != nil {
			return res, err
		}
		switch {
		case slices.Contains(backupRootFiles, h.Name):
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
			files[parts[2]] = b
		}
	}
	return res, flush()
}

// restoreAgent writes one agent's folder and saves its record archived; false when this
// machine has it already or the record can't be read.
func (d *Daemon) restoreAgent(id wire.UUID, files map[string][]byte, madeIn string) (bool, error) {
	raw, ok := files["agent.json"]
	if !ok || d.Store.Agent(id) != nil {
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
	// Made under the root that made the backup, if the record does not say: then a record
	// from another machine is never run here.
	if a.MadeInRoot == nil && madeIn != "" {
		a.MadeInRoot = &madeIn
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
	for name, b := range files {
		if name == "agent.json" {
			continue
		}
		if err := store.WriteAtomically(filepath.Join(folder, name), b, 0o644); err != nil {
			return false, err
		}
	}
	if err := d.Store.Save(a); err != nil {
		return false, err
	}
	d.tellChanged(a, nil)
	return true, nil
}

func backupAgentID(s string) bool {
	return len(s) == 36 && strings.Count(s, "-") == 4 && !strings.ContainsAny(s, `/\.`)
}
