// Package store is the daemon's root as the Swift daemon lays it out (StoreLocations.swift,
// AgentStore.swift, FolderStore.swift): the same files, in the same encoding, so a host
// that changes language keeps its agents and its id (#1134).
package store

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// Locations is where a root's files are: the root itself, and its cache and log folders
// in the platform's places (#1030).
type Locations struct {
	Root  string
	Cache string
	Logs  string
}

// At is the locations of root on this machine, as StoreLocations(root:) works them out:
// platformFolders on Linux, macFolders on a Mac (locations_darwin.go).
func At(root string) Locations {
	home, _ := os.UserHomeDir()
	return folders(filepath.Clean(root), home, os.Getenv)
}

// IsStandard is root being this OS's ordinary root, StandardRoot: the root the person's
// own host uses. agentsd's default root and every check that a root is the real one
// (roles on daemon.sock, events by hand, the real Trash) ask this, never ~/.agents (#1400).
func IsStandard(root string) bool {
	home, err := os.UserHomeDir()
	return err == nil && filepath.Clean(root) == StandardRoot(home)
}

// platformFolders is the Linux rule: a root in a temporary folder keeps cache/ and logs/
// inside it; any other root has a folder of its own, roots/<name>-<hash>, under
// $XDG_CACHE_HOME/agents and $XDG_STATE_HOME/agents/logs.
func platformFolders(root, home string, env func(string) string) Locations {
	if isTemporary(root) {
		return Locations{Root: root, Cache: filepath.Join(root, "cache"), Logs: filepath.Join(root, "logs")}
	}
	xdg := func(variable, fallback string) string {
		if v := env(variable); strings.HasPrefix(v, "/") {
			return v
		}
		return filepath.Join(home, fallback)
	}
	own := filepath.Join("roots", fmt.Sprintf("%s-%s", filepath.Base(root), PathHash(root)))
	return Locations{
		Root:  root,
		Cache: filepath.Join(xdg("XDG_CACHE_HOME", ".cache"), "agents", own),
		Logs:  filepath.Join(xdg("XDG_STATE_HOME", ".local/state"), "agents", "logs", own),
	}
}

func isTemporary(root string) bool {
	resolved, err := filepath.EvalSymlinks(root)
	if err != nil {
		resolved = root
	}
	// Both the folder and where it leads: a root not made yet is not resolved, and on a
	// Mac /tmp leads to /private/tmp.
	for _, t := range []string{os.TempDir(), "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp"} {
		candidates := []string{filepath.Clean(t)}
		if r, err := filepath.EvalSymlinks(t); err == nil {
			candidates = append(candidates, filepath.Clean(r))
		}
		for _, c := range candidates {
			if resolved == c || strings.HasPrefix(resolved, c+"/") {
				return true
			}
		}
	}
	return false
}

// PathHash is eight hex digits of FNV-1a 64, StoreLocations.pathHash.
func PathHash(path string) string {
	h := uint64(1469598103934665603)
	for _, b := range []byte(path) {
		h = (h ^ uint64(b)) * 1099511628211
	}
	s := fmt.Sprintf("%x", h)
	if len(s) > 8 {
		s = s[len(s)-8:]
	}
	return s
}

func (l Locations) Agents() string          { return filepath.Join(l.Root, "agents") }
func (l Locations) Agent(id string) string  { return filepath.Join(l.Agents(), strings.ToUpper(id)) }
func (l Locations) Record(id string) string { return filepath.Join(l.Agent(id), "agent.json") }
func (l Locations) Transcript(id string) string {
	return filepath.Join(l.Agent(id), "transcript.jsonl")
}
func (l Locations) Folders() string      { return filepath.Join(l.Root, "folders.json") }
func (l Locations) RootIdentity() string { return filepath.Join(l.Root, "root-id.json") }
func (l Locations) Socket() string       { return filepath.Join(l.Root, "daemon.sock") }
func (l Locations) Lock() string         { return filepath.Join(l.Root, "daemon.lock") }
func (l Locations) Log() string          { return filepath.Join(l.Logs, "daemon.log") }

// ProjectTools is the last MachineProjects the control plane sent (#2669). It is not
// projects.json: that is v0.11's folder list, which a person may still move to folders.json
// by hand (#2707).
func (l Locations) ProjectTools() string { return filepath.Join(l.Root, "project-tools.json") }

// ArchiveIndex is the Swift daemon's index of archived agents (051), a cache.
func (l Locations) ArchiveIndex() string { return filepath.Join(l.Cache, "archive.json") }

// Turns is the Swift daemon's cache of an agent's turn summaries (StoreLocations.turns).
func (l Locations) Turns(id string) string {
	return filepath.Join(l.Cache, "turns", strings.ToUpper(id)+".jsonl")
}
