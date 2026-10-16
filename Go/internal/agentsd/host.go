package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The host's own plumbing, as the Swift host serves it on a server: the one answer a
// client gets on connecting, status and quitting, the disk, the person's settings it
// reads, and the files a client puts in (an agent's artifact, a project's drop box).

// Quit, when set, ends the host (daemon/quit): cmd/agentsd stops serving and lets go.
type quitState struct {
	Quit func()
	// disk is each mount's level, and the alarms last said.
	diskMu     sync.Mutex
	diskLevels map[string]wire.DiskLevel
	diskAlarms []wire.DiskAlarm
}

func (d *Daemon) registerHost() {
	On(d, wire.CallClientCatchUp, func(ctx context.Context, c *Client, r wire.CatchUpRequest) (wire.CatchUpSnapshot, error) {
		return d.catchUp(r), nil
	})
	On(d, wire.CallDaemonStatus, func(ctx context.Context, c *Client, _ wire.Empty) (wire.DaemonStatus, error) {
		n := int64(d.holdingRuntimes())
		return wire.DaemonStatus{TurnsInFlight: n, AgentsLive: n}, nil
	})
	On(d, wire.CallDaemonQuit, func(ctx context.Context, c *Client, r wire.QuitRequest) (wire.Empty, error) {
		if r.StopAgents {
			for _, l := range d.everyLive() {
				l.cancel()
			}
		} else if d.holdingRuntimes() > 0 {
			return wire.Empty{}, &Error{Code: wire.FailureBusy, Message: "An agent here is mid-turn. Ask again when it has finished."}
		}
		if d.Quit != nil {
			// After the answer has gone.
			time.AfterFunc(200*time.Millisecond, d.Quit)
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallDiskState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.DiskState, error) {
		return d.diskState(), nil
	})
	On(d, wire.CallSandboxState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.SandboxSettings, error) {
		return d.sandboxSettings(), nil
	})
	On(d, wire.CallClientPermissionsState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.ClientPermissionSettings, error) {
		return d.clientPermissions(), nil
	})
	On(d, wire.CallRetentionState, func(ctx context.Context, c *Client, _ wire.Empty) (wire.RetentionState, error) {
		return d.retentionState(), nil
	})
	On(d, wire.CallStoreNotes, func(ctx context.Context, c *Client, _ wire.Empty) (wire.StoreNotes, error) {
		// No file of this host's has been set aside.
		return wire.StoreNotes{Notes: []string{}}, nil
	})
	// A server keeps no devices: an unknown one is nothing to note (DaemonCore.identify).
	On(d, wire.CallSurfaceIdentify, func(ctx context.Context, c *Client, _ wire.SurfaceIdentification) (wire.Empty, error) {
		return wire.Empty{}, nil
	})
	// Which device a control-plane channel is for; this host answers every channel alike.
	On(d, wire.CallConnectionBindDevice, func(ctx context.Context, c *Client, _ wire.DeviceBinding) (wire.Empty, error) {
		return wire.Empty{}, nil
	})
	// A connection that will carry the person's mail; this host posts none yet.
	On(d, wire.CallMailboxCarry, func(ctx context.Context, c *Client, _ wire.Empty) (wire.Empty, error) {
		return wire.Empty{}, nil
	})
	On(d, wire.CallArtifactWrite, func(ctx context.Context, c *Client, r wire.ArtifactWriteRequest) (wire.Empty, error) {
		return wire.Empty{}, d.writeArtifact(r)
	})
	On(d, wire.CallDropboxPut, func(ctx context.Context, c *Client, r wire.DropboxPutRequest) (wire.DropboxPutResponse, error) {
		return d.putInDropbox(r)
	})
}

// holdingRuntimes is DaemonStatus's count: agents starting, running or waiting on the person.
func (d *Daemon) holdingRuntimes() int {
	n := 0
	for _, a := range d.Store.Agents() {
		switch a.State {
		case wire.AgentStateStarting, wire.AgentStateRunning, wire.AgentStateWaitingOnUser:
			n++
		}
	}
	return n
}

// catchUp is DaemonCore.catchUp: everything a client shows first, in one answer (#175).
func (d *Daemon) catchUp(r wire.CatchUpRequest) wire.CatchUpSnapshot {
	list := wire.ListRequest{Lean: true}
	if r.Agents != nil {
		list = *r.Agents
	}
	disk := d.diskState()
	notes := wire.StoreNotes{Notes: []string{}}
	milestones := wire.Milestones{Earned: []wire.EarnedMilestone{}}
	s := wire.CatchUpSnapshot{Projects: d.projects(false), Agents: d.listAgents(list), Permissions: d.pendingPermissions(),
		Elicitations: d.pendingElicitations(),
		// Needs and their deliveries come with attention/pending.
		Attention: wire.AttentionPending{Needs: []wire.Need{}, Deliveries: []wire.AttentionDelivery{}},
		Resuming:  []wire.UUID{}, Disk: &disk, StoreNotes: &notes, Milestones: &milestones}
	for _, part := range r.Parts {
		if part == "pins" {
			s.Pins = []wire.ProjectPins{}
			for _, p := range d.projects(false) {
				if pp := d.projectPins(store.FolderPath(p.Project.Folder)); len(pp.Pins)+len(pp.Sessions)+len(pp.Workflows) > 0 {
					s.Pins = append(s.Pins, pp)
				}
			}
		}
	}
	return s
}

// MARK: settings the window reads (personalSettings)

func (d *Daemon) readSetting(name string, v any) {
	if b, err := os.ReadFile(filepath.Join(d.SettingsDir, name)); err == nil {
		json.Unmarshal(b, v)
	}
}

func (d *Daemon) sandboxSettings() wire.SandboxSettings {
	var raw struct {
		Defaults map[string]string `json:"defaults"`
	}
	d.readSetting("sandbox.json", &raw)
	s := wire.SandboxSettings{Defaults: map[string]wire.SandboxChoice{}}
	for runtime, v := range raw.Defaults {
		// "runtime" is said by leaving the entry out; a value not known reads as it.
		if v == "on" || v == "off" {
			s.Defaults[runtime] = wire.SandboxChoice(v)
		}
	}
	return s
}

func clientPermissionMode(v string) wire.ClientPermissionMode {
	if v == "alwaysApprove" || v == "autoReview" {
		return wire.ClientPermissionModeAlwaysApprove
	}
	return wire.ClientPermissionModeDefault
}

func (d *Daemon) clientPermissions() wire.ClientPermissionSettings {
	var raw struct{ Cursor, Grok, Opencode string }
	d.readSetting("client-permissions.json", &raw)
	return wire.ClientPermissionSettings{Cursor: clientPermissionMode(raw.Cursor), Grok: clientPermissionMode(raw.Grok),
		Opencode: clientPermissionMode(raw.Opencode)}
}

func (d *Daemon) retentionState() wire.RetentionState {
	var raw struct {
		KeepFor string `json:"keepFor"`
	}
	d.readSetting("retention.json", &raw)
	keep := wire.RetentionKeepFor(raw.KeepFor)
	switch keep {
	case wire.RetentionKeepForDays7, wire.RetentionKeepForDays14, wire.RetentionKeepForDays30, wire.RetentionKeepForDays90,
		wire.RetentionKeepForForever:
	default:
		keep = wire.RetentionKeepForDays30
	}
	s := wire.RetentionState{Settings: wire.RetentionSettings{KeepFor: keep}}
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived {
			s.ArchivedCount++
			s.ArchivedBytes += folderBytes(d.Store.Loc.Agent(string(a.ID)))
		}
	}
	return s
}

// folderBytes is the size of the regular files under a folder (ArchiveIndex on Linux).
func folderBytes(folder string) int64 {
	var n int64
	filepath.WalkDir(folder, func(_ string, e os.DirEntry, err error) error {
		if err == nil && e.Type().IsRegular() {
			if fi, err := e.Info(); err == nil {
				n += fi.Size()
			}
		}
		return nil
	})
	return n
}

// MARK: the disk (DaemonCore+Disk)

const gigabyte = 1_000_000_000

type diskThresholds struct{ lowGB, lowPercent, criticalGB float64 }

func (t diskThresholds) lowLine(total int64) int64 {
	return max(int64(t.lowGB*gigabyte), int64(float64(total)/100*t.lowPercent))
}
func (t diskThresholds) criticalLine() int64 { return int64(t.criticalGB * gigabyte) }

// projectThresholds is a project's .agents/project.json "diskSpace", where it says one.
func projectThresholds(folder string) (diskThresholds, bool) {
	b, err := os.ReadFile(filepath.Join(folder, ".agents", "project.json"))
	if err != nil {
		return diskThresholds{}, false
	}
	var p struct {
		DiskSpace *struct {
			LowGB      *float64 `json:"lowGB"`
			LowPercent *float64 `json:"lowPercent"`
			CriticalGB *float64 `json:"criticalGB"`
		} `json:"diskSpace"`
	}
	if json.Unmarshal(b, &p) != nil || p.DiskSpace == nil {
		return diskThresholds{}, false
	}
	t := diskThresholds{20, 5, 2}
	if p.DiskSpace.LowGB != nil {
		t.lowGB = *p.DiskSpace.LowGB
	}
	if p.DiskSpace.LowPercent != nil {
		t.lowPercent = *p.DiskSpace.LowPercent
	}
	if p.DiskSpace.CriticalGB != nil {
		t.criticalGB = *p.DiskSpace.CriticalGB
	}
	return t, true
}

func diskMargin(line int64) int64 { return max(line/10, gigabyte) }

// nextDiskLevel is DiskSpace.next: worse at once, better only past the line and a margin.
func nextDiskLevel(was wire.DiskLevel, free, low, critical int64) wire.DiskLevel {
	rank := map[wire.DiskLevel]int{wire.DiskLevelOk: 0, wire.DiskLevelLow: 1, wire.DiskLevelCritical: 2}
	raw := wire.DiskLevelOk
	if free < critical {
		raw = wire.DiskLevelCritical
	} else if free < low {
		raw = wire.DiskLevelLow
	}
	if was == "" {
		was = wire.DiskLevelOk
	}
	if rank[raw] > rank[was] {
		return raw
	}
	level := was
	if level == wire.DiskLevelCritical && free >= critical+diskMargin(critical) {
		level = wire.DiskLevelLow
	}
	if level == wire.DiskLevelLow && free >= low+diskMargin(low) {
		level = wire.DiskLevelOk
	}
	if rank[raw] > rank[level] {
		level = raw
	}
	return level
}

// checkDisk looks at the root's and every project's disk, and says disk/changed when the
// alarms change.
func (d *Daemon) checkDisk() {
	type mount struct {
		reading wire.DiskReading
		t       diskThresholds
		set     bool
	}
	mounts := map[string]*mount{}
	look := func(folder string, t diskThresholds, has bool) {
		var st syscall.Statfs_t
		var fi syscall.Stat_t
		if syscall.Statfs(folder, &st) != nil || syscall.Stat(folder, &fi) != nil {
			return
		}
		key := "device-" + strconv.FormatUint(uint64(fi.Dev), 10)
		m := mounts[key]
		if m == nil {
			m = &mount{reading: wire.DiskReading{Volume: "This server’s disk", Mount: key,
				FreeBytes: int64(st.Bavail) * int64(st.Bsize), TotalBytes: int64(st.Blocks) * int64(st.Bsize)}, t: diskThresholds{20, 5, 2}}
			mounts[key] = m
		}
		if has {
			// The strictest of the projects on the mount.
			if !m.set {
				m.t, m.set = t, true
			} else {
				m.t = diskThresholds{max(m.t.lowGB, t.lowGB), max(m.t.lowPercent, t.lowPercent), max(m.t.criticalGB, t.criticalGB)}
			}
		}
	}
	look(d.Store.Loc.Root, diskThresholds{}, false)
	for _, p := range d.projects(false) {
		folder := store.FolderPath(p.Project.Folder)
		t, has := projectThresholds(folder)
		look(folder, t, has)
	}
	d.diskMu.Lock()
	if d.diskLevels == nil {
		d.diskLevels = map[string]wire.DiskLevel{}
	}
	var alarms []wire.DiskAlarm
	for key, m := range mounts {
		low, critical := m.t.lowLine(m.reading.TotalBytes), m.t.criticalLine()
		level := nextDiskLevel(d.diskLevels[key], m.reading.FreeBytes, low, critical)
		d.diskLevels[key] = level
		if level != wire.DiskLevelOk {
			threshold := low
			if level == wire.DiskLevelCritical {
				threshold = critical
			}
			alarms = append(alarms, wire.DiskAlarm{Reading: m.reading, Level: level, Threshold: threshold, Worktrees: []wire.DiskWorktree{}})
		}
	}
	sort.Slice(alarms, func(i, j int) bool {
		if alarms[i].Level != alarms[j].Level {
			return alarms[i].Level == wire.DiskLevelCritical
		}
		return alarms[i].Reading.FreeBytes < alarms[j].Reading.FreeBytes
	})
	changed := len(alarms) != len(d.diskAlarms)
	for i := 0; !changed && i < len(alarms); i++ {
		changed = alarms[i].Level != d.diskAlarms[i].Level || alarms[i].Reading.Mount != d.diskAlarms[i].Reading.Mount
	}
	d.diskAlarms = alarms
	d.diskMu.Unlock()
	if changed {
		Broadcast(d, wire.NotifyDiskChanged, wire.DiskState{Alarms: alarms})
	}
}

func (d *Daemon) diskState() wire.DiskState {
	d.diskMu.Lock()
	defer d.diskMu.Unlock()
	return wire.DiskState{Alarms: append([]wire.DiskAlarm{}, d.diskAlarms...)}
}

// watchDisk looks once now and every minute after, as startWatchingDisk does.
func (d *Daemon) watchDisk() {
	d.checkDisk() // before any client, which hears only a change after it
	safe.Go("disk", func() {
		t := time.NewTicker(time.Minute)
		defer t.Stop()
		for {
			select {
			case <-d.ctx.Done():
				return
			case <-t.C:
				d.checkDisk()
			}
		}
	})
}

// MARK: files put in (DaemonCore+Artifacts, DaemonCore+Dropbox)

// writeArtifact is artifact/write: a text file in the agent's folders, as the person typed it.
func (d *Daemon) writeArtifact(r wire.ArtifactWriteRequest) error {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return noSuchAgent()
	}
	if !strings.HasPrefix(r.Path, "/") {
		return Invalid("The path has to be absolute, starting at `/`.")
	}
	folders := []string{store.FolderPath(a.Cwd)}
	for _, f := range a.AdditionalDirectories {
		folders = append(folders, store.FolderPath(f))
	}
	if !inScope(r.Path, folders) {
		return Invalid("Outside this agent's folders (%s)", strings.Join(folders, ", "))
	}
	if old, err := os.ReadFile(r.Path); err == nil && string(old) == r.Text {
		return nil
	}
	if err := store.WriteAtomically(r.Path, []byte(r.Text), 0o644); err != nil {
		return &Error{Code: CodeInternal, Message: "Could not save " + filepath.Base(r.Path) + ": " + err.Error()}
	}
	return nil
}

// inScope is FolderScope.contains: the path, its links followed and a missing one judged
// by its nearest folder that is there, under one of the folders.
func inScope(path string, folders []string) bool {
	resolved := filepath.Clean(path)
	rest := ""
	for p := resolved; ; p = filepath.Dir(p) {
		if r, err := filepath.EvalSymlinks(p); err == nil {
			resolved = filepath.Join(r, rest)
			break
		}
		if p == "/" || p == "." {
			break
		}
		rest = filepath.Join(filepath.Base(p), rest)
	}
	for _, f := range folders {
		root := f
		if r, err := filepath.EvalSymlinks(f); err == nil {
			root = r
		}
		if inside(root, resolved) {
			return true
		}
	}
	return false
}

const dropboxLimit = 25 * 1024 * 1024

// putInDropbox is dropbox/put: a file into a project's .agents/dropbox, whole or not at all.
func (d *Daemon) putInDropbox(r wire.DropboxPutRequest) (wire.DropboxPutResponse, error) {
	folder := store.FolderPath(r.Folder)
	if real, err := filepath.EvalSymlinks(folder); err == nil {
		folder = real
	}
	known := false
	for _, p := range d.projects(true) {
		f := store.FolderPath(p.Project.Folder)
		if real, err := filepath.EvalSymlinks(f); err == nil {
			f = real
		}
		known = known || f == folder
	}
	if !known {
		return wire.DropboxPutResponse{}, Invalid("That is not a project here.")
	}
	if len(r.Data) > dropboxLimit {
		return wire.DropboxPutResponse{}, Invalid("That file is too big to send. Copy it into .agents/dropbox/ on its host instead.")
	}
	name := filepath.Base(r.Name)
	if name == "" || name == "/" || name == "." || strings.HasPrefix(name, ".") {
		return wire.DropboxPutResponse{}, Invalid("A drop box file needs a name that does not start with a dot.")
	}
	dir := filepath.Join(folder, ".agents", "dropbox")
	if r.Subfolder != nil {
		for _, part := range strings.Split(*r.Subfolder, "/") {
			if part == "" {
				continue
			}
			if strings.HasPrefix(part, ".") {
				return wire.DropboxPutResponse{}, Invalid("A folder in the drop box cannot start with a dot.")
			}
			dir = filepath.Join(dir, part)
		}
	}
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return wire.DropboxPutResponse{}, &Error{Code: wire.FailureCouldNotSave, Message: "The file could not be put in the drop box."}
	}
	part := filepath.Join(dir, "."+name+"."+strings.ToLower(string(store.NewUUID()))[:8]+".part")
	if err := os.WriteFile(part, r.Data, 0o644); err != nil {
		os.Remove(part)
		return wire.DropboxPutResponse{}, &Error{Code: wire.FailureCouldNotSave, Message: "The file could not be put in the drop box."}
	}
	path := filepath.Join(dir, name)
	if err := os.Rename(part, path); err != nil {
		os.Remove(part)
		return wire.DropboxPutResponse{}, &Error{Code: wire.FailureCouldNotSave, Message: "The file could not be put in the drop box."}
	}
	return wire.DropboxPutResponse{Path: path}, nil
}
