package controlplane

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/hostinstall"
	"github.com/alexec/agents/Go/internal/controlplane/hosttunnels"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// A provider gives its ssh as a person types it, agents@127.0.0.1 -p 2224 (the Docker
// preset's ssh field). The start over ssh hands ssh one word for it (#857): as three, ssh
// said "hostname contains invalid characters" and the host never came back.
func TestAStartOverSSHTakesAProvidersDestinationWithAPort(t *testing.T) {
	t.Parallel()
	folder := t.TempDir()
	said := filepath.Join(folder, "said")
	ssh := filepath.Join(folder, "ssh")
	script := "#!/bin/sh\nfor word in \"$@\"; do printf '%s\\n' \"$word\"; done >> '" + said + "'\n"
	if err := os.WriteFile(ssh, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	s := &Service{installer: &hostinstall.Installer{SSH: ssh}}
	if err := s.sshStart(records.MachineRecord{ID: "box", Name: "w857-box"}, "agents@127.0.0.1 -p 2224", false); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(said)
	if err != nil {
		t.Fatal(err)
	}
	words := strings.Split(string(data), "\n")
	found := false
	for _, w := range words {
		found = found || w == "ssh://agents@127.0.0.1:2224"
		if w == "agents@127.0.0.1 -p 2224" || w == "agents@127.0.0.1" {
			t.Errorf("ssh was given %q", w)
		}
	}
	if !found {
		t.Errorf("ssh was not given ssh://agents@127.0.0.1:2224: %q", words)
	}
}

// keyedSSH is an ssh that says its words to said and, as ssh with accept-new does, adds
// the key it is "offered" to the known hosts file it is given.
func keyedSSH(t *testing.T, key string) (ssh, said string) {
	folder := t.TempDir()
	said = filepath.Join(folder, "said")
	ssh = filepath.Join(folder, "ssh")
	script := "#!/bin/sh\nfor word in \"$@\"; do printf '%s\\n' \"$word\" >> '" + said + "'\n" +
		"case \"$word\" in UserKnownHostsFile=*) file=\"${word#UserKnownHostsFile=}\";; esac; done\n" +
		"grep -q ' " + key + "$' \"$file\" 2>/dev/null || echo 'agents-pinned-host ssh-ed25519 " + key + "' >> \"$file\"\n"
	if err := os.WriteFile(ssh, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return ssh, said
}

// tunnelFor is the tunnels with one record, for host, installed over destination with key.
func tunnelFor(t *testing.T, host, destination, key string) *hosttunnels.Tunnels {
	tunnels := hosttunnels.New(hosttunnels.Config{Store: store.NewMemory(), SSH: "/usr/bin/false", Port: 1,
		Hosts: func(context.Context) []records.MachineRecord { return []records.MachineRecord{{ID: host, Name: host}} }})
	t.Cleanup(tunnels.Stop)
	if err := tunnels.Add(context.Background(), hosttunnels.Record{ID: "t-" + host, Destination: destination, Name: host,
		Port: 1, Code: "c", Host: &host, KnownHosts: destination + " ssh-ed25519 " + key + "\n", Made: records.Now()}); err != nil {
		t.Fatal(err)
	}
	return tunnels
}

// A Google Cloud workstation's container is made again at each start, so its host key is
// new (#1701). After the control plane's own Start, the ssh start takes the key it is
// offered and pins it for the host's tunnel; the old one is not asked for.
func TestAStartOverSSHPinsTheNewKeyOfAWorkspaceThatRenewsIt(t *testing.T) {
	t.Parallel()
	ssh, said := keyedSSH(t, "NEWKEY")
	s := &Service{installer: &hostinstall.Installer{SSH: ssh}, tunnels: tunnelFor(t, "ws", "w1701-ws", "OLDKEY"),
		cfg: Config{Log: func(string) {}}}
	if err := s.sshStart(records.MachineRecord{ID: "ws", Name: "w1701-ws"}, "w1701-ws", true); err != nil {
		t.Fatal(err)
	}
	if _, keys, _ := s.tunnels.Installed("ws"); keys != "agents-pinned-host ssh-ed25519 NEWKEY\n" {
		t.Errorf("pinned %q", keys)
	}
	data, _ := os.ReadFile(said)
	if !strings.Contains(string(data), "StrictHostKeyChecking=accept-new") {
		t.Errorf("ssh was not told to take a new key: %q", data)
	}
}

// Without renewKey a key is never taken: the one trusted at the install is checked.
func TestAStartOverSSHKeepsTheInstallsKeyOtherwise(t *testing.T) {
	t.Parallel()
	ssh, said := keyedSSH(t, "OLDKEY")
	s := &Service{installer: &hostinstall.Installer{SSH: ssh}, tunnels: tunnelFor(t, "vm", "agents@10.0.0.1", "OLDKEY"),
		cfg: Config{Log: func(string) {}}}
	if err := s.sshStart(records.MachineRecord{ID: "vm", Name: "w1691-vm"}, "agents@10.0.0.2", false); err != nil {
		t.Fatal(err)
	}
	if _, keys, _ := s.tunnels.Installed("vm"); keys != "agents@10.0.0.1 ssh-ed25519 OLDKEY\n" {
		t.Errorf("pinned %q", keys)
	}
	data, _ := os.ReadFile(said)
	words := string(data)
	// The new address, checked against the install's key under its alias (#1691).
	for _, want := range []string{"agents@10.0.0.2", "HostKeyAlias=agents-pinned-host", "StrictHostKeyChecking=yes"} {
		if !strings.Contains(words, want+"\n") {
			t.Errorf("ssh was not given %q: %q", want, words)
		}
	}
	if strings.Contains(words, "accept-new") {
		t.Errorf("ssh was told to take a new key: %q", words)
	}
}

// uplinkStandIn is a host's uplink that reads nothing until it is closed.
type uplinkStandIn struct{ closed chan struct{} }

func (u *uplinkStandIn) Send(string) bool { return true }
func (u *uplinkStandIn) Read(ctx context.Context) (string, error) {
	<-u.closed
	return "", context.Canceled
}
func (u *uplinkStandIn) Close() {
	select {
	case <-u.closed:
	default:
		close(u.closed)
	}
}

// #1701: a host whose workspace was stopped is closed and shown offline, so a Start waits
// for its new connection.
func TestAStoppedHostsUplinkIsClosedAndOffline(t *testing.T) {
	t.Parallel()
	r := NewRouter(nil, nil)
	up := &uplinkStandIn{closed: make(chan struct{})}
	r.AttachHost("ws", up)
	if state, _ := r.State("ws"); !state.online() {
		t.Fatalf("%+v", state)
	}
	r.CloseStopped("ws")
	select {
	case <-up.closed:
	default:
		t.Fatal("its uplink is still open")
	}
	if state, _ := r.State("ws"); state.online() || r.Reaches("ws") {
		t.Fatalf("%+v", state)
	}
	r.CloseStopped("nobody")
}
