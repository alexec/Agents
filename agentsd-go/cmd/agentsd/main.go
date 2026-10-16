// agentsd (Go spike, #1125): a host that joins the control plane as the Swift agentsd does,
// and runs agents over ACP. Throwaway; see specs/1125-go-agentsd/report.md.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"

	"github.com/alexec/agents/agentsd-go/internal/control"
	"github.com/alexec/agents/agentsd-go/internal/daemon"
)

const version = "0.1.0-go"

func main() {
	root := flag.String("root", "", "the host's root (its identity)")
	serve := flag.Bool("serve", false, "never exit for being idle")
	detach := flag.Bool("detach", false, "start in the background and return")
	network := flag.Bool("control-network", false, "dial the control plane with the membership in the root")
	code := flag.String("control", "", "a host code, used once to enrol")
	code2 := flag.String("control-code", "", "the same as --control")
	hostName := flag.String("host-name", "", "what the control plane lists this host as")
	flag.Parse()
	_ = serve
	if *root == "" {
		home, _ := os.UserHomeDir()
		*root = filepath.Join(home, ".agents-go", "root")
	}
	if *code == "" {
		*code = *code2
	}
	if err := os.MkdirAll(*root, 0o700); err != nil {
		log.Fatal(err)
	}
	if *detach {
		var args []string
		for _, a := range os.Args[1:] {
			if a != "--detach" && a != "-detach" {
				args = append(args, a)
			}
		}
		logf, _ := os.OpenFile(filepath.Join(*root, "daemon.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
		cmd := exec.Command(os.Args[0], args...)
		cmd.Stdout, cmd.Stderr = logf, logf
		cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
		if err := cmd.Start(); err != nil {
			log.Fatal(err)
		}
		fmt.Printf("agentsd started, pid %d\n", cmd.Process.Pid)
		return
	}
	if !isTerminal() {
		// Detached or under a service: the log is the root's daemon.log.
		if f, err := os.OpenFile(filepath.Join(*root, "daemon.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); err == nil {
			log.SetOutput(f)
		}
	}
	os.WriteFile(filepath.Join(*root, "daemon.lock"), []byte(fmt.Sprint(os.Getpid())), 0o600)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	d, err := daemon.New(ctx, *root)
	if err != nil {
		log.Fatal(err)
	}
	go func() {
		if err := d.ServeSocket(ctx, filepath.Join(*root, "daemon.sock")); err != nil {
			log.Printf("socket: %v", err)
		}
	}()

	name := *hostName
	if name == "" {
		name, _ = os.Hostname()
	}
	hello := control.HostHello{Version: version, Platform: platform(), MachineID: machineID(), Name: name}
	if *code == "" {
		if b, err := os.ReadFile(filepath.Join(*root, "control-join-code")); err == nil {
			*code = strings.TrimSpace(string(b))
		}
	}
	if *code != "" || *network {
		private, err := control.HostPrivateKey(*root)
		if err != nil {
			log.Fatal(err)
		}
		member, err := control.LoadMembership(*root)
		if err != nil || member.Host == "" {
			if *code == "" {
				log.Fatal("no membership in the root, and no code to enrol with")
			}
			c, err := control.ParseCode(*code)
			if err != nil {
				log.Fatal(err)
			}
			member, err = control.Enroll(ctx, *root, c, private, hello)
			if err != nil {
				log.Fatal(err)
			}
			os.Remove(filepath.Join(*root, "control-join-code"))
			log.Printf("enrolled as host %s with %s", member.Host, member.Name)
		}
		up := &control.Uplink{Root: *root, Member: member, Private: private, Hello: hello, Accept: d.Accept}
		d.SetTunneler(up)
		d.HostID = member.Host
		go up.Run(ctx)
	}
	log.Printf("agentsd (go) %s on %s, root %s", version, platform(), *root)
	<-ctx.Done()
	d.Shutdown()
}

func platform() string {
	os := "Linux"
	if runtime.GOOS == "darwin" {
		os = "macOS"
	}
	if runtime.GOARCH == "arm64" {
		return os + " arm64"
	}
	return os + " x86-64"
}

func machineID() string {
	if id := os.Getenv("AGENTS_MACHINE_ID"); id != "" {
		return id
	}
	for _, f := range []string{"/etc/machine-id", "/var/lib/dbus/machine-id"} {
		if b, err := os.ReadFile(f); err == nil && len(strings.TrimSpace(string(b))) > 0 {
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
