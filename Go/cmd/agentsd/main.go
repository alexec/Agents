// agentsd is the Go host daemon (#1136): it joins a control plane as the Swift agentsd
// does, with the same flags, on the same root. The Swift Linux host stays the default
// until Alex chooses (#1134); install.sh --impl go installs this one.
package main

import (
	"context"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/safe"
)

// logLine writes each line as DaemonLog does: the time in UTC to the second, then the words.
type logLine struct{ w io.Writer }

func (l logLine) Write(p []byte) (int, error) {
	stamp := time.Now().UTC().Format("2006-01-02T15:04:05Z") + " "
	if _, err := l.w.Write(append([]byte(stamp), p...)); err != nil {
		return 0, err
	}
	return len(p), nil
}

func setLog(w io.Writer) {
	log.SetFlags(0)
	log.SetOutput(logLine{w})
}

func main() {
	setLog(os.Stderr)
	if len(os.Args) > 1 && os.Args[1] == "supervise" {
		supervise(os.Args[2:])
		return
	}
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "version") {
		fmt.Println(buildinfo.String())
		return
	}
	cl := parse(os.Args[1:])
	if err := os.MkdirAll(cl.root, 0o700); err != nil {
		log.Fatal(err)
	}
	loc := store.At(cl.root)
	if err := os.MkdirAll(loc.Logs, 0o700); err != nil {
		log.Fatal(err)
	}
	if cl.detach {
		detach(loc)
		return
	}
	if !isTerminal() {
		// Detached or under systemd: the log is the root's daemon.log, where the Swift
		// host keeps it (StoreLocations.log).
		if f, err := os.OpenFile(loc.Log(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			setLog(f)
		}
	}
	lock, err := takeLock(loc.Lock())
	if err != nil {
		log.Fatalf("another agentsd holds %s: %v", loc.Lock(), err)
	}
	defer lock.Close()

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	d, err := agentsd.New(ctx, cl.root)
	if err != nil {
		log.Fatal(err)
	}
	d.Quit = stop // daemon/quit
	// events/raise, as a debug build on a scratch root has it: never on a root a person
	// uses, nor in a release.
	d.RaiseByHand = buildinfo.Version == "dev" && !ordinaryRoot(cl.root)
	if cl.serve {
		// A server's settings are the person's, in their home (Daemon.swift's --serve).
		if home, err := os.UserHomeDir(); err == nil {
			d.SettingsDir = filepath.Join(home, ".agents", "settings")
			d.ChatHome = home
		}
	}
	safe.Go("socket", func() {
		if err := d.ServeSocket(ctx, loc.Socket()); err != nil && ctx.Err() == nil {
			log.Printf("socket: %v", err)
		}
	})
	if cl.controlNetwork() {
		join(ctx, cl, d)
	}
	log.Printf("agentsd %s on %s, root %s", buildinfo.String(), platform(), cl.root)
	d.EnsureChatProject()
	d.PickUpAfterRestart()
	<-ctx.Done()
	log.Printf("shutting down")
	d.Shutdown()
}

// commandLine is DaemonCommandLine: the flags the install script and ssh pass.
type commandLine struct {
	root     string
	serve    bool
	detach   bool
	network  bool
	code     string
	hostName string
	args     []string
}

func parse(args []string) commandLine {
	cl := commandLine{args: args}
	value := func(flag string) string {
		for i, a := range args {
			if a == flag && i+1 < len(args) {
				return args[i+1]
			}
			if strings.HasPrefix(a, flag+"=") {
				return strings.TrimPrefix(a, flag+"=")
			}
		}
		return ""
	}
	for _, a := range args {
		switch a {
		case "--serve":
			cl.serve = true
		case "--detach":
			cl.detach = true
		case "--control-network":
			cl.network = true
		}
	}
	cl.root = value("--root")
	cl.code = value("--control")
	if cl.code == "" {
		cl.code = value("--control-code")
	}
	cl.hostName = value("--host-name")
	if cl.root == "" {
		cl.root = os.Getenv("AGENTS_ROOT")
	}
	if cl.root == "" {
		// The ordinary root, Application Support/Agents, which is ~/.local/share/Agents on
		// Linux, as Foundation has it.
		home, _ := os.UserHomeDir()
		cl.root = filepath.Join(home, ".local", "share", "Agents")
	}
	if strings.HasPrefix(cl.root, "~/") {
		home, _ := os.UserHomeDir()
		cl.root = filepath.Join(home, cl.root[2:])
	}
	cl.root, _ = filepath.Abs(cl.root)
	return cl
}

func (cl commandLine) controlNetwork() bool { return cl.code != "" || cl.network }

// detach starts this host again in a session of its own, under its supervisor, told
// everything but --detach, and returns at once (037: the ssh that asked can finish).
func detach(loc store.Locations) {
	var args []string
	for _, a := range os.Args[1:] {
		if a != "--detach" {
			args = append(args, a)
		}
	}
	logf, _ := os.OpenFile(loc.Log(), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	self, _ := os.Executable()
	cmd := exec.Command(self, append([]string{"supervise"}, args...)...)
	cmd.Stdout, cmd.Stderr = logf, logf
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		log.Fatal(err)
	}
	fmt.Printf("agentsd started under its supervisor, pid %d\n", cmd.Process.Pid)
}

// takeLock is DaemonLock: an exclusive flock on daemon.lock, holding this pid, so two
// hosts never share a root. The install script stops a host by the pid in it.
func takeLock(file string) (*os.File, error) {
	f, err := os.OpenFile(file, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, err
	}
	f.Truncate(0)
	f.WriteAt([]byte(fmt.Sprintf("%d\n", os.Getpid())), 0)
	return f, nil
}

// join enrols with a code once (control-join-code, or --control), then keeps the uplink.
func join(ctx context.Context, cl commandLine, d *agentsd.Daemon) {
	loc := d.Store.Loc
	name := cl.hostName
	if name == "" {
		name, _ = os.Hostname()
	}
	hello := controllink.HostHello{Version: buildinfo.Version, Platform: platform(), MachineID: machineID(), Name: name,
		Implementation: buildinfo.Implementation}
	code := cl.code
	codeFile := filepath.Join(loc.Root, "control-join-code")
	if code == "" {
		if b, err := os.ReadFile(codeFile); err == nil {
			code = strings.TrimSpace(string(b))
		}
	}
	private, err := controllink.HostPrivateKey(loc.Root)
	if err != nil {
		log.Fatal(err)
	}
	member, err := controllink.LoadMembership(loc.Root)
	if code != "" || err != nil || member.Host == "" {
		if code == "" {
			log.Printf("no membership in the root and no code to enrol with: not joining a control plane")
			return
		}
		c, err := controllink.ParseCode(code)
		if err != nil {
			log.Fatalf("the host code: %v", err)
		}
		for {
			member, err = controllink.Enroll(ctx, loc.Root, c, private, hello)
			if err == nil {
				break
			}
			log.Printf("could not enrol: %v; trying again in 5 s", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(5 * time.Second):
			}
		}
		os.Remove(codeFile)
		log.Printf("enrolled as host %s with %s", member.Host, member.Name)
	}
	up := &controllink.Uplink{Root: loc.Root, Member: member, Private: private, Hello: hello, Accept: d.Accept}
	d.Tunneler = up
	safe.Go("uplink", func() {
		// A panic in the uplink would leave the host up but offline: dial again.
		for ctx.Err() == nil && safe.Catch("uplink", func() { up.Run(ctx) }) != nil {
			time.Sleep(time.Second)
		}
	})
}

// platform is Daemon.platform: "Linux arm64" or "Linux x86-64".
func platform() string {
	name := "Linux"
	if runtime.GOOS == "darwin" {
		name = "macOS"
	}
	if runtime.GOARCH == "arm64" {
		return name + " arm64"
	}
	return name + " x86-64"
}

// machineID is MachineID.current on Linux.
func machineID() string {
	if id := os.Getenv("AGENTS_MACHINE_ID"); id != "" {
		return id
	}
	for _, f := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
		if b, err := os.ReadFile(f); err == nil && strings.TrimSpace(string(b)) != "" {
			return strings.TrimSpace(string(b))
		}
	}
	h, _ := os.Hostname()
	return h
}

func isTerminal() bool {
	fi, err := os.Stdout.Stat()
	return err == nil && fi.Mode()&os.ModeCharDevice != 0
}

// ordinaryRoot is StoreLocations.isStandard: the root a person's host uses, where an
// invented event would be a lie (Application Support/Agents, or an installed server's).
func ordinaryRoot(root string) bool {
	home, _ := os.UserHomeDir()
	for _, r := range []string{filepath.Join(home, ".local", "share", "Agents"),
		filepath.Join(home, "Library", "Application Support", "Agents"), filepath.Join(home, ".agents-server", "root")} {
		if filepath.Clean(root) == r {
			return true
		}
	}
	return false
}
