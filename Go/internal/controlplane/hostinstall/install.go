package hostinstall

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unicode"

	"github.com/alexec/agents/Go/internal/controlplane/hosttunnels"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// CodeIssuer is what MachineInstall needs of ControlCodes: a one-time host code. url is
// the address the code names: "" for the control plane's own, or the server's end of a
// reverse tunnel (#435). The code's text goes to the server. Its id goes in a
// TunnelRecord: its spend says which host the tunnel carries.
type CodeIssuer interface {
	HostCode(ctx context.Context, url string) (text, id string, err error)
}

// Tunnels is where HostTunnels goes (#435, #610): it holds a reverse tunnel for a
// server behind a bastion. Nil where this copy holds none.
type Tunnels interface {
	// Port is the port on both ends: the server's loopback, and this machine's listener.
	Port() int
	// LetGo drops the tunnels held for this destination: the install replaces the host
	// they carried, and their forward would take the port the new one needs.
	LetGo(ctx context.Context, destination, name string)
	// Add is HostTunnels.add: hold a tunnel for a server just installed, at once, so
	// its first dial finds it.
	Add(ctx context.Context, record TunnelRecord) error
}

// TunnelRecord is HostTunnels.Record, stored as v1/tunnels/<id>.json: the tunnels' own.
type TunnelRecord = hosttunnels.Record

// Installer is MachineInstall: hosts/install (058, US4, T072). The control plane installs
// the host on a server the person can ssh to, once, and lets go.
//
//   - A key in the request lives for this call only: written 0600 into a folder of its
//     own and given to `ssh -i`. The folder is removed however the call ends. With no
//     key, ssh logs in as `ssh user@host` would for the person (#413).
//   - The host key is checked against the person's known_hosts first (#610). A key not
//     there is shown (needsTrust) and trusted only when its fingerprint comes back. It
//     goes into the install's own folder, never the person's known_hosts.
//   - No master connection and no forward are kept (FR-018a). The host starts with a host
//     code and enrols over its own connection out.
//   - A server that asks for a tunnel (by default one behind a bastion) is given a code
//     for its own loopback, and Tunnels holds a reverse tunnel there.
type Installer struct {
	Codes CodeIssuer
	// ServerFolder is ServerFiles.folder: the Linux hosts to copy. "" has none.
	ServerFolder string
	// ToolsetFolder is the app's Resources/toolsets: the runtimes to put on a server
	// beside the host (#1136). "" puts none.
	ToolsetFolder string
	// Toolsets are the runtimes whose toolsets an install puts on: nil is DefaultToolsets.
	Toolsets []string
	// NodeDist is where the server fetches Node from: "" is nodejs.org's.
	NodeDist string
	// Log says what went wrong that an install goes on without: a toolset. Nil: nothing.
	Log func(format string, args ...any)
	// SSH is the ssh to run: "" is AGENTS_SSH, else DefaultSSH.
	SSH string
	// ConfigFile is an ssh config for tests, given with -F: "" is AGENTS_SSH_CONFIG,
	// else the person's own ~/.ssh/config.
	ConfigFile string
	// Env is the environment ssh runs with, less this process's own: nil is os.Environ.
	Env []string
	// Progress says each step of an install: connect, checkSystem, setUp, started.
	Progress func(name, step string)
	// Tunnels may be nil: then a server that wants a tunnel is refused.
	Tunnels Tunnels
	// KnownNames are the names of the control plane's hosts, for hosts/detect and
	// hosts/sshHosts. Nil: none.
	KnownNames func(ctx context.Context) []string
}

// Request is MachineInstall.Request: the params of hosts/install. Destination is user@host,
// user@host:port, or a name from the ssh config. Key is the private key's text, OpenSSH or
// PEM (nil or empty: ssh's own choice). Trust is the fingerprint the person was shown and
// trusts, on the second call. Tunnel says whether the server dials back through an ssh
// tunnel (#610); nil: when ssh reaches it through a bastion.
type Request = wire.MachineInstall

func (i *Installer) sshExecutable() string {
	if i.SSH != "" {
		return i.SSH
	}
	if s := os.Getenv("AGENTS_SSH"); s != "" {
		return s
	}
	return DefaultSSH
}

// configFile is MachineInstall.configFile: -F and a config file, or nothing for the
// person's own.
func (i *Installer) configFile() []string {
	file := i.ConfigFile
	if file == "" {
		file = os.Getenv("AGENTS_SSH_CONFIG")
	}
	if file == "" {
		return nil
	}
	return []string{"-F", file}
}

func (i *Installer) env(keepAgent bool) []string {
	inherited := i.Env
	if inherited == nil {
		inherited = os.Environ()
	}
	return environment(keepAgent, inherited)
}

func (i *Installer) progress(name, step string) {
	if i.Progress != nil {
		i.Progress(name, step)
	}
}

// Install is hosts/install: params is a Request. The reply is
// {"needsTrust": fingerprint, "name"} when the host key must be shown first, or
// {"started": true, "name", "platform", "tunnel"} once the host has started.
func (i *Installer) Install(ctx context.Context, params json.RawMessage) (any, error) {
	var request struct {
		Request
		Destination *string `json:"destination"`
	}
	if len(params) == 0 || json.Unmarshal(params, &request) != nil || request.Destination == nil {
		return nil, &Failure{Code: InvalidParams, Message: "Say which server."}
	}
	request.Request.Destination = *request.Destination
	return i.install(ctx, request.Request, false)
}

// Update is hosts/update (#1766): a host this control plane installed over ssh, updated
// the same way, with its server and key given again (the control plane keeps neither).
// The host key is checked as at an install. The server's root must hold this host's own
// membership, so no other server is touched; then its agentsd, MCP servers and toolsets
// are copied, and the host starts again with its root, membership and agents as they were.
// name is the host's, as the control plane knows it. The answer is an install's:
// {needsTrust, name} for a key to trust first, then {updated: true, name}.
func (i *Installer) Update(ctx context.Context, update wire.MachineUpdate, name string) (any, error) {
	request := Request{Destination: update.Destination, Key: update.Key, Trust: update.Trust, Name: &name}
	return i.run(ctx, request, false, string(update.Host))
}

// CheckAgain is hosts/checkAgain. The Swift control plane does nothing for it
// (ControlMethods' default hook), so neither does this.
func (i *Installer) CheckAgain(ctx context.Context, host string) error { return nil }

// trimSpaces is trimmingCharacters(in: .whitespaces): spaces and tabs, not newlines.
func trimSpaces(s string) string {
	return strings.TrimFunc(s, func(r rune) bool { return r != '\n' && r != '\r' && unicode.IsSpace(r) })
}

// install is MachineInstall.run. The host key, in order (#610):
//  1. With no fingerprint to trust, ssh logs in against the person's own known_hosts,
//     with StrictHostKeyChecking=yes. A key there is the one they trust; a changed one
//     is refused, as ssh refuses it.
//  2. No key there: it is fetched and its fingerprint returned (needsTrust).
//  3. With that fingerprint back, the key is fetched again into the install's own
//     known_hosts, checked against it, and the install goes on with that file.
//
// personsKnownHosts: a server found in the ssh config (#429), which ssh has just logged
// into that way. It never asks.
func (i *Installer) install(ctx context.Context, request Request, personsKnownHosts bool) (any, error) {
	return i.run(ctx, request, personsKnownHosts, "")
}

// run is install, or with updating (a host's id) its update: the same connection and
// checks, then the same files, and the host started again in place of a new one joining.
func (i *Installer) run(ctx context.Context, request Request, personsKnownHosts bool, updating string) (any, error) {
	if trimSpaces(request.Destination) == "" {
		return nil, &Failure{Code: InvalidParams, Message: "Say which server."}
	}
	var key string
	if request.Key != nil && strings.TrimSpace(*request.Key) != "" {
		key = *request.Key
	}
	destination := trimSpaces(request.Destination)
	name := label(destination)
	if request.Name != nil && trimSpaces(*request.Name) != "" {
		name = *request.Name
	}

	// One folder for everything this install touches, gone however the call ends.
	folder, err := os.MkdirTemp("", "agents-install-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(folder)
	keyFile := ""
	if key != "" {
		keyFile = filepath.Join(folder, "key")
		if !strings.HasSuffix(key, "\n") {
			key += "\n"
		}
		if os.WriteFile(keyFile, []byte(key), 0o600) != nil {
			return nil, &Failure{Code: InternalError, Message: "The key could not be held for the install."}
		}
	}
	knownHosts := filepath.Join(folder, "known_hosts")
	keyGiven := keyFile != ""
	config := i.configFile()

	ssh := sshCommand{executable: i.sshExecutable(), name: destination, env: i.env(!keyGiven)}
	i.progress(name, "connect")
	trusting := ""
	if request.Trust != nil && !personsKnownHosts {
		trusting = *request.Trust
	}
	var found *facts
	if trusting != "" {
		// The key shown on the first call: fetched again, and used only if it is that one.
		ssh.options = config
		file, fingerprint, err := fetchHostKey(ctx, ssh, folder)
		if err != nil {
			return nil, words(err, keyGiven)
		}
		defer os.Remove(file)
		if trusting != fingerprint {
			return map[string]any{"needsTrust": fingerprint, "name": name}, nil
		}
		if err := os.Rename(file, knownHosts); err != nil {
			return nil, err
		}
		ssh.options = join(config, options(keyFile, knownHosts))
		i.progress(name, "checkSystem")
		if found, err = (installer{ssh}).probe(ctx); err != nil {
			return nil, words(err, keyGiven)
		}
	} else {
		ssh.options = join(config, options(keyFile, ""))
		ssh.options = append(ssh.options, personsKnownHostsOptions(ctx, ssh)...)
		i.progress(name, "checkSystem")
		found, err = (installer{ssh}).probe(ctx)
		if p, ok := err.(*Problem); ok && p.Kind == HostKeyUnknown && !personsKnownHosts {
			fetching := ssh
			fetching.options = config
			file, fingerprint, err := fetchHostKey(ctx, fetching, folder)
			if err != nil {
				return nil, words(err, keyGiven)
			}
			os.Remove(file)
			return map[string]any{"needsTrust": fingerprint, "name": name}, nil
		}
		if err != nil {
			return nil, words(err, keyGiven)
		}
	}

	server := installer{ssh}
	// An update goes only to the server whose root is this host's (#1766).
	if updating != "" {
		if err := server.isHost(ctx, updating, name); err != nil {
			return nil, err
		}
	}
	arch := binarySuffix(found.architecture)
	binary, ok := binaryFor(arch, i.ServerFolder)
	if arch == "" || !ok {
		return nil, &Failure{Code: NotAllowed, Message: name + " is " + found.system + " " +
			displayArchitecture(found.architecture) + ", which this control plane has no host for."}
	}
	i.progress(name, "setUp")
	if err := server.install(ctx, binary.file, binary.sha256, true); err != nil {
		return nil, words(err, keyGiven)
	}
	if err := server.swapCurrent(ctx, binary.sha256, binary.version, "control plane"); err != nil {
		return nil, words(err, keyGiven)
	}
	// The MCP servers Agents ships (#700), beside agentsd. One that fails to copy leaves
	// the host without it, not without a host.
	for _, shipped := range shippedFor(arch, i.ServerFolder) {
		server.installServer(ctx, shipped.name, shipped.file, shipped.sha256)
	}
	// The runtimes' toolsets (#1136), as the window's ToolsetInstaller puts them on a server
	// it holds. One that cannot be installed leaves the host without that runtime, not
	// without a host: the runtime says why when it is chosen.
	i.installToolsets(ctx, server, found, folder, name)

	// An update keeps the host's membership and root: it stops and starts again, as itself.
	if updating != "" {
		if err := server.stopRunning(ctx); err != nil {
			return nil, words(err, keyGiven)
		}
		if err := server.startDaemon(ctx, "--control-network", "--host-name", name); err != nil {
			return nil, words(err, keyGiven)
		}
		i.progress(name, "started")
		return map[string]any{"updated": true, "name": name}, nil
	}

	// A host code, left in the host's root and read once, never on its command line.
	// Through a tunnel, it names the server's end of the tunnel (#435, #610).
	var code string
	var tunnel *TunnelRecord
	wantsTunnel := false
	if request.Tunnel != nil {
		wantsTunnel = *request.Tunnel
	} else {
		wantsTunnel = throughBastion(ctx, ssh)
	}
	if wantsTunnel && i.Tunnels == nil {
		return nil, &Failure{Code: NotAllowed,
			Message: "This control plane can’t hold an ssh tunnel: only one on your Mac can. Add the server without one."}
	}
	if wantsTunnel {
		port := i.Tunnels.Port()
		text, id, err := i.Codes.HostCode(ctx, "https://127.0.0.1:"+strconv.Itoa(port))
		if err != nil {
			return nil, err
		}
		// The key shown and trusted, or the one the person's own known_hosts trusts
		// (#1691): pinned either way, so a new address at a start is still checked.
		trusted := ""
		if trusting != "" {
			data, _ := os.ReadFile(knownHosts)
			trusted = string(data)
		} else {
			trusted = personsKey(ctx, ssh, config, folder)
		}
		tunnel = &TunnelRecord{ID: newID(), Destination: destination, Name: name, Port: port, Code: id,
			KnownHosts: trusted, Made: records.Now()}
		// A tunnel held before for this server goes now, before the steps below: its
		// master would dial again beside them, and its forward holds the port (#1769).
		i.Tunnels.LetGo(ctx, destination, name)
		code = text
	} else {
		text, _, err := i.Codes.HostCode(ctx, "")
		if err != nil {
			return nil, err
		}
		code = text
	}
	if err := server.leaveJoinCode(ctx, code); err != nil {
		return nil, words(err, keyGiven)
	}
	if err := server.startDaemon(ctx, "--control-network", "--host-name", name); err != nil {
		return nil, words(err, keyGiven)
	}
	// The tunnel is held after the install's last ssh step (#1769). A provider's own
	// tunnel, such as gcloud's start-tcp-tunnel, drops connections that open at the same
	// time, and a failed install leaves no tunnel holding the port. The host dials again
	// until the tunnel is up.
	if tunnel != nil {
		if err := i.Tunnels.Add(ctx, *tunnel); err != nil {
			return nil, err
		}
	}
	i.progress(name, "started")
	// The host enrols over its own connection; control/hostChanged says when it is on.
	return map[string]any{"started": true, "name": name,
		"platform": found.system + " " + displayArchitecture(found.architecture), "tunnel": tunnel != nil}, nil
}

// installToolsets puts each toolset the Installer names on the server, and points its
// current at it, before the host starts, so the host finds them at once.
func (i *Installer) installToolsets(ctx context.Context, server installer, found *facts, folder, name string) {
	runtimes := i.Toolsets
	if runtimes == nil {
		runtimes = DefaultToolsets
	}
	dist := i.NodeDist
	if dist == "" {
		dist = nodeDist
	}
	for _, t := range loadToolsets(i.ToolsetFolder, runtimes) {
		if err := server.installToolset(ctx, t, found, dist, folder); err != nil {
			text := err.Error()
			if p, ok := err.(*Problem); ok {
				text = Say(p, true)
			}
			if i.Log != nil {
				i.Log("hosts/install: %s on %s: %s", runtimeName(t.manifest.RuntimeID), name, text)
			}
			continue
		}
		// What the server had free goes down by what this one needs, for the next.
		found.freeBytes -= t.manifest.MinFreeBytes
	}
}

// newID is UUID().uuidString.lowercased(): a random version 4 UUID, in lower case.
func newID() string {
	var b [16]byte
	rand.Read(b[:])
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	h := hex.EncodeToString(b[:])
	return h[0:8] + "-" + h[8:12] + "-" + h[12:16] + "-" + h[16:20] + "-" + h[20:]
}

// throughBastion is MachineInstall.throughBastion: whether the person's ssh config reaches
// this server through another machine. A config ssh cannot read is taken as no bastion.
func throughBastion(ctx context.Context, ssh sshCommand) bool {
	out, err := ssh.run(ctx, join(ssh.options, ssh.resolveArguments()), "")
	if err != nil || out.status != 0 {
		return false
	}
	return throughBastionResolved(out.stdout)
}

// label is MachineInstall.label: agents@devbox.lan:2222 is devbox.lan.
func label(destination string) string {
	host := destination
	if at := strings.LastIndex(host, "@"); at >= 0 {
		host = host[at+1:]
	}
	host = strings.TrimPrefix(host, "ssh://")
	if colon := strings.Index(host, ":"); colon >= 0 {
		host = host[:colon]
	}
	return host
}

// sayErrors is MachineInstall.sayErrors: over a config's LogLevel quiet, which keeps even
// "Host key verification failed" off standard error (#964).
var sayErrors = []string{"-o", "LogLevel=error"}

// options is MachineInstall.options: what ssh is told besides the person's config. The
// host key goes into the install's own known_hosts ("" is the person's). A key given
// is the only one tried; with none, ssh offers what it would for `ssh user@host` (#413).
func options(keyFile, knownHosts string) []string {
	var all []string
	if keyFile != "" {
		all = append(all, "-i", keyFile, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none")
	}
	if knownHosts != "" {
		all = append(all, "-o", "UserKnownHostsFile="+knownHosts, "-o", "GlobalKnownHostsFile=/dev/null")
	}
	all = append(all, "-o", "StrictHostKeyChecking=yes")
	return append(all, sayErrors...)
}

// personsKnownHostsOptions is MachineInstall.personsKnownHosts: the person's own
// known_hosts, for a server whose ssh config checks against none (#514).
func personsKnownHostsOptions(ctx context.Context, ssh sshCommand) []string {
	out, err := ssh.run(ctx, join(ssh.options, ssh.resolveArguments()), "")
	if err != nil || out.status != 0 {
		return nil
	}
	return knownHostsOverride(out.stdout)
}

// knownHostsOverride is MachineInstall.knownHostsOverride: from `ssh -G` output, ssh's
// default known_hosts files when every one it names is /dev/null, otherwise nothing.
// Checking a key against /dev/null always fails.
func knownHostsOverride(resolved string) []string {
	var files []string
	for _, line := range lines(resolved) {
		key, value, ok := strings.Cut(line, " ")
		if !ok || strings.ToLower(key) != "userknownhostsfile" {
			continue
		}
		files = strings.Fields(value)
		break
	}
	if len(files) == 0 {
		return nil
	}
	for _, f := range files {
		if f != "/dev/null" {
			return nil
		}
	}
	return []string{"-o", "UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts2"}
}

// StartDaemon is the machine providers' sshStart hook (#691, #965): a host's agentsd
// started over ssh as an install leaves it, without installing. knownHosts is the key
// trusted at the install, in known_hosts form, checked whatever address the server has now
// (#1691); "" reads the person's own known_hosts. With renew, the server's key is made again
// at each start (#1701): the key it offers is taken and returned, in known_hosts form, to be
// pinned again. A failure is said in the install's words, for the person.
func (i *Installer) StartDaemon(ctx context.Context, destination, knownHosts, name string, renew bool) (string, error) {
	ssh := sshCommand{executable: i.sshExecutable(), name: destination, env: i.env(true)}
	file := ""
	if knownHosts != "" || renew {
		folder, err := os.MkdirTemp("", "agents-start-")
		if err != nil {
			return "", err
		}
		defer os.RemoveAll(folder)
		file = filepath.Join(folder, "known_hosts")
		pinned := hosttunnels.Pinned(knownHosts)
		if renew {
			pinned = ""
		}
		if err := os.WriteFile(file, []byte(pinned), 0o600); err != nil {
			return "", err
		}
	}
	ssh.options = i.configFile()
	if file != "" {
		ssh.options = append(ssh.options, "-o", "HostKeyAlias="+hosttunnels.PinnedAlias)
	}
	if renew {
		// ssh takes the first value it is given: this one, over options' "yes".
		ssh.options = append(ssh.options, "-o", "StrictHostKeyChecking=accept-new")
	}
	ssh.options = append(ssh.options, options("", file)...)
	if file == "" {
		ssh.options = append(ssh.options, personsKnownHostsOptions(ctx, ssh)...)
	}
	if err := (installer{ssh}).startDaemon(ctx, "--control-network", "--host-name", name); err != nil {
		if p, ok := err.(*Problem); ok {
			return "", errors.New(Say(p, false))
		}
		return "", err
	}
	if !renew {
		return "", nil
	}
	taken, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	return hosttunnels.Pinned(string(taken)), nil
}
