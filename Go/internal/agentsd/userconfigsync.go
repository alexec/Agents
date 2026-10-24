package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io/fs"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// startUserConfigSync watches the files that follow the person. It also reconciles the
// full folder when the control plane comes back, so offline edits and removals are sent.
func (d *Daemon) startUserConfigSync() {
	home := d.personalHome()
	if home == "" {
		return
	}
	root := filepath.Join(home, ".agents")
	if err := os.MkdirAll(root, 0o755); err != nil {
		log.Printf("agent configuration sync: could not open ~/.agents: %v", err)
		return
	}
	d.configWatchMu.Lock()
	if d.configWatch != nil {
		d.configWatchMu.Unlock()
		return
	}
	watch, err := newProjectWatch(root, func(paths []string) { d.syncUserConfigPaths(paths) })
	if err == nil {
		d.configWatch = watch
	}
	d.configWatchMu.Unlock()
	if err != nil {
		log.Printf("agent configuration sync: could not watch ~/.agents: %v", err)
		return
	}
}

func (d *Daemon) stopUserConfigSync() {
	d.configWatchMu.Lock()
	w := d.configWatch
	d.configWatch = nil
	d.configWatchMu.Unlock()
	if w != nil {
		w.stop()
	}
}

func (d *Daemon) syncAllUserConfigFiles() {
	safe.Go("agent configuration sync", func() { d.syncUserConfigTree(".") })
}

func (d *Daemon) syncUserConfigPaths(paths []string) {
	for _, changed := range paths {
		base := filepath.Join(d.personalHome(), ".agents")
		rel, err := filepath.Rel(base, changed)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			continue
		}
		if safeAgentConfigPath(rel) {
			d.syncUserConfigFile(rel)
			continue
		}
		d.syncUserConfigTree(rel)
	}
}

func (d *Daemon) syncUserConfigTree(rel string) {
	if rel != "." {
		for _, part := range strings.Split(filepath.ToSlash(rel), "/") {
			if excludedAgentConfigDirectory(part) {
				return
			}
		}
	}
	base := filepath.Join(d.personalHome(), ".agents")
	root := filepath.Join(base, filepath.Clean(rel))
	active := map[string]bool{}
	_ = filepath.WalkDir(root, func(p string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if entry.IsDir() {
			if p != root && excludedAgentConfigDirectory(entry.Name()) {
				return filepath.SkipDir
			}
			return nil
		}
		if !entry.Type().IsRegular() {
			return nil
		}
		name, err := filepath.Rel(base, p)
		if err != nil || !safeAgentConfigPath(name) {
			return nil
		}
		active[name] = true
		d.syncUserConfigFile(name)
		return nil
	})
	mark := d.currentUserConfigMark()
	for _, file := range mark.ConfigFiles {
		if file.Deleted != nil && *file.Deleted || active[file.Path] {
			continue
		}
		if rel != "." && file.Path != rel && !strings.HasPrefix(file.Path, filepath.ToSlash(rel)+"/") {
			continue
		}
		if _, err := os.Stat(filepath.Join(base, filepath.FromSlash(file.Path))); errorsIsNotExist(err) {
			d.sendUserConfigFile(file.Path, nil, true, 0, 0)
		}
	}
}

func excludedAgentConfigDirectory(name string) bool {
	switch strings.ToLower(name) {
	case "node_modules", ".git", ".cache", "cache", "caches", "dist", "build", "target", "vendor", "__pycache__":
		return true
	default:
		return false
	}
}

func errorsIsNotExist(err error) bool { return err != nil && os.IsNotExist(err) }

func (d *Daemon) syncUserConfigFile(rel string) {
	if !safeAgentConfigPath(rel) {
		return
	}
	base := filepath.Join(d.personalHome(), ".agents")
	path, pathErr := safeConfigPath(base, rel, false)
	if pathErr != nil {
		return
	}
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		if errorsIsNotExist(err) {
			mark := d.currentUserConfigMark()
			for _, file := range mark.ConfigFiles {
				if file.Path == rel && (file.Deleted == nil || !*file.Deleted) {
					d.sendUserConfigFile(rel, nil, true, 0, 0)
					return
				}
			}
		}
		return
	}
	if info.Size() > maxAgentConfigFileBytes {
		log.Printf("agent configuration sync: %s was not sent because it is larger than the file limit", filepath.ToSlash(rel))
		return
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		return
	}
	if rel == "mcp.json" {
		var file struct {
			MCPServers json.RawMessage `json:"mcpServers"`
		}
		if json.Unmarshal(contents, &file) != nil {
			return
		}
		if len(file.MCPServers) == 0 {
			file.MCPServers = json.RawMessage(`{}`)
		}
		if err := tokensInClear(file.MCPServers); err != nil {
			log.Printf("agent configuration sync: mcp.json was not sent because it has a secret in clear")
			return
		}
		contents = file.MCPServers
	}
	digestBytes := sha256.Sum256(contents)
	digest := hex.EncodeToString(digestBytes[:])
	mark := d.currentUserConfigMark()
	var previous *wire.AgentConfigFile
	for i := range mark.ConfigFiles {
		if mark.ConfigFiles[i].Path == rel {
			previous = &mark.ConfigFiles[i]
			break
		}
	}
	if previous != nil && previous.Digest == digest && (previous.Deleted == nil || !*previous.Deleted) {
		return // This is the same file the control plane last wrote.
	}
	timeValue := max(time.Now().UnixMilli(), info.ModTime().UnixMilli())
	var counter int64
	if previous != nil {
		if timeValue <= previous.Time {
			timeValue = previous.Time
			counter = previous.Counter + 1
		}
	}
	d.sendUserConfigFile(rel, contents, false, timeValue, counter)
}

func (d *Daemon) currentUserConfigMark() userScopeMark {
	d.userScopeMu.Lock()
	defer d.userScopeMu.Unlock()
	return d.userMarkLocked()
}

func (d *Daemon) sendUserConfigFile(rel string, contents []byte, deleted bool, timeValue, counter int64) {
	ask := d.askControl.Load()
	if ask == nil {
		return
	}
	mark := d.currentUserConfigMark()
	if timeValue == 0 {
		timeValue = time.Now().UnixMilli()
		for _, file := range mark.ConfigFiles {
			if file.Path == rel && timeValue <= file.Time {
				timeValue = file.Time
				counter = file.Counter + 1
			}
		}
	}
	var value *string
	if !deleted {
		encoded := base64.StdEncoding.EncodeToString(contents)
		value = &encoded
	}
	wasDeleted := deleted
	request := wire.AgentConfigFileRequest{Path: filepath.ToSlash(rel), Contents: value, Deleted: &wasDeleted,
		Time: timeValue, Counter: counter}
	if _, err := (*ask)(context.Background(), "user/setAgentConfigFile", request); err != nil {
		log.Printf("agent configuration sync: %s could not be sent: %v", filepath.ToSlash(rel), err)
		return
	}
	d.noteUserConfigClock(request, digestForConfig(contents, deleted))
}

func digestForConfig(contents []byte, deleted bool) string {
	if deleted {
		return "deleted"
	}
	sum := sha256.Sum256(contents)
	return hex.EncodeToString(sum[:])
}

func (d *Daemon) noteUserConfigClock(request wire.AgentConfigFileRequest, digest string) {
	d.userScopeMu.Lock()
	defer d.userScopeMu.Unlock()
	mark := d.userMarkLocked()
	file := wire.AgentConfigFile{Path: request.Path, Deleted: request.Deleted, Time: request.Time, Counter: request.Counter, Digest: digest}
	found := false
	for i, old := range mark.ConfigFiles {
		if old.Path != request.Path {
			continue
		}
		found = true
		if request.Time < old.Time || request.Time == old.Time && request.Counter < old.Counter {
			return
		}
		mark.ConfigFiles[i] = file
		break
	}
	if !found {
		mark.ConfigFiles = append(mark.ConfigFiles, file)
	}
	encoded, err := diskjson.Marshal(mark)
	if err == nil {
		err = store.WriteAtomically(d.userScopeFile(), encoded, 0o644)
	}
	if err != nil {
		log.Printf("agent configuration sync: could not save the local clock for %s: %v", filepath.ToSlash(request.Path), err)
		return
	}
	d.userMark = &mark
}

func (d *Daemon) userConfigSyncUplinkRestored() { d.syncAllUserConfigFiles() }
