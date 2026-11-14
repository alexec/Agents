package browser

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// xvfb is an X screen in memory that agentsd started for Google Chrome on a Linux machine
// with no display (#5227, spike #5209): Chrome headed under Xvfb passes the bot checks
// (Google's sign-in, Cloudflare) that headless Chrome fails, and its screencast paints.
type xvfb struct {
	// display is the screen's name, ":<n>", for Chrome's DISPLAY.
	display string
	stop    func()
}

// xvfbScreen is the screen's size and depth, as in the spike (#5209): larger than Chrome's
// window, so the window is whole on it.
const xvfbScreen = "1920x1080x24"

// xvfbReady is how long Xvfb has to say its display before it counts as not started.
const xvfbReady = 10 * time.Second

// startXvfb starts Xvfb, from env's PATH or /usr/bin, on a display it picks itself: with
// -displayfd it takes the first free one and writes its number when it is ready for
// clients, so two hosts on one machine never take the same one. It takes no TCP
// connections, only its socket. With -terminate it exits when its last client goes, so a
// Chrome left running by a host that died takes its Xvfb with it when it ends.
func startXvfb(env []string) (*xvfb, error) {
	exe := lookPath("Xvfb", env)
	if exe == "" {
		return nil, errors.New("this machine has no display and no Xvfb, so Google Chrome cannot open a window")
	}
	r, w, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	defer r.Close()
	cmd := exec.Command(exe, "-displayfd", "3", "-screen", "0", xvfbScreen, "-nolisten", "tcp", "-terminate")
	cmd.Env = env
	cmd.ExtraFiles = []*os.File{w}
	var out strings.Builder
	cmd.Stderr = &out
	if err := cmd.Start(); err != nil {
		w.Close()
		return nil, fmt.Errorf("Xvfb did not start: %w", err)
	}
	w.Close()
	exited := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(exited)
	}()
	var once sync.Once
	stop := func() {
		once.Do(func() {
			_ = cmd.Process.Signal(syscall.SIGTERM)
			select {
			case <-exited:
			case <-time.After(5 * time.Second):
				_ = cmd.Process.Kill()
				<-exited
			}
		})
	}
	said := make(chan string, 1)
	go func() {
		line, _ := bufio.NewReader(r).ReadString('\n')
		said <- strings.TrimSpace(line)
	}()
	select {
	case line := <-said:
		if n, err := strconv.Atoi(line); err == nil && n >= 0 {
			return &xvfb{display: ":" + line, stop: stop}, nil
		}
		stop()
		return nil, fmt.Errorf("Xvfb said no display: %s", lastLine(out.String()))
	case <-time.After(xvfbReady):
		stop()
		return nil, fmt.Errorf("Xvfb said no display in %s", xvfbReady)
	}
}

// lookPath is name in env's PATH, or in /usr/bin, or "".
func lookPath(name string, env []string) string {
	var dirs []string
	for _, kv := range env {
		if v, ok := strings.CutPrefix(kv, "PATH="); ok {
			dirs = filepath.SplitList(v)
		}
	}
	for _, dir := range append(dirs, "/usr/bin") {
		if exe := filepath.Join(dir, name); dir != "" && executable(exe) {
			return exe
		}
	}
	return ""
}
