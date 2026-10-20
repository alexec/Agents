package procgroup

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// leaver is a command that leaves a child running, as ssh leaves gh's relay (#1643): one
// that does not end on SIGHUP, with its pid in a file.
func leaver(t *testing.T) (*exec.Cmd, string) {
	pidFile := filepath.Join(t.TempDir(), "pid")
	cmd := exec.Command("/bin/sh", "-c",
		`trap "" HUP; sleep 30 >/dev/null 2>&1 </dev/null & echo $! > "$1"`, "sh", pidFile)
	return cmd, pidFile
}

func childOf(t *testing.T, pidFile string) int {
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil {
		t.Fatal(err)
	}
	return pid
}

// gone waits a moment for pid to end. A child of init can stay a zombie for a moment.
func gone(pid int) bool {
	for range 50 {
		if syscall.Kill(pid, 0) != nil {
			return true
		}
		if data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat"); err == nil &&
			strings.Contains(string(data), ") Z ") {
			return true
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func TestWhatACommandLeavesIsEndedWithIt(t *testing.T) {
	cmd, pidFile := leaver(t)
	Own(cmd)
	if err := cmd.Run(); err != nil {
		t.Fatal(err)
	}
	child := childOf(t, pidFile)
	t.Cleanup(func() { syscall.Kill(child, syscall.SIGKILL) })
	if gone(child) {
		t.Fatal("the child ended before End: the test shows nothing")
	}
	End(cmd)
	if !gone(child) {
		t.Fatal("the child it left is still running")
	}
}

func TestACancelledCommandsGroupIsEnded(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	pidFile := filepath.Join(t.TempDir(), "pid")
	cmd := exec.CommandContext(ctx, "/bin/sh", "-c",
		`trap "" HUP; sleep 30 >/dev/null 2>&1 </dev/null & echo $! > "$1"; sleep 30`, "sh", pidFile)
	Own(cmd)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	for range 100 {
		if _, err := os.Stat(pidFile); err == nil {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	child := childOf(t, pidFile)
	t.Cleanup(func() { syscall.Kill(child, syscall.SIGKILL) })
	cancel()
	cmd.Wait()
	End(cmd)
	if !gone(child) {
		t.Fatal("the child is still running after the cancel")
	}
}

func TestEndOfACommandThatNeverStartedDoesNothing(t *testing.T) {
	End(exec.Command("/nonexistent"))
}
