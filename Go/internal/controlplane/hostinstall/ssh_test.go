package hostinstall

import (
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

// #1643: a ProxyCommand that outlives ssh, as gh's relay does, ends with the call.
func TestWhatSSHLeavesRunningEndsWithTheCall(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "relay")
	fake := filepath.Join(dir, "ssh")
	script := "#!/bin/sh\ntrap '' HUP\nsleep 30 >/dev/null 2>&1 </dev/null &\necho $! > " + pidFile + "\n"
	if err := os.WriteFile(fake, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	out, err := sshCommand{executable: fake}.run(context.Background(), nil, "")
	if err != nil || out.status != 0 {
		t.Fatalf("%+v %v", out, err)
	}
	data, err := os.ReadFile(pidFile)
	if err != nil {
		t.Fatal(err)
	}
	relay, _ := strconv.Atoi(strings.TrimSpace(string(data)))
	t.Cleanup(func() { syscall.Kill(relay, syscall.SIGKILL) })
	for range 50 {
		stat, _ := os.ReadFile("/proc/" + strconv.Itoa(relay) + "/stat")
		if syscall.Kill(relay, 0) != nil || strings.Contains(string(stat), ") Z ") {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("the relay ssh left is still running")
}
