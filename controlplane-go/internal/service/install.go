package service

import (
	"bytes"
	"context"
	_ "embed"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Stage 6: a server joins from the Go control plane as from the Swift one. GET /v1/install.sh
// is the Swift HostInstallScript's text (`agents-control install-script`, byte for byte),
// and /v1/servers/<file> hands out the Linux hosts from AGENTS_CONTROL_SERVERS. hosts/install
// is the window's Add a Server ▸ Over ssh, simpler than HostInstall.swift: the host key is
// checked the same way (#610), then the server runs the install script itself, fetching
// the host from here, where Swift copies it over ssh. No tunnel through a bastion (#435).

//go:embed install.sh
var installScript []byte

var serverNames = func() map[string]bool {
	names := map[string]bool{"VERSION": true}
	for _, arch := range []string{"x86_64", "aarch64"} {
		for _, p := range []string{"agentsd", "ci-watcher"} {
			names[p+"-linux-"+arch] = true
			names[p+"-linux-"+arch+".sha256"] = true
		}
	}
	return names
}()

func serversFolder() string {
	f := os.Getenv("AGENTS_CONTROL_SERVERS")
	if f == "" {
		return ""
	}
	if _, err := os.Stat(filepath.Join(f, "VERSION")); err != nil {
		return ""
	}
	return f
}

func (s *Service) installRoutes(mux *http.ServeMux) {
	mux.HandleFunc("/v1/install.sh", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/x-shellscript")
		w.Write(installScript)
	})
	mux.HandleFunc("/v1/servers/", func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/v1/servers/")
		folder := serversFolder()
		if !serverNames[name] || folder == "" {
			http.Error(w, "this control plane has no such file", http.StatusNotFound)
			return
		}
		http.ServeFile(w, r, filepath.Join(folder, name))
	})
}

// installCommand is HostInstallScript.command: the one line a person runs on the server.
func installCommand(url, pin, code string) string {
	curl := "curl -fsSL"
	if pin != "" {
		std := strings.NewReplacer("-", "+", "_", "/").Replace(pin)
		for len(std)%4 != 0 {
			std += "="
		}
		curl += " --insecure --pinnedpubkey sha256//" + std
	}
	return fmt.Sprintf("%s %s/v1/install.sh | sh -s -- '%s'", curl, strings.TrimSuffix(url, "/"), code)
}

type installRequest struct {
	Destination string  `json:"destination"`
	Name        *string `json:"name"`
	Key         *string `json:"key"`
	Trust       *string `json:"trust"`
	Tunnel      *bool   `json:"tunnel"`
}

func sshExecutable() string {
	if s := os.Getenv("AGENTS_SSH"); s != "" {
		return s
	}
	return "/usr/bin/ssh"
}

// sshRun runs ssh with options and a remote command, in the person's environment less
// this process's own (no agent when a key was given).
func sshRun(ctx context.Context, keyGiven bool, args ...string) (string, string, int) {
	return sshRunIn(ctx, keyGiven, "", args...)
}

// sshRunIn is sshRun with stdin: a remote command that holds a secret goes in there, not
// on a command line that ps shows on this Mac.
func sshRunIn(ctx context.Context, keyGiven bool, stdin string, args ...string) (string, string, int) {
	cmd := exec.CommandContext(ctx, sshExecutable(), args...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var env []string
	for _, kv := range os.Environ() {
		if strings.HasPrefix(kv, "AGENTS_") || (keyGiven && strings.HasPrefix(kv, "SSH_AUTH_SOCK=")) {
			continue
		}
		env = append(env, kv)
	}
	cmd.Env = env
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	err := cmd.Run()
	code := 0
	if err != nil {
		code = 255
		if x, ok := err.(*exec.ExitError); ok {
			code = x.ExitCode()
		}
	}
	return out.String(), errb.String(), code
}

// sayProblem is HostInstall.say, for what ssh wrote on standard error.
func sayProblem(stderr string, keyGiven bool) string {
	switch {
	case strings.Contains(stderr, "Could not resolve hostname"):
		return "ssh doesn’t know that server."
	case strings.Contains(stderr, "REMOTE HOST IDENTIFICATION HAS CHANGED"):
		return "The server’s host key has changed since your known_hosts last saw it, so nothing was installed. If the server was rebuilt, remove its old key (ssh-keygen -R) and try again."
	case strings.Contains(stderr, "Host key verification failed"), strings.Contains(stderr, "No ED25519 host key is known"), strings.Contains(stderr, "host key is known"):
		return "The server’s host key isn’t in your known_hosts. Add it over ssh to see the key and trust it."
	case strings.Contains(stderr, "Permission denied") && !keyGiven:
		return "The server refused every key ssh offered. If yours has a passphrase, add it to the agent (ssh-add), or choose a key."
	case strings.Contains(stderr, "Permission denied"):
		return "The server refused that key."
	case strings.Contains(stderr, "timed out"), strings.Contains(stderr, "Connection refused"):
		return "It did not answer: the connection timed out or was refused."
	case strings.TrimSpace(stderr) == "":
		return "ssh failed without saying why."
	}
	return strings.TrimSpace(stderr)
}

func label(destination string) string {
	h := destination
	if i := strings.LastIndex(h, "@"); i >= 0 {
		h = h[i+1:]
	}
	h = strings.TrimPrefix(h, "ssh://")
	if i := strings.Index(h, ":"); i >= 0 {
		h = h[:i]
	}
	return h
}

// sshTarget turns user@host:port into ssh's own arguments: -p port user@host.
func sshTarget(destination string) []string {
	d := strings.TrimPrefix(destination, "ssh://")
	at := strings.LastIndex(d, "@")
	if c := strings.LastIndex(d, ":"); c > at && !strings.Contains(d[c+1:], "]") {
		return []string{"-p", d[c+1:], d[:c]}
	}
	return []string{d}
}

func (m *Methods) install(params json.RawMessage) (any, error) {
	s := m.s
	var req installRequest
	if json.Unmarshal(params, &req) != nil || strings.TrimSpace(req.Destination) == "" {
		return nil, fail(invalidParams, "Say which server.")
	}
	if req.Tunnel != nil && *req.Tunnel {
		return nil, fail(notAllowed, "This control plane can’t hold an ssh tunnel yet. Add the server without one.")
	}
	destination := strings.TrimSpace(req.Destination)
	name := label(destination)
	if req.Name != nil && strings.TrimSpace(*req.Name) != "" {
		name = strings.TrimSpace(*req.Name)
	}
	progress := func(step string) {
		s.router.BroadcastControl("control/installProgress", map[string]any{"name": name, "step": step})
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Minute)
	defer cancel()
	folder, err := os.MkdirTemp("", "agents-install-")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(folder)
	os.Chmod(folder, 0o700)
	keyGiven := req.Key != nil && strings.TrimSpace(*req.Key) != ""
	var opts []string
	if keyGiven {
		key := *req.Key
		if !strings.HasSuffix(key, "\n") {
			key += "\n"
		}
		file := filepath.Join(folder, "key")
		if err := os.WriteFile(file, []byte(key), 0o600); err != nil {
			return nil, fail(internalError, "The key could not be held for the install.")
		}
		opts = append(opts, "-i", file, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none")
	}
	if c := os.Getenv("AGENTS_SSH_CONFIG"); c != "" {
		opts = append([]string{"-F", c}, opts...)
	}
	base := append(opts, "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "LogLevel=error")
	target := sshTarget(destination)
	progress("connect")

	// The host key (#610): the person's known_hosts, or one shown and trusted by its fingerprint.
	knownOpts := []string{"-o", "StrictHostKeyChecking=yes"}
	fetchKey := func() (string, string, error) {
		file := filepath.Join(folder, "fetched_hosts")
		os.WriteFile(file, nil, 0o600)
		args := append(append([]string{}, opts...), "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "UserKnownHostsFile="+file,
			"-o", "GlobalKnownHostsFile=/dev/null", "-o", "StrictHostKeyChecking=accept-new", "-o", "PreferredAuthentications=none")
		_, stderr, _ := sshRun(ctx, keyGiven, append(args, append(target, "true")...)...)
		if b, _ := os.ReadFile(file); len(bytes.TrimSpace(b)) == 0 {
			return "", "", fail(notAllowed, "%s", sayProblem(stderr, keyGiven))
		}
		out, err := exec.Command("/usr/bin/ssh-keygen", "-lf", file, "-E", "sha256").Output()
		if err != nil {
			return "", "", fail(notAllowed, "The server’s key could not be read.")
		}
		for _, f := range strings.Fields(string(out)) {
			if strings.HasPrefix(f, "SHA256:") {
				return f, file, nil
			}
		}
		return "", "", fail(notAllowed, "The server’s key could not be read.")
	}
	if req.Trust != nil && *req.Trust != "" {
		fp, file, err := fetchKey()
		if err != nil {
			return nil, err
		}
		if fp != *req.Trust {
			return map[string]any{"needsTrust": fp, "name": name}, nil
		}
		knownOpts = append(knownOpts, "-o", "UserKnownHostsFile="+file, "-o", "GlobalKnownHostsFile=/dev/null")
	}
	progress("checkSystem")
	uname, stderr, code := sshRun(ctx, keyGiven, append(append(append([]string{}, base...), knownOpts...), append(target, "uname -sm")...)...)
	if code != 0 {
		if req.Trust == nil && strings.Contains(stderr, "Host key verification failed") {
			fp, _, err := fetchKey()
			if err != nil {
				return nil, err
			}
			return map[string]any{"needsTrust": fp, "name": name}, nil
		}
		return nil, fail(notAllowed, "%s", sayProblem(stderr, keyGiven))
	}
	platform := strings.TrimSpace(uname)
	fields := strings.Fields(platform)
	if len(fields) != 2 || fields[0] != "Linux" {
		return nil, fail(notAllowed, "%s is %s, which this control plane has no host for.", name, platform)
	}
	arch := map[string]string{"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}[fields[1]]
	folderOK := serversFolder()
	if _, err := os.Stat(filepath.Join(folderOK, "agentsd-linux-"+arch)); arch == "" || folderOK == "" || err != nil {
		return nil, fail(notAllowed, "%s is %s, which this control plane has no host for.", name, platform)
	}
	progress("setUp")
	shown, err := s.codes.Issue(ctx, true, false, lifetime)
	if err != nil {
		return nil, storeFailure(err)
	}
	// The line with the code goes to the server's shell on standard input, never on this
	// Mac's command line, where ps would show it.
	line := installCommand(s.cfg.URL, s.cfg.Pin, shown.Text) + " '" + strings.ReplaceAll(name, "'", "") + "'\n"
	out, stderr, code := sshRunIn(ctx, keyGiven, line, append(append(append([]string{}, base...), knownOpts...), append(target, "sh -s")...)...)
	if code != 0 {
		return nil, fail(notAllowed, "%s", sayProblem(stderr+out, keyGiven))
	}
	progress("started")
	return map[string]any{"started": true, "name": name, "platform": fields[0] + " " + fields[1], "tunnel": false}, nil
}

const notAllowed = -32060
