package agentsd

import (
	"log"
	"os"
	"path/filepath"
)

// serverToolsetsFolder is where the shown command leaves the toolsets the control plane
// carries (#1312): ~/.agents-server/toolsets/<runtime>/, each a manifest and npm's lock.
func serverToolsetsFolder() string {
	return filepath.Join(filepath.Dir(filepath.Dir(toolsetFolder("claude"))), "toolsets")
}

// registerInstall serves runtimes/install on a server (#1312): the Node toolsets in
// ~/.agents-server/toolsets, into ~/.agents-server/tools, as machines/install does over ssh.
func (d *Daemon) registerInstall() {
	d.serveServerInstall(serverToolsetsFolder())
}

// defaultToolsets are the runtimes a server installs by itself when they are missing:
// Claude, the default runtime, as machines/install's DefaultToolsets.
var defaultToolsets = []string{"claude"}

// installDefaultToolsets installs Claude once the host is up, when the shown command left
// its toolset and the server has no Claude yet, so a server joined that way can run it
// with nothing more done. A failure is said on runtime/changed and in the log, and tried
// again at the next start.
func (d *Daemon) installDefaultToolsets() {
	if _, err := os.Stat(serverToolsetsFolder()); err != nil {
		return
	}
	for _, id := range defaultToolsets {
		r := runtimeByID(id)
		if r == nil || d.recipe(id) == nil {
			continue
		}
		if path, _, _ := locateFor(r); path != "" {
			continue
		}
		log.Printf("%s is missing: installing it from the toolset the control plane gave", r.Name)
		if _, err := d.installRuntime(nil, id); err != nil {
			log.Printf("installing %s: %v", id, err)
		}
	}
}
