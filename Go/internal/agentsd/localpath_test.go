package agentsd

import (
	"bufio"
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/wire"
)

// window is a paired window's key, as host/clients lists it.
type window struct {
	id      string
	private []byte
}

func newWindow(t *testing.T) (window, wire.MachineClient) {
	t.Helper()
	w := window{id: "C0000000-0000-4000-8000-000000001118", private: controllink.NewPrivateKey()}
	public, err := controllink.PublicKey(w.private)
	if err != nil {
		t.Fatal(err)
	}
	return w, wire.MachineClient{ID: wire.UUID(w.id), Kind: "mac", PublicKey: public}
}

// serveLocal serves d's local socket as host "mac" with a test's door, and says where.
func serveLocal(t *testing.T, d *Daemon, role Role) string {
	t.Helper()
	old := socketPolicyFor
	socketPolicyFor = func(*Daemon) SocketPolicy { return fixedPolicy{role: role, ok: true} }
	t.Cleanup(func() { socketPolicyFor = old })
	dir, err := os.MkdirTemp("", "local") // short: a Unix socket's path is at most 104 bytes
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	path := filepath.Join(dir, LocalSocketName([]byte("control key")))
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go d.ServeLocal(ctx, path, "mac", controllink.NewPrivateKey())
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); time.Sleep(10 * time.Millisecond) {
		if _, err := os.Stat(path); err == nil {
			return path
		}
	}
	t.Fatal("the local socket never came")
	return ""
}

// prove dials the local socket as w and runs the exchange, as the window does
// (LocalHostLink.swift): the reader after it, and the host's ok, or its refusal.
func prove(t *testing.T, path string, w window) (net.Conn, *bufio.Reader, controllink.Message) {
	t.Helper()
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { c.Close() })
	c.SetDeadline(time.Now().Add(5 * time.Second))
	r := bufio.NewReader(c)
	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	m, ok := controllink.ParseMessage(strings.TrimSpace(line))
	if !ok || m.Hello == nil {
		t.Fatal(line)
	}
	hostKey, _ := controllink.FromB64URL(m.Hello.Control)
	key, err := controllink.ClientKey(w.private, hostKey, w.id)
	if err != nil {
		t.Fatal(err)
	}
	auth, expect, err := controllink.Answer(m.Hello, controllink.Identity{Kind: 'c', ID: w.id}, key, localOrigin, "mac", nil, "", nil)
	if err != nil {
		t.Fatal(err)
	}
	c.Write([]byte(controllink.Message{Auth: auth}.Line() + "\n"))
	line, err = r.ReadString('\n')
	if err != nil {
		return c, r, controllink.Message{Refused: "closed"}
	}
	reply, ok := controllink.ParseMessage(strings.TrimSpace(line))
	if !ok {
		t.Fatal(line)
	}
	if reply.OK != nil {
		if err := controllink.Check(reply.OK, expect); err != nil {
			t.Fatal("the host's proof:", err)
		}
	}
	c.SetDeadline(time.Time{})
	return c, r, reply
}

// A window the control plane lists proves its key on the local socket, is told which
// host it reached, and is then served as through the control plane (#1118).
func TestAPairedWindowReachesTheHostDirectly(t *testing.T) {
	d, _ := start(t, t.TempDir())
	w, listed := newWindow(t)
	d.SetLocalClients(wire.MachineClients{Clients: []wire.MachineClient{listed}})
	path := serveLocal(t, d, RoleWindow)
	c, r, reply := prove(t, path, w)
	if reply.OK == nil || reply.OK.Host == nil || *reply.OK.Host != "mac" {
		t.Fatalf("%+v", reply)
	}
	c.Write([]byte(`{"jsonrpc":"2.0","id":7,"method":"daemon/status"}` + "\n"))
	c.SetDeadline(time.Now().Add(5 * time.Second))
	line, err := r.ReadString('\n')
	if err != nil || !strings.Contains(line, `"id":7`) || !strings.Contains(line, `"result"`) {
		t.Fatal(line, err)
	}
	// It hears what the host tells every window.
	d.mu.Lock()
	n := len(d.clients)
	d.mu.Unlock()
	if n < 2 {
		t.Fatalf("%d clients hear the host", n)
	}
}

// A window the control plane does not list is refused, and so is one it lists that
// cannot prove the key.
func TestAnUnknownWindowIsRefused(t *testing.T) {
	d, _ := start(t, t.TempDir())
	w, listed := newWindow(t)
	path := serveLocal(t, d, RoleWindow)
	if _, _, reply := prove(t, path, w); reply.Refused != controllink.Unknown {
		t.Fatalf("%+v", reply)
	}
	d.SetLocalClients(wire.MachineClients{Clients: []wire.MachineClient{listed}})
	impostor := window{id: w.id, private: controllink.NewPrivateKey()}
	if _, _, reply := prove(t, path, impostor); reply.Refused != controllink.BadProof {
		t.Fatalf("%+v", reply)
	}
}

// Another program of this account is closed before a line is said.
func TestAStrangerGetsNoHello(t *testing.T) {
	d, _ := start(t, t.TempDir())
	path := serveLocal(t, d, RoleStranger)
	c, err := net.Dial("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if line, err := bufio.NewReader(c).ReadString('\n'); err == nil {
		t.Fatal(line)
	}
}

// A window forgotten at the control plane is cut off at once, and the list is kept in the
// root for a host that starts with the control plane away.
func TestAForgottenWindowIsCutOff(t *testing.T) {
	root := t.TempDir()
	d, _ := start(t, root)
	w, listed := newWindow(t)
	d.SetLocalClients(wire.MachineClients{Clients: []wire.MachineClient{listed}})
	path := serveLocal(t, d, RoleWindow)
	c, r, reply := prove(t, path, w)
	if reply.OK == nil {
		t.Fatalf("%+v", reply)
	}
	d.Told(wire.NotifyHostClients.Name, []byte(`{"clients":[]}`))
	c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := r.ReadString('\n'); err == nil {
		t.Fatal("a forgotten window is still connected")
	}

	d.SetLocalClients(wire.MachineClients{Clients: []wire.MachineClient{listed}})
	again := &Daemon{Store: d.Store}
	if _, ok := again.localClient(strings.ToLower(w.id)); !ok {
		t.Fatal("the list was not kept in the root")
	}
}

// control-clients.json is written only when host/clients changes, not on every notice
// (#1528), and a host that starts with the same list kept does not write it again.
func TestTheLocalClientsFileIsWrittenOnlyWhenItChanges(t *testing.T) {
	root := t.TempDir()
	d, _ := start(t, root)
	_, listed := newWindow(t)
	list := wire.MachineClients{Clients: []wire.MachineClient{listed}}
	file := filepath.Join(d.Store.Loc.Root, localClientsFile)
	d.SetLocalClients(list)
	old := time.Now().Add(-time.Hour).Truncate(time.Second)
	if err := os.Chtimes(file, old, old); err != nil {
		t.Fatal(err)
	}
	written := func() bool {
		info, err := os.Stat(file)
		if err != nil {
			t.Fatal(err)
		}
		return !info.ModTime().Equal(old)
	}
	// Forty notices are ten minutes of the control plane's refreshes.
	for range 40 {
		d.SetLocalClients(list)
	}
	if written() {
		t.Fatal("an unchanged host/clients wrote the file again")
	}
	// Another daemon over the same root, as after a restart, finds the list kept.
	again := &Daemon{Store: d.Store}
	again.SetLocalClients(list)
	if written() {
		t.Fatal("a host that started with the same list kept wrote it again")
	}
	d.SetLocalClients(wire.MachineClients{})
	if !written() {
		t.Fatal("a changed host/clients was not written")
	}
	if b, _ := os.ReadFile(file); string(b) != `{"clients":[]}` {
		t.Fatalf("the file holds %s", b)
	}
}

// #997: the control plane rotated its key, and the socket moves to the name the windows
// now look for.
func TestTheLocalSocketMovesWithARotatedKey(t *testing.T) {
	if !localPathHere() {
		t.Skip("the local socket is a Mac's")
	}
	dir, err := os.MkdirTemp("", "local")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	t.Setenv("AGENTS_LOCAL_SOCKET_DIR", dir)
	d, _ := start(t, t.TempDir())
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	d.StartLocal(ctx, &controllink.Membership{Host: "mac", ControlKey: []byte("old key")}, controllink.NewPrivateKey())
	at := func(key string) func() bool {
		return func() bool { _, err := os.Stat(filepath.Join(dir, LocalSocketName([]byte(key)))); return err == nil }
	}
	waitFor(t, "the socket at the old key's name", at("old key"))
	d.MoveLocal([]byte("new key"))
	waitFor(t, "the socket at the new key's name", at("new key"))
	waitFor(t, "the old name gone", func() bool { return !at("old key")() })
}

// A window of another person is never let in on the local socket, even if a control plane
// lists it, once it says whose host this is (FR-020); one of the host's own user is.
func TestOnlyTheHostsOwnUsersWindowIsLetIn(t *testing.T) {
	d, _ := start(t, t.TempDir())
	mine, listedMine := newWindow(t)
	theirs, listedTheirs := newWindow(t)
	alex, sam := "alex", "sam"
	listedMine.Person, listedTheirs.Person = &alex, &sam
	d.SetLocalClients(wire.MachineClients{User: &alex, Clients: []wire.MachineClient{listedMine, listedTheirs}})
	path := serveLocal(t, d, RoleWindow)
	if _, _, reply := prove(t, path, mine); reply.OK == nil {
		t.Fatalf("the host's own user's window: %+v", reply)
	}
	if _, _, reply := prove(t, path, theirs); reply.OK != nil {
		t.Fatal("another person's window was let in")
	}
	// An older control plane says no user: every window listed, as before.
	d.SetLocalClients(wire.MachineClients{Clients: []wire.MachineClient{listedTheirs}})
	if _, ok := d.localClient(theirs.id); !ok {
		t.Fatal("a window an older control plane listed was not kept")
	}
}
