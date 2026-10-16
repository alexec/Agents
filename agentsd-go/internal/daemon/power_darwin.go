package daemon

import (
	"fmt"
	"log"
	"os"
	"os/exec"
)

// awake keeps this Mac from idle sleep while a turn runs, as the Swift host does with
// ProcessInfo.beginActivity(.idleSystemSleepDisabled). With no cgo for IOPMAssertion, it
// is /usr/bin/caffeinate -i, tied to this process so it cannot outlive it.
func (d *Daemon) awake(on bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if on && d.caffeinate == nil {
		cmd := exec.Command("/usr/bin/caffeinate", "-i", "-w", fmt.Sprint(os.Getpid()))
		if err := cmd.Start(); err != nil {
			log.Printf("power: %v", err)
			return
		}
		d.caffeinate = cmd
		log.Printf("power: kept awake while turns run (caffeinate %d)", cmd.Process.Pid)
	} else if !on && d.caffeinate != nil {
		d.caffeinate.Process.Kill()
		d.caffeinate.Wait()
		d.caffeinate = nil
		log.Printf("power: no turn running; idle sleep allowed")
	}
}
