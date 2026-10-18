package agentsd

import (
	"os"
	"path/filepath"
)

// registerInstall serves runtimes/install on a Mac: into <cache>/tools, from the toolsets
// the app carries beside this binary (Contents/Helpers → Contents/Resources/toolsets), as
// Daemon/main.swift finds them.
func (d *Daemon) registerInstall() {
	folder := ""
	if exe, err := os.Executable(); err == nil {
		if exe, err = filepath.EvalSymlinks(exe); err == nil {
			folder = filepath.Join(filepath.Dir(filepath.Dir(exe)), "Resources", "toolsets")
		}
	}
	d.serveInstall(filepath.Join(d.Store.Loc.Cache, "tools"), folder)
}

// installDefaultToolsets leaves a Mac's runtimes to the person: the window offers Install.
func (d *Daemon) installDefaultToolsets() {}
