package agentsd

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The direct local path (#1118). A window on this Mac reaches this host over a socket,
// not out to the control plane and back, so it is quick, and it still works with the
// control plane away. The socket is in the app group that the App Store window and Agents
// Host share (team-prefixed, so it needs no provisioning profile), and is named by the
// control plane's key, so a scratch control plane's host never takes the person's.
//
// The control plane stays the authority for who may connect. The host lets in only a
// window the control plane lists as paired (host/clients), and keeps that list in its root
// for when the control plane is away. The window proves its key with the control plane's
// own exchange (hello, auth, ok), with this host's key in place of the control plane's.
// What it does is then what it would do through the control plane: the host tells every
// client, those on its uplink too, so every other screen sees the same thing.

// LocalGroup is the app group both apps are entitled to.
const LocalGroup = "6T4RVD5724.com.alexecollins.agents"

// localOrigin is what both MACs of the exchange bind on the local socket, so a proof made
// for the control plane cannot be replayed here, nor one made here there.
const localOrigin = "local:agentsd"

// localClientsFile is the last host/clients, in the root.
const localClientsFile = "control-clients.json"

// localExchangeWait bounds the exchange: a caller that says nothing is let go.
const localExchangeWait = 15 * time.Second

// LocalSocketName is the socket's name in the group: 12 hex digits of the SHA-256 of the
// control plane's key, which the window knows from its own pairing. Short, as a socket's
// whole path is at most 104 bytes.
func LocalSocketName(controlKey []byte) string {
	sum := sha256.Sum256(controlKey)
	return hex.EncodeToString(sum[:6]) + ".sock"
}

// LocalSocketDir is the group's container, or AGENTS_LOCAL_SOCKET_DIR when set (a test's).
func LocalSocketDir(home string) string {
	if dir := os.Getenv("AGENTS_LOCAL_SOCKET_DIR"); dir != "" {
		return dir
	}
	return filepath.Join(home, "Library", "Group Containers", LocalGroup)
}

type localBook struct {
	localMu sync.Mutex
	// localClients is the last host/clients, by upper-case id; nil until read.
	localClients map[string]wire.MachineClient
	// localConns is each connection on the local socket, and the window it proved.
	localConns map[*sockConn]string
	// localKept is what localClientsFile holds, read the first time; it is written only
	// when host/clients differs from it (#1528).
	localKept []byte
	// localKey is the control plane's key the socket is named by, and localMove ends the
	// socket at the old name when it changes (#997).
	localKey  []byte
	localMove context.CancelFunc
}

// MoveLocal is the control plane's new key after a rotation (#997): the socket moves to
// the name the windows now look for.
func (d *Daemon) MoveLocal(controlKey []byte) {
	d.localMu.Lock()
	defer d.localMu.Unlock()
	if bytes.Equal(d.localKey, controlKey) {
		return
	}
	d.localKey = controlKey
	if d.localMove != nil {
		d.localMove()
	}
}

// SetLocalClients is host/clients: the windows the control plane lists as paired. It is
// kept in the root, and a window no longer listed (forgotten) is cut off at once.
func (d *Daemon) SetLocalClients(list wire.MachineClients) {
	clients := ownUsersWindows(list)
	if list.Clients == nil {
		list.Clients = []wire.MachineClient{}
	}
	b, _ := json.Marshal(list)
	file := filepath.Join(d.Store.Loc.Root, localClientsFile)
	d.localMu.Lock()
	d.localClients = clients
	var gone []*sockConn
	for sc, id := range d.localConns {
		if _, ok := clients[id]; !ok {
			gone = append(gone, sc)
		}
	}
	if d.localKept == nil {
		d.localKept, _ = os.ReadFile(file)
	}
	same := bytes.Equal(b, d.localKept)
	if !same {
		d.localKept = b
	}
	d.localMu.Unlock()
	for _, sc := range gone {
		sc.Close()
	}
	if same {
		return
	}
	tmp := file + ".tmp"
	if err := os.WriteFile(tmp, b, 0o600); err == nil {
		err = os.Rename(tmp, file)
		if err != nil {
			log.Printf("local: keep %s: %v", localClientsFile, err)
		}
	} else {
		log.Printf("local: keep %s: %v", localClientsFile, err)
	}
}

// ownUsersWindows is the windows of a host/clients by upper-case id: of the host's own user
// only, when the control plane says who that is (FR-020). A window of another person is
// never let in here, even if a control plane lists it; an older control plane, which says
// no user, is taken at its word.
func ownUsersWindows(list wire.MachineClients) map[string]wire.MachineClient {
	clients := map[string]wire.MachineClient{}
	for _, c := range list.Clients {
		if list.User != nil && (c.Person == nil || *c.Person != *list.User) {
			continue
		}
		clients[strings.ToUpper(string(c.ID))] = c
	}
	return clients
}

// localClient is a window the control plane last listed, read from the root the first
// time, as the host may start with the control plane away.
func (d *Daemon) localClient(id string) (wire.MachineClient, bool) {
	d.localMu.Lock()
	defer d.localMu.Unlock()
	if d.localClients == nil {
		d.localClients = map[string]wire.MachineClient{}
		var kept wire.MachineClients
		if b, err := os.ReadFile(filepath.Join(d.Store.Loc.Root, localClientsFile)); err == nil && json.Unmarshal(b, &kept) == nil {
			d.localClients = ownUsersWindows(kept)
		}
	}
	c, ok := d.localClients[strings.ToUpper(id)]
	return c, ok
}

// Told is what the control plane tells this host on its uplink's channel 0.
func (d *Daemon) Told(method string, params json.RawMessage) {
	if method == wire.NotifyHostUserSettings.Name {
		d.toldUserSettings(params)
		return
	}
	if method == wire.NotifyHostUser.Name {
		d.toldHostUser(params)
		return
	}
	if method == wire.NotifyHostPolicy.Name {
		d.toldPolicy(params)
		return
	}
	if method == wire.NotifyUserSuspended.Name {
		d.toldUserSuspended(params)
		return
	}
	if method == wire.NotifyHostRelease.Name {
		d.toldRelease(params)
		return
	}
	if method == wire.NotifyHostOrgRoutes.Name {
		d.toldOrgRoutes(params)
		return
	}
	if method != wire.NotifyHostClients.Name {
		return
	}
	var list wire.MachineClients
	if err := json.Unmarshal(params, &list); err != nil {
		log.Printf("local: %s: %v", method, err)
		return
	}
	d.SetLocalClients(list)
}

// StartLocal serves the local socket for as long as ctx, on a Mac: for this host as the
// member it is, with its private key. Until the group's container is there (agents-peer
// makes it, or the window when it starts) it tries again every half minute.
func (d *Daemon) StartLocal(ctx context.Context, member *controllink.Membership, private []byte) {
	if !localPathHere() || member == nil || len(member.ControlKey) == 0 || member.Host == "" {
		return
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return
	}
	dir := LocalSocketDir(home)
	d.localMu.Lock()
	d.localKey = append([]byte(nil), member.ControlKey...)
	d.localMu.Unlock()
	host := member.Host
	safe.Go("local", func() {
		said := false
		for ctx.Err() == nil {
			d.localMu.Lock()
			path := filepath.Join(dir, LocalSocketName(d.localKey))
			serving, move := context.WithCancel(ctx)
			d.localMove = move
			d.localMu.Unlock()
			if len(path) >= 104 {
				move()
				log.Printf("local: %s is too long for a socket; windows here go through the control plane", path)
				return
			}
			if !isDir(dir) {
				makeLocalGroup()
			}
			if isDir(dir) {
				err := d.ServeLocal(serving, path, host, private)
				moved := serving.Err() != nil && ctx.Err() == nil
				move()
				if ctx.Err() != nil {
					return
				}
				if moved {
					continue // rotated: listen again at once, under the new key's name
				}
				log.Printf("local: %v", err)
			} else if !said {
				said = true
				log.Printf("local: no %s yet; trying again until the window makes it", dir)
			}
			select {
			case <-ctx.Done():
				return
			case <-time.After(30 * time.Second):
			}
		}
	})
}

// ServeLocal answers on the local socket at path, as host, with this host's private key,
// until ctx ends.
func (d *Daemon) ServeLocal(ctx context.Context, path, host string, private []byte) error {
	os.Remove(path)
	l, err := net.Listen("unix", path)
	if err != nil {
		return err
	}
	os.Chmod(path, 0o600)
	policy := d.socketPolicy()
	log.Printf("local: a window on this Mac may connect at %s", path)
	safe.Go("local close", func() { <-ctx.Done(); l.Close(); os.Remove(path) })
	for {
		c, err := l.Accept()
		if err != nil {
			return err
		}
		safe.Go("local accept", func() { d.acceptLocal(c, policy, host, private) })
	}
}

func (d *Daemon) acceptLocal(c net.Conn, policy SocketPolicy, host string, private []byte) {
	// Another account, or a program of this one that is not the window.
	role, ok := policy.Role(c)
	if !ok || (role != RoleControl && role != RoleWindow) {
		c.Close()
		return
	}
	c.SetDeadline(time.Now().Add(localExchangeWait))
	r := bufio.NewReaderSize(c, 1<<20)
	client, err := d.localExchange(c, r, host, private)
	if errors.Is(err, io.EOF) {
		// Gone at the hello, before any proof: a window that wanted another host (#1497).
		c.Close()
		return
	}
	if err != nil {
		reason := controllink.BadMessage
		if refusal, ok := err.(*controllink.Refusal); ok {
			reason = refusal.Reason
		}
		c.Write([]byte(controllink.Message{Refused: reason}.Line() + "\n"))
		log.Printf("local: a window was refused: %v", err)
		c.Close()
		return
	}
	c.SetDeadline(time.Time{})
	// A Mac's window is the Mac, as on the control plane's channel: it names no device.
	sc := newSockConn(c, RoleControl)
	d.localMu.Lock()
	if d.localConns == nil {
		d.localConns = map[*sockConn]string{}
	}
	d.localConns[sc] = client
	d.localMu.Unlock()
	log.Printf("local: window %s connected", client)
	defer func() {
		d.localMu.Lock()
		delete(d.localConns, sc)
		d.localMu.Unlock()
		log.Printf("local: window %s went", client)
	}()
	d.serveSockConn(sc, r)
}

// localExchange is the control plane's exchange, with this host as the server: it says
// hello with its own key, checks the window's auth against the clients it was told of,
// and proves its key back, naming itself. It returns the window's id.
func (d *Daemon) localExchange(c net.Conn, r *bufio.Reader, host string, private []byte) (string, error) {
	public, err := controllink.PublicKey(private)
	if err != nil {
		return "", err
	}
	nonce := controllink.Nonce()
	hello := controllink.Message{Hello: &wire.ControlHello{V: controllink.Version, Name: host,
		Control: controllink.B64URL(public), Nonce: controllink.B64URL(nonce)}}
	if _, err := c.Write([]byte(hello.Line() + "\n")); err != nil {
		return "", err
	}
	line, err := r.ReadString('\n')
	if err != nil {
		return "", err
	}
	m, ok := controllink.ParseMessage(strings.TrimSuffix(line, "\n"))
	if !ok || m.Auth == nil {
		return "", controllink.Refuse(controllink.BadMessage)
	}
	id, mac, err := controllink.Verify(m.Auth, nonce, []string{localOrigin}, func(id controllink.Identity) ([]byte, error) {
		if id.Kind != 'c' {
			return nil, controllink.Refuse(controllink.Unknown)
		}
		known, ok := d.localClient(id.ID)
		if !ok {
			return nil, controllink.Refuse(controllink.Unknown)
		}
		return controllink.ClientKey(private, known.PublicKey, id.ID)
	})
	if err != nil {
		return "", err
	}
	if d.suspension() != nil {
		// The person is suspended (#1002, FR-018): their window is refused here too.
		return "", controllink.Refuse(controllink.Suspended)
	}
	ok2 := controllink.Message{OK: &wire.ControlOK{Mac: controllink.B64URL(mac), Host: new(wire.MachineRef(host))}}
	if _, err := c.Write([]byte(ok2.Line() + "\n")); err != nil {
		return "", err
	}
	return id.ID, nil
}
