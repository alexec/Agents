package agentsd

import (
	"bufio"
	"bytes"
	"log"
	"os"
	"os/exec"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
)

// StartMachineWatch hears the Mac (#1368) through agents-watch --machine, beside this
// binary in Agents Host's Helpers: IOKit and CoreGraphics are out of Go's reach without
// cgo. One helper for the host's life, started again if it dies; with none (a build that
// carries none) nothing is heard, and that is said once.
func (d *Daemon) StartMachineWatch() {
	helper := watchHelper()
	if fi, err := os.Stat(helper); helper == "" || err != nil || fi.Mode()&0o111 == 0 {
		log.Printf("machine watch: no agents-watch beside agentsd, so sleep, wake, away and back are not heard")
		return
	}
	stop := make(chan struct{})
	d.machineMu.Lock()
	d.machineStop = func() { close(stop) }
	d.machineMu.Unlock()
	safe.Go("machine watch", func() {
		for {
			began := time.Now()
			d.runMachineWatch(helper, stop)
			select {
			case <-stop:
				return
			case <-d.ctx.Done():
				return
			default:
			}
			// Died: again, but not in a tight loop.
			wait := 30 * time.Second
			if time.Since(began) > time.Minute {
				wait = time.Second
			}
			log.Printf("machine watch: agents-watch ended; starting it again in %s", wait)
			select {
			case <-time.After(wait):
			case <-stop:
				return
			case <-d.ctx.Done():
				return
			}
		}
	})
}

// runMachineWatch runs one helper until it ends or the host lets it go.
func (d *Daemon) runMachineWatch(helper string, stop chan struct{}) {
	cmd := exec.Command(helper, "--machine", d.personAway())
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	cmd.Stderr = os.Stderr
	if err := cmd.Start(); err != nil {
		log.Printf("machine watch: %v", err)
		return
	}
	ended := make(chan struct{})
	safe.Go("machine watch stop", func() {
		select {
		case <-stop:
		case <-d.ctx.Done():
		case <-ended:
		}
		stdin.Close()
	})
	words := bufio.NewScanner(stdout)
	words.Split(func(data []byte, atEOF bool) (int, []byte, error) {
		if i := bytes.IndexByte(data, 0); i >= 0 {
			return i + 1, data[:i], nil
		}
		if atEOF && len(data) > 0 {
			return len(data), data, nil
		}
		return 0, nil, nil
	})
	marker := false
	for words.Scan() {
		word := words.Text()
		switch {
		case word == "":
			marker = true
			continue
		case marker && word == "ready":
			d.machineFirstLookDone()
		default:
			if c, ok := parseMachineChange(word); ok {
				d.machineChanged(c)
			}
		}
		marker = false
	}
	close(ended)
	cmd.Wait()
}
