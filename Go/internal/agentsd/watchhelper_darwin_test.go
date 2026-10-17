package agentsd

import (
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"testing"
)

var (
	builtWatch     string
	builtWatchErr  error
	buildWatchOnce sync.Once
)

// prepareWatch gives this test the Mac's watch: agents-watch, compiled from Host/AgentsWatch
// once per run with swiftc, or a skip where there is no swiftc.
func prepareWatch(t *testing.T) {
	t.Helper()
	buildWatchOnce.Do(func() {
		swiftc, err := exec.LookPath("swiftc")
		if err != nil {
			builtWatchErr = err
			return
		}
		dir, err := os.MkdirTemp("", "agents-watch")
		if err != nil {
			builtWatchErr = err
			return
		}
		out := filepath.Join(dir, "agents-watch")
		// main.swift and the --machine watch beside it (#1368).
		srcs, _ := filepath.Glob(filepath.Join("..", "..", "..", "Host", "AgentsWatch", "*.swift"))
		if b, err := exec.Command(swiftc, append([]string{"-O", "-o", out}, srcs...)...).CombinedOutput(); err != nil {
			builtWatchErr = &exec.Error{Name: "swiftc " + string(b), Err: err}
			return
		}
		builtWatch = out
	})
	if builtWatchErr != nil {
		t.Skipf("no agents-watch to watch with: %v", builtWatchErr)
	}
	old := watchHelper
	watchHelper = func() string { return builtWatch }
	t.Cleanup(func() { watchHelper = old })
}
