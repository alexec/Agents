package main

import (
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
)

// supervise runs (a box with no systemd: under systemd, Restart=always does this) `agentsd <args>` and starts it again when it crashes (#1125: a host on a box
// with no systemd stayed down all night after one panic). A clean exit (status 0, which SIGTERM
// gives) is a stop on purpose: the supervisor ends too, so stop.sh and devbox.sh stop, which kill
// the host by its daemon.lock pid, still stop it. Anything else (a panic's status 2, a signal such
// as SIGKILL or SIGSEGV) is a crash: it waits 1 s, doubling to 60 s, and starts the host again.
// After 5 minutes up, the wait goes back to 1 s. Its own pid is in the root's supervise.lock;
// SIGTERM to it stops the host and then the supervisor.
func supervise(args []string) {
	root := parse(args).root
	out := io.Writer(os.Stderr)
	if f, err := os.OpenFile(store.At(root).Log(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
		out = f
		setLog(f)
	}
	lock := filepath.Join(root, "supervise.lock")
	os.WriteFile(lock, []byte(fmt.Sprint(os.Getpid())), 0o600)
	defer os.Remove(lock)

	self, _ := os.Executable()
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	wait, starts := time.Second, 0
	for {
		cmd := exec.Command(self, args...)
		// The host stamps its own lines; a panic's stack goes in as it is.
		cmd.Stdout, cmd.Stderr = out, out
		if err := cmd.Start(); err != nil {
			log.Printf("supervise: could not start agentsd: %v", err)
			os.Exit(1)
		}
		starts++
		log.Printf("supervise: agentsd pid %d (start %d)", cmd.Process.Pid, starts)
		up := time.Now()
		exited := make(chan error, 1)
		go func() { exited <- cmd.Wait() }()
		var err error
		select {
		case s := <-sigs:
			log.Printf("supervise: %v, stopping agentsd", s)
			cmd.Process.Signal(syscall.SIGTERM)
			<-exited
			return
		case err = <-exited:
		}
		if err == nil {
			log.Printf("supervise: agentsd stopped cleanly; the supervisor ends too")
			return
		}
		var ee *exec.ExitError
		what := err.Error()
		if errors.As(err, &ee) {
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() && ws.Signal() == syscall.SIGTERM {
				log.Printf("supervise: agentsd was sent SIGTERM; the supervisor ends too")
				return
			}
		}
		if time.Since(up) > 5*time.Minute {
			wait = time.Second
		}
		log.Printf("supervise: agentsd crashed after %s (%s); starting it again in %s", time.Since(up).Round(time.Second), what, wait)
		select {
		case <-time.After(wait):
		case s := <-sigs:
			log.Printf("supervise: %v while waiting; the supervisor ends", s)
			return
		}
		wait = min(wait*2, time.Minute)
	}
}
