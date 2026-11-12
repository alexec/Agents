package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/codespacessh"
	"github.com/alexec/agents/Go/internal/controlplane/hostinstall"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/workspacecommands"
	"github.com/alexec/agents/Go/wire"
)

// carriedProviders are the machine providers this machine carries (#3398): the control
// plane keeps each one's record, never a secret, and asks this machine on channel 0 to call
// it. Its server runs here, with the secrets kept here in
// ~/.agents-secrets/provider-secrets.json (0600).
type carriedProviders struct {
	mu    sync.Mutex
	held  map[string]*carriedConnection
	store *providers.Secrets
	home  string
	// The codespaces this machine keeps awake while their machines work (#4637).
	awake awake
}

// carriedConnection is a provider's server, as the record it was made from says.
type carriedConnection struct {
	record     []byte
	connection *providers.Connection
}

// carriedCallTimeout bounds one call: a start or stop has the contract's long timeout,
// and a little more for its server to start.
var carriedCallTimeout = providers.StandardCalls.Long + time.Minute

func (d *Daemon) carried() *carriedProviders {
	d.carriedOnce.Do(func() {
		home := d.personalHome()
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		d.carriedHeld = &carriedProviders{held: map[string]*carriedConnection{}, home: home,
			store: providers.NewSecrets(filepath.Join(home, ".agents-secrets"))}
	})
	return d.carriedHeld
}

// carriedMethods are the asks askedProvider answers on channel 0, which no client can send:
// said in machine/hello as providers.carry/1, so the control plane asks only a host that has them.
var carriedMethods = []string{wire.CallProvidersCarry.Name, wire.CallProvidersForget.Name,
	wire.CallProvidersKeepSecrets.Name, wire.CallProvidersSSH.Name}

// askedProvider answers a providers/* ask; false for any other method.
func (d *Daemon) askedProvider(method string, params json.RawMessage) (any, bool) {
	c := d.carried()
	switch method {
	case wire.CallProvidersCarry.Name:
		var request wire.ProviderCarry
		if err := json.Unmarshal(params, &request); err != nil {
			return carriedError("The control plane's request was not understood."), true
		}
		return c.carry(request), true
	case wire.CallProvidersKeepSecrets.Name:
		var request wire.ProviderSecretsKeep
		if err := json.Unmarshal(params, &request); err != nil {
			return carriedError("The control plane's request was not understood."), true
		}
		return c.keep(request), true
	case wire.CallProvidersForget.Name:
		var request wire.ProviderForget
		if err := json.Unmarshal(params, &request); err != nil {
			return carriedError("The control plane's request was not understood."), true
		}
		return c.forget(string(request.Provider)), true
	case wire.CallProvidersSSH.Name:
		var request wire.ProviderSSH
		if err := json.Unmarshal(params, &request); err != nil {
			return carriedError("The control plane's request was not understood."), true
		}
		return c.ssh(request, d.installProgress), true
	}
	return nil, false
}

func carriedError(words string) wire.ProviderCarried { return wire.ProviderCarried{Error: &words} }

func carriedResult(v any, err error) wire.ProviderCarried {
	if err != nil {
		return carriedError(err.Error())
	}
	raw, err := json.Marshal(v)
	if err != nil {
		return carriedError("Its answer could not be written.")
	}
	return wire.ProviderCarried{Result: raw}
}

// carry is providers/carry: the call, on the provider's server here. What it answers goes
// back with every secret's value taken out, as a draft's steps are, so none reaches the
// control plane from here.
func (c *carriedProviders) carry(request wire.ProviderCarry) wire.ProviderCarried {
	values := c.store.Values(string(request.Provider))
	for k, v := range request.Secrets {
		if v != "" {
			values[k] = v
		}
	}
	return redacted(providers.NewRedaction(values), c.call(request))
}

// redacted is out with each secret's value said as ${NAME}.
func redacted(r providers.Redaction, out wire.ProviderCarried) wire.ProviderCarried {
	if out.Error != nil {
		words := r.Text(*out.Error)
		out.Error = &words
	}
	if len(out.Result) > 0 {
		text := r.Text(string(out.Result))
		if !json.Valid([]byte(text)) {
			return carriedError("Its answer held a secret, so it was not sent.")
		}
		out.Result = json.RawMessage(text)
	}
	return out
}

func (c *carriedProviders) call(request wire.ProviderCarry) wire.ProviderCarried {
	var record providers.ProviderRecord
	if err := json.Unmarshal(request.Record, &record); err != nil || record.ID != string(request.Provider) {
		return carriedError("The control plane sent no provider record this machine can read.")
	}
	connection, draft, err := c.connection(record, request.Record, request.Secrets)
	if err != nil {
		return carriedError(err.Error())
	}
	if draft {
		// A draft's secrets are not kept, and nor is its server.
		defer connection.End()
	}
	workspace := ""
	if request.Workspace != nil {
		workspace = *request.Workspace
	}
	log.Printf("providers: %s %s", request.Call, record.ID)
	switch request.Call {
	case "check":
		return carriedResult(connection.Check())
	case "list":
		return carriedResult(connection.List())
	case "start":
		return carriedResult(connection.Start(workspace))
	case "stop":
		return carriedResult(connection.Stop(workspace))
	case "options":
		return carriedResult(connection.Options())
	case "create":
		name := ""
		if request.Name != nil {
			name = *request.Name
		}
		var options any
		if len(request.Options) > 0 {
			json.Unmarshal(request.Options, &options)
		}
		made, runs, err := connection.Create(name, options, request.FirstBoot)
		return carriedResult(providers.CarriedCreate{Made: made, Runs: runs}, err)
	case "delete":
		err := connection.Delete(workspace)
		if err == nil {
			forgetCodespaceSSH(workspace)
		}
		return carriedResult(nil, err)
	case "tools":
		return carriedResult(connection.Tools())
	}
	return carriedError("No provider call is called " + request.Call + ".")
}

// connection is the provider's server as record says, made again when the record
// changed. With a draft's secrets, a new one that is not kept: true.
func (c *carriedProviders) connection(record providers.ProviderRecord, raw []byte, draft map[string]string) (*providers.Connection, bool, error) {
	folder := filepath.Join(c.home, ".agents", "providers")
	os.MkdirAll(folder, 0o700)
	logf := func(s string) { log.Print(s) }
	if len(draft) > 0 {
		values := c.store.Values(record.ID)
		for k, v := range draft {
			if v != "" {
				values[k] = v
			}
		}
		made, err := providers.NewConnection(record, values, folder, providers.StandardCalls, providers.CommandProvider(), logf)
		return made, true, err
	}
	c.mu.Lock()
	held := c.held[record.ID]
	if held != nil && bytes.Equal(held.record, raw) {
		c.mu.Unlock()
		return held.connection, false, nil
	}
	delete(c.held, record.ID)
	c.mu.Unlock()
	if held != nil {
		held.connection.End()
	}
	made, err := providers.NewConnection(record, c.store.Values(record.ID), folder, providers.StandardCalls,
		providers.CommandProvider(), logf)
	if err != nil {
		return nil, false, err
	}
	c.mu.Lock()
	if other := c.held[record.ID]; other != nil {
		// Another call made one first: that one is used.
		c.mu.Unlock()
		made.End()
		return other.connection, false, nil
	}
	c.held[record.ID] = &carriedConnection{record: append([]byte(nil), raw...), connection: made}
	c.mu.Unlock()
	return made, false, nil
}

// end ends a provider's server here, so the next call starts it with what is kept now.
func (c *carriedProviders) end(provider string) {
	c.mu.Lock()
	held := c.held[provider]
	delete(c.held, provider)
	c.mu.Unlock()
	if held != nil {
		held.connection.End()
	}
}

// keep is providers/keepSecrets. Never logged.
func (c *carriedProviders) keep(request wire.ProviderSecretsKeep) wire.ProviderCarried {
	if err := c.store.Set(string(request.Provider), request.Secrets); err != nil {
		return carriedError("This machine could not keep the provider's secrets.")
	}
	c.end(string(request.Provider))
	log.Printf("providers: kept secrets for %s", request.Provider)
	return wire.ProviderCarried{}
}

// forget is providers/forget.
func (c *carriedProviders) forget(provider string) wire.ProviderCarried {
	c.end(provider)
	c.awake.forget(provider)
	if err := c.store.Remove(provider); err != nil {
		return carriedError("This machine could not delete the provider's secrets.")
	}
	log.Printf("providers: forgot %s", provider)
	return wire.ProviderCarried{}
}

// installProgress says a step of an install this machine runs to the control plane
// (machine/installProgress, #3497), which says it to the person's clients.
func (d *Daemon) installProgress(name, step string) {
	if tell := d.tellControl.Load(); tell != nil {
		(*tell)(wire.NotifyMachineInstallProgress.Name, wire.ControlInstallProgress{Name: name, Step: step})
	}
}

// ssh is providers/ssh: a codespace reached through gh with the provider's token, which
// stays here (#3347). progress says an install's steps.
func (c *carriedProviders) ssh(request wire.ProviderSSH, progress func(name, step string)) wire.ProviderCarried {
	token := c.store.Values(string(request.Provider))[workspacecommands.GitHubSecret]
	codespace := deref(request.Codespace)
	if request.Op == "letSleep" && codespace != "" {
		// Its token can have gone, with the provider: the session ends all the same.
		c.awake.letSleep(codespace)
		return wire.ProviderCarried{}
	}
	if token == "" || codespace == "" {
		return carriedError("This machine has no GitHub token for that codespace.")
	}
	if request.Op == "keepAwake" {
		// Held here, after this answer, until a letSleep or its lease ends (#4637).
		c.awake.keepAwake(string(request.Provider), codespace, token)
		return wire.ProviderCarried{}
	}
	installer := &hostinstall.Installer{
		Log:      func(format string, args ...any) { log.Printf(format, args...) },
		Progress: progress,
		Prepare: func(ctx context.Context, destination string) ([]string, error) {
			if err := codespacessh.Prepare(ctx, sshConfigPath(), codespace, destination, token, os.Environ()); err != nil {
				return nil, err
			}
			return []string{codespacessh.Token(token)}, nil
		}}
	ctx, cancel := context.WithTimeout(context.Background(), carriedCallTimeout)
	defer cancel()
	switch request.Op {
	case "start":
		taken, err := installer.StartDaemon(ctx, providers.SSHDestination(request.Destination), deref(request.KnownHosts),
			deref(request.Name), request.Renew != nil && *request.Renew)
		return carriedResult(wire.ProviderSSHResult{KnownHosts: optionalString(taken)}, err)
	case "hostKey":
		known, trust, err := installer.HostKey(ctx, request.Destination, deref(request.Trust))
		return carriedResult(wire.ProviderSSHResult{KnownHosts: optionalString(known), NeedsTrust: optionalString(trust)}, err)
	case "install":
		// Add as Machine… (#3497): the key the person's known_hosts trusts, or the one they
		// were shown and trust, and then the control plane's install.sh with its host code.
		name := deref(request.Name)
		progress(name, "connect")
		known, trust, err := installer.HostKey(ctx, request.Destination, deref(request.Trust))
		if err != nil || trust != "" {
			return carriedResult(wire.ProviderSSHResult{NeedsTrust: optionalString(trust)}, err)
		}
		progress(name, "checkSystem")
		err = installer.InstallWithCode(ctx, providers.SSHDestination(request.Destination), known, deref(request.HostCode), name)
		// What the install said goes back with the token's value taken out.
		return redacted(providers.NewRedaction(map[string]string{workspacecommands.GitHubSecret: token}),
			carriedResult(wire.ProviderSSHResult{KnownHosts: optionalString(known)}, err))
	}
	return carriedError("No ssh call is called " + request.Op + ".")
}

// forgetCodespaceSSH takes a deleted workspace's block out of the ssh config here, the one
// providers/ssh put there for a codespace (#3746). Another workspace has none.
func forgetCodespaceSSH(workspace string) {
	if workspace == "" {
		return
	}
	removed, err := codespacessh.Remove(sshConfigPath(), workspace)
	switch {
	case err != nil:
		log.Printf("providers: %s's ssh block: %v", workspace, err)
	case removed:
		log.Printf("providers: removed %s's ssh block", workspace)
	}
}

// sshConfigPath is the ssh config ssh reads here: AGENTS_SSH_CONFIG, else ~/.ssh/config.
func sshConfigPath() string {
	if file := os.Getenv("AGENTS_SSH_CONFIG"); file != "" {
		return file
	}
	home, err := os.UserHomeDir()
	if err != nil {
		home = "/"
	}
	return filepath.Join(home, ".ssh", "config")
}
