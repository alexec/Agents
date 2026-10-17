package agentsd

import "path/filepath"

// setToolsHome is where a Mac host's own toolsets are: the root's cache's tools/, where the
// Swift host installs them (048), so a host that changes language finds them.
func (d *Daemon) setToolsHome() { macToolsHome = filepath.Join(d.Store.Loc.Cache, "tools") }
