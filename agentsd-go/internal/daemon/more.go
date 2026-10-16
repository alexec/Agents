package daemon

// registerMore is where the later stages add their methods.
func (d *Daemon) registerMore() {
	d.registerShells()
	d.registerFiles()
}
