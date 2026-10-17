package workspacecommands

import (
	"context"
	"errors"
	"os/exec"
	"sync"
	"syscall"
	"time"
)

// Outcome is what one command did.
type Outcome struct {
	// Status is the exit status, or -1 when it could not start or ran out of time.
	Status   int
	Output   []byte
	Errors   []byte
	TimedOut bool
	// Failure is why it did not run, when it could not start.
	Failure string
}

// Text is its output as text.
func (o Outcome) Text() string { return string(o.Output) }

// ErrorText is its standard error as text.
func (o Outcome) ErrorText() string { return string(o.Errors) }

// Runner runs one line with /bin/sh -c, within a deadline.
type Runner func(line string, deadline time.Duration) Outcome

const (
	outputLimit = 1 << 20
	// errorLimit is what is kept of standard error: enough for any message.
	errorLimit = 256 << 10
	// grace is how long a child that has exited may leave something holding its pipes, and
	// how long a stopped one has between SIGTERM and SIGKILL.
	grace = 2 * time.Second
)

// Shell runs the line in /bin/sh with this process's environment, so a secret the control
// plane passed reaches it. Output past a megabyte is read and dropped. A child still going
// at the deadline is sent SIGTERM, then SIGKILL two seconds on.
func Shell(line string, deadline time.Duration) Outcome {
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c", line)
	cmd.Cancel = func() error { return cmd.Process.Signal(syscall.SIGTERM) }
	cmd.WaitDelay = grace
	output, errs := &capped{limit: outputLimit}, &capped{limit: errorLimit}
	cmd.Stdout, cmd.Stderr = output, errs
	err := cmd.Run()
	outcome := Outcome{Status: -1, Output: output.bytes(), Errors: errs.bytes()}
	if ctx.Err() == context.DeadlineExceeded {
		outcome.TimedOut = true
		return outcome
	}
	if cmd.ProcessState != nil {
		outcome.Status = cmd.ProcessState.ExitCode()
		return outcome
	}
	var exitErr *exec.ExitError
	if err != nil && !errors.As(err, &exitErr) {
		outcome.Failure = err.Error()
	}
	return outcome
}

// capped keeps what is written up to its limit and drops the rest.
type capped struct {
	mu    sync.Mutex
	limit int
	data  []byte
}

func (c *capped) Write(p []byte) (int, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if room := c.limit - len(c.data); room > 0 {
		c.data = append(c.data, p[:min(room, len(p))]...)
	}
	return len(p), nil
}

func (c *capped) bytes() []byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]byte(nil), c.data...)
}
