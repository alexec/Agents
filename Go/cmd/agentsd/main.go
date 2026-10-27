// agentsd is the host daemon (#1136, #1138): it joins a control plane with the flags the
// Swift agentsd had, on the same root, on Linux and on a Mac. The Swift one went in #1314.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd"
	"github.com/alexec/agents/Go/internal/agentsd/redact"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/machine"
	"github.com/alexec/agents/Go/internal/rolllog"
	"github.com/alexec/agents/Go/internal/safe"
)

// logLine writes each line as DaemonLog does: the time in UTC to the second, then the words,
// with any known token shape redacted (#1001).
type logLine struct{ w io.Writer }

func (l logLine) Write(p []byte) (int, error) {
	stamp := time.Now().UTC().Format("2006-01-02T15:04:05Z") + " "
	words, _ := redact.Bytes(p)
	if _, err := l.w.Write(append([]byte(stamp), words...)); err != nil {
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
		// host keeps it (StoreLocations.log), rolled at 4 MB (#1555). A panic lands in it too.
		if f, err := rolllog.Open(loc.Log(), rolllog.Limit, true); err == nil {
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
	if home := personalHome(cl); home != "" {
		// The person's settings are in their home: a server's
		// (Daemon.swift's --serve), and the ordinary root's (StoreLocations.personalHome).
		d.SettingsDir = filepath.Join(home, ".agents", "settings")
		d.PersonalHome = home
	}
	// A root that joined follows its organisation's policy from its first call, also when
	// started without the control network (#998, FR-013): only its control plane's key
	// checks the policy it keeps. join sets it again after a new enrolment.
	d.SetPin(machinePin(cl))
	if member, err := controllink.LoadMembership(loc.Root); err == nil && member.Host != "" {
		if err := d.Pin().AdmitsMember(member); err != nil {
			log.Printf("pin: the membership kept here is for another control plane, and is not used: %v", err)
		} else {
			d.SetControlKey(member.ControlKey)
			d.SetMember(member)
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
	// The restart itself, for a wait or a workflow that names it (#1219), and from now on
	// a word once a minute that this host is alive.
	d.SayRestarted()
	d.PickUpAfterRestart()
	d.StartConnections()
	d.StartRetention()
	d.StartBackups()
	d.StartMCPHealth()
	d.StartMCPEvents()
	d.StartMachineWatch()
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
	// web and webPort: the page to serve on loopback, when the control plane runs elsewhere
	// (#1951). Agents Host gives them only then.
	web     string
	webPort int
	// pinAddress, pinKey and mustJoin: the Mac's managed preferences, as Agents Host gives
	// them (#998, FR-025). /etc/agents/policy.json, when there is one, wins.
	pinAddress string
	pinKey     string
	mustJoin   bool
	args       []string
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
		case "--must-join":
			cl.mustJoin = true
		}
	}
	cl.root = value("--root")
	cl.code = value("--control")
	if cl.code == "" {
		cl.code = value("--control-code")
	}
	cl.hostName = value("--host-name")
	cl.pinAddress = value("--pin-address")
	cl.pinKey = value("--pin-key")
	cl.web = value("--web")
	cl.webPort, _ = strconv.Atoi(value("--web-port"))
	if cl.root == "" {
		cl.root = os.Getenv("AGENTS_ROOT")
	}
	if cl.root == "" {
		// The ordinary root, Application Support/Agents, as Foundation has it on this OS.
		home, _ := os.UserHomeDir()
		cl.root = store.StandardRoot(home)
	}
	if strings.HasPrefix(cl.root, "~/") {
		home, _ := os.UserHomeDir()
		cl.root = filepath.Join(home, cl.root[2:])
	}
	cl.root, _ = filepath.Abs(cl.root)
	return cl
}

// machinePin is the pin (#998, US7): /etc/agents/policy.json when root owns it and nobody
// else can write it, or else the managed preferences Agents Host gave. Read once, at start.
func machinePin(cl commandLine) *agentsd.MachinePin {
	pin, err := agentsd.ReadPinFile(agentsd.PinFile, 0)
	if err != nil {
		log.Printf("pin: %v", err)
	}
	if pin != nil {
		return pin
	}
	return agentsd.PinFromFlags(cl.pinAddress, cl.pinKey, cl.mustJoin)
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
	hello := controllink.MachineHello{Version: buildinfo.Version, Platform: platform(), MachineID: machine.ID(),
		Implementation: new(buildinfo.Implementation), Capabilities: d.Capabilities()}
	if name != "" {
		hello.Name = &name
	}
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
	pin := d.Pin()
	member, err := controllink.LoadMembership(loc.Root)
	if err == nil && member.Host != "" && pin.AdmitsMember(member) != nil {
		// Joined another control plane before the pin: it is not dialled (FR-027).
		member = nil
	}
	askFile := filepath.Join(loc.Root, "control-join-ask")
	if code == "" && (member == nil || member.Host == "") {
		if b, err := os.ReadFile(askFile); err == nil {
			var ask controllink.JoinAsk
			if err := json.Unmarshal(b, &ask); err != nil {
				log.Fatalf("control-join-ask: %v", err)
			}
			if err := pin.Admits(nil, ask.URL); err != nil {
				log.Printf("pin: not asking to join %s: %v", ask.URL, err)
				return
			}
			if member = askToJoin(ctx, loc.Root, ask, private, hello); member == nil {
				return
			}
			os.Remove(askFile)
			os.Remove(filepath.Join(loc.Root, "control-join-shown"))
		}
	}
	if code != "" || member == nil || member.Host == "" {
		if code == "" {
			log.Printf("no membership in the root and no code to enrol with: not joining a control plane")
			return
		}
		member = enrol(ctx, code, codeFile, func(ctx context.Context, c *controllink.Code) (*controllink.Membership, error) {
			// A code for another control plane is refused here, before it is used (FR-027).
			if err := pin.Admits(c.ControlKey, c.URL); err != nil {
				return nil, err
			}
			return controllink.Enroll(ctx, loc.Root, c, private, hello)
		})
		if member == nil {
			return
		}
		os.Remove(codeFile)
		log.Printf("enrolled as host %s with %s", member.Host, member.Name)
	}
	if err := pin.AdmitsMember(member); err != nil {
		// An approved ask that turned out to be another control plane's key.
		log.Printf("pin: the control plane joined is not the one required, and is not used: %v", err)
		return
	}
	// The organisation's policy is checked with the control key (#998).
	d.SetControlKey(member.ControlKey)
	d.SetMember(member)
	up := &controllink.Uplink{Root: loc.Root, Member: member, Private: private, Hello: hello, Accept: d.Accept,
		Lend: d.LendingPort, Rotated: func(key []byte) { d.ControlKeyRotated(key); d.MoveLocal(key) }}
	d.Tunneler = up
	// The needs it shows nowhere go to the control plane, offered again on each return (#1367).
	up.OnChange = func(connected bool, problem string) {
		writeJoinStatus(loc.Root, connected, problem)
		safe.Go("attention uplink", func() { d.ControlUplinkChanged(connected) })
	}
	up.Told = d.Told
	up.Asked = d.Asked
	// A window on this Mac reaches this host directly (#1118).
	d.StartLocal(ctx, member, private)
	// And a browser on it, through the page this host serves (#1951).
	if cl.web != "" {
		d.StartPage(ctx, private, cl.web, cl.webPort)
	}
	d.SetControl(up.Tell)
	d.SetControlAsk(up.Ask)
	safe.Go("uplink", func() {
		// A panic in the uplink would leave the host up but offline: dial again.
		for ctx.Err() == nil && safe.Catch("uplink", func() { up.Run(ctx) }) != nil {
			time.Sleep(time.Second)
		}
	})
}

// askToJoin asks to join with no code (#994) until the person approves it, asking again
// when a request is denied or runs out, or the control plane can't be reached.
func askToJoin(ctx context.Context, root string, ask controllink.JoinAsk, private []byte, hello controllink.MachineHello) *controllink.Membership {
	for {
		member, err := controllink.AskToJoin(ctx, root, ask, private, hello, func(code string) {
			os.WriteFile(filepath.Join(root, "control-join-shown"), []byte(code+"\n"), 0o600)
			log.Printf("asking to join %s as %s: approve it on a client; the code is %s", ask.URL, ask.Person, code)
		})
		if err == nil {
			log.Printf("joined as host %s with %s, by approval", member.Host, member.Name)
			return member
		}
		if ctx.Err() != nil {
			return nil
		}
		log.Printf("could not join: %v; asking again in 30 s", err)
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(30 * time.Second):
		}
	}
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

// personalHome is StoreLocations.personalHome: AGENTS_PERSONAL_HOME first, then the
// account's home for a server (--serve) or the ordinary root, and none for any other root,
// which keeps its settings in <root>/settings and never writes the real ~/.agents.
func personalHome(cl commandLine) string {
	if named := os.Getenv("AGENTS_PERSONAL_HOME"); named != "" {
		return named
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	if cl.serve || store.IsStandard(cl.root) {
		return home
	}
	return ""
}

func isTerminal() bool {
	fi, err := os.Stdout.Stat()
	return err == nil && isTerminalFile(fi)
}

// isTerminalFile is a character device other than /dev/null: launchd gives the Mac's host
// /dev/null, a character device too, and its log went nowhere (#1392).
func isTerminalFile(fi os.FileInfo) bool {
	if fi.Mode()&os.ModeCharDevice == 0 {
		return false
	}
	null, err := os.Stat(os.DevNull)
	return err != nil || !os.SameFile(fi, null)
}

// ordinaryRoot is StoreLocations.isStandard: the root a person's host uses, where an
// invented event would be a lie (Application Support/Agents, or an installed server's).
func ordinaryRoot(root string) bool {
	home, _ := os.UserHomeDir()
	return store.IsStandard(root) || filepath.Clean(root) == filepath.Join(home, ".agents-server", "root")
}
