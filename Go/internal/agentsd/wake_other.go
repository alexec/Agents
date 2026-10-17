//go:build !darwin

package agentsd

// wakeKeeper is a Mac's: a server has no idle sleep to hold off.
type wakeKeeper struct{}

func (d *Daemon) registerWake()     {}
func (d *Daemon) registerMacVerbs() {}
func (k *wakeKeeper) shutDown()     {}
