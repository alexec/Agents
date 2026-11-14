package agentsd

import (
	"context"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// agents-secret NAME (#4178, step C of the spike #4168): a session's own commands read a
// secret that does not ask through agentsd, never from a file. A session gets, as for gh and
// git (#3926):
//
//   - `agents-secret` first on its PATH, which runs `agentsd secret NAME`;
//   - a grant in its environment (secretURLEnv, secretGrantEnv) that can ask this endpoint
//     and nothing else, made when the runtime starts and taken back when it ends.
//
// agentsd prints the value of a secret with Ask before use off, and records each read with
// the session and the name (secret.read, use command). A secret with Ask before use is
// refused: #4013's rule is that a flagged value never goes into a process of the user. A call
// with no grant (a terminal) asks a person through daemon.sock (secretterminal.go, #4179).

const (
	secretCommandPath = "/secrets/value"
	// secretURLEnv and secretGrantEnv tell `agentsd secret` where to ask.
	secretURLEnv   = "AGENTS_SECRET_URL"
	secretGrantEnv = "AGENTS_SECRET_GRANT"
	// secretCommandPlace is a command's read's place in the record.
	secretCommandPlace = "agents-secret"
)

// SecretCommand is `agentsd secret NAME`, run as `agents-secret NAME`: it writes the value to
// out, exactly, with no newline, so `$(agents-secret NAME)` and a pipe get the value alone.
// What went wrong goes to errOut, and the exit code is 1. With no session's grant it asks
// agentsd on socket, which asks a person.
func SecretCommand(args []string, getenv func(string) string, socket string, out, errOut io.Writer) int {
	if len(args) != 1 || args[0] == "" || strings.HasPrefix(args[0], "-") {
		fmt.Fprintln(errOut, "usage: agents-secret NAME\n"+
			"Prints the value of a secret with Ask before use off, for a session of Agent Loops; from a terminal, once a person allows it. agentsd records each read.")
		return 2
	}
	name := args[0]
	base, grant := getenv(secretURLEnv), getenv(secretGrantEnv)
	if base == "" || grant == "" {
		return terminalSecretCommand(socket, name, out, errOut)
	}
	u, err := url.Parse(base)
	if err != nil {
		fmt.Fprintln(errOut, "agents-secret:", err)
		return 1
	}
	u.RawQuery = url.Values{"name": {name}}.Encode()
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), nil)
	if err != nil {
		fmt.Fprintln(errOut, "agents-secret:", err)
		return 1
	}
	req.Header.Set("Authorization", "Bearer "+grant)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintln(errOut, "agents-secret: agentsd did not answer:", err)
		return 1
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		fmt.Fprintln(errOut, "agents-secret:", err)
		return 1
	}
	switch {
	case resp.StatusCode == http.StatusOK:
		_, _ = out.Write(b)
		return 0
	case len(b) > 0:
		fmt.Fprintln(errOut, "agents-secret: "+strings.TrimSpace(string(b)))
	case resp.StatusCode == http.StatusNotFound:
		fmt.Fprintln(errOut, "agents-secret: agentsd does not know this session's grant: the session's runtime has ended or started again. "+
			"A new start of the session gets a new one.")
	default:
		fmt.Fprintln(errOut, "agents-secret: agentsd said "+resp.Status)
	}
	return 1
}

// withSecretCommand is env for agent's runtime with agents-secret first on PATH and a grant
// that asks this host, or env as it was when agentsd cannot listen.
func (d *Daemon) withSecretCommand(env []string, agent wire.UUID) []string {
	self := d.credentialSelf
	if self == "" {
		var err error
		if self, err = os.Executable(); err != nil {
			return env
		}
	}
	port, err := d.startAppTools()
	if err != nil {
		log.Printf("agents-secret: could not listen: %v", err)
		return env
	}
	grant := string(store.NewUUID())
	d.credMu.Lock()
	dropGrants(d.commandGrants, agent)
	if d.commandGrants == nil {
		d.commandGrants = map[string]wire.UUID{}
	}
	d.commandGrants[grant] = agent
	d.credMu.Unlock()

	env = without(env, secretURLEnv, secretGrantEnv)
	env = append(env, secretURLEnv+"=http://127.0.0.1:"+strconv.Itoa(port)+secretCommandPath, secretGrantEnv+"="+grant)
	bin := filepath.Join(d.Store.Loc.Root, "runtimes", "secret")
	if err := writeSecretShim(bin, self); err != nil {
		log.Printf("agents-secret: could not write the command: %v", err)
		return env
	}
	return prependPath(env, bin)
}

// serveSecretValue answers `agentsd secret`: the value of the secret ?name= for the grant's
// session, as plain text, when it does not ask; else words that say why not.
func (d *Daemon) serveSecretValue(w http.ResponseWriter, r *http.Request) {
	grant := bearer(r.Header.Get("Authorization"))
	d.credMu.Lock()
	agent, ok := d.commandGrants[grant]
	d.credMu.Unlock()
	if grant == "" || !ok {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if r.Method != http.MethodPost {
		w.Header().Set("Allow", "POST")
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	name := strings.TrimSpace(r.URL.Query().Get("name"))
	value, status, words := d.secretForCommand(agent, name)
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if status == http.StatusOK {
		_, _ = io.WriteString(w, value)
		return
	}
	_, _ = io.WriteString(w, words)
}

// secretForCommand is name's value for agent's agents-secret, with the read recorded; or the
// status and the words that say why it is not given.
func (d *Daemon) secretForCommand(agent wire.UUID, name string) (value string, status int, words string) {
	if name == "" {
		return "", http.StatusBadRequest, "give the secret's name: agents-secret NAME"
	}
	if d.secretIsSealed(agent, name) {
		log.Printf("agents-secret: %s refused to %s: it has Ask before use", name, agent)
		return "", http.StatusForbidden, name + " has Ask before use, so agentsd never puts its value in a process. " +
			"Use it with fill_secret or set_ci_secret, which put it where it goes for you, " +
			"or as ${" + name + "} in the url or a header of an http server in .agents/mcp.json, which agentsd fills on each request. " +
			"Or a person turns Ask before use off for " + name + " in Settings ▸ Secrets."
	}
	v, ok, expired := d.localSecret(agent, name)
	if !ok {
		if expired {
			return "", http.StatusNotFound, name + " was kept for this session only, and it has expired. Ask for it again with ask_secret."
		}
		return "", http.StatusNotFound, name + " is not set on this machine. Call list_secrets for the names that are, or ask for it with ask_secret."
	}
	log.Printf("agents-secret: %s read by %s", name, agent)
	d.secretRead(agent, name, wire.SecretOperationUseCommand, secretCommandPlace)
	return v, http.StatusOK, ""
}

// writeSecretShim writes bin/agents-secret: `agentsd secret`, the agentsd that started the
// session.
func writeSecretShim(bin, agentsd string) error {
	if err := os.MkdirAll(bin, 0o700); err != nil {
		return err
	}
	script := "#!/bin/sh\n" +
		"# agents-secret NAME (#4178): Agent Loops writes this file. agentsd gives the value of a secret with Ask before use off, and records the read.\n" +
		"exec " + shellQuote(agentsd) + " secret \"$@\"\n"
	path := filepath.Join(bin, "agents-secret")
	if old, err := os.ReadFile(path); err == nil && string(old) == script {
		return nil
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, []byte(script), 0o700); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
