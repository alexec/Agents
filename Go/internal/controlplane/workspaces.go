package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// Machine providers (#691), as ControlService.takeUp wires them: on a single copy with
// a home for their secrets, beside the tunnels. They keep prompts and starts for a
// stopped workspace (US3), and an agent on this machine's own host writes a map for a new
// one (Write It for Me, #858).

// providerSecrets is where providers keep their secrets: in the store, sealed by the keeper
// for secrets, so a store copy, a handover or a backup carries them (#2138); or, with no
// keeper, in home.
func (s *Service) providerSecrets(home string) *providers.Secrets {
	if s.cfg.SecretKeeper == "" {
		return providers.NewSecrets(home)
	}
	ctx, cancel := context.WithTimeout(context.Background(), userDeliveryTimeout)
	defer cancel()
	k, err := kms.Keeper(ctx, s.cfg.SecretKeeper)
	if err != nil {
		s.log(fmt.Sprintf("providers: the keeper for secrets %s does not open (%v); their secrets stay in %s", kms.Describe(s.cfg.SecretKeeper), err, home))
		return providers.NewSecrets(home)
	}
	return providers.NewSealedSecrets(s.cfg.Store, k, s.cfg.SecretKeeper)
}

// makeProviders makes the providers, their kept requests and their drafts.
func (s *Service) makeProviders(home string) *providers.Providers {
	commandProvider := s.cfg.CommandProvider
	if commandProvider == "" {
		commandProvider = providers.CommandProvider()
	}
	timing := s.cfg.ProviderTiming
	if timing.ListEvery == 0 {
		timing = providers.StandardTiming
	}
	connect := func(record providers.ProviderRecord, secrets map[string]string) (providers.Provider, error) {
		return providers.NewConnection(record, secrets, home, timing.Calls, commandProvider, s.log)
	}
	adapter := providerRouter{s.router}
	p := providers.NewProviders(providers.Config{
		Store: s.cfg.Store, Records: s.records, Router: adapter, Methods: providerMethods{s.methods},
		Secrets: s.providerSecrets(home), Timing: timing, Log: s.log,
		Hooks: providers.Hooks{
			SSHStart: s.sshStart,
			OpenTunnel: func(string) {
				if s.tunnels != nil {
					s.tunnels.Reconcile(context.Background())
				}
			},
			Stopped: s.router.CloseStopped,
			InstalledOver: func(host string) string {
				if s.tunnels == nil {
					return ""
				}
				over, _, _ := s.tunnels.Installed(host)
				return over
			},
			Connect:   connect,
			OwnerOf:   s.ownerOf,
			IsAdmin:   s.isAdmin,
			InGroup:   s.inGroup,
			GroupName: s.groupName,
			Suspended: s.suspended,
			HostCommand: func(person string) (string, error) {
				shown, err := s.codes.Issue(withCodeOwner(context.Background(), person), true, false, 5*time.Minute)
				if err != nil {
					return "", err
				}
				if shown.Command == nil {
					return "", errors.New("This control plane gave no install command with its host code.")
				}
				return *shown.Command, nil
			},
			BackUp: s.backUpBeforeDelete,
		},
	})
	providers.NewDraftsFor(p, providers.DraftWiring{Router: adapter, Records: s.records, Home: home, Connect: connect,
		Log: s.log, MachineID: func() string {
			if settings := s.records.Settings(); settings != nil {
				return settings.MachineID
			}
			return s.cfg.MachineID
		}})
	kept := providers.NewKeptFor(p, s.log)
	s.router.SetKeeper(kept)
	return p
}

// backupPatience is how long a delete waits for the host's backup (#1815): hundreds of MB
// in 8 MiB parts.
var backupPatience = 30 * time.Minute

// backUpBeforeDelete asks the host for a backup, on a channel bound to the client that
// asked for the delete, and waits for it to be made (#1815). False when the host can't:
// it is not here, or older than backups.
func (s *Service) backUpBeforeDelete(host string, caller providers.Caller) (bool, error) {
	record := s.records.Host(host)
	if record == nil || !wire.Has(hostCapabilities(*record), wire.CapBackups1) {
		return false, nil
	}
	m := s.router.DeliverKept(wire.CallBackupsMake.Name, wire.BackupMakeRequest{Wait: new(true)}, caller.Client, caller.Kind, host, backupPatience)
	if m == nil {
		return false, errors.New("the host went, or did not finish the backup in time")
	}
	if len(m.Error) > 0 {
		var refusal providers.Failure
		json.Unmarshal(m.Error, &refusal)
		return false, &refusal
	}
	return true, nil
}

// providerRouter is the router as the providers see it (their Router).
type providerRouter struct{ r *Router }

func (a providerRouter) Online(host string) bool {
	state, ok := a.r.State(host)
	return ok && state.online()
}

func (a providerRouter) HostState(host string) string {
	state, _ := a.r.Described(host)["state"].(string)
	return state
}

func (a providerRouter) SetWorkspace(host string, ws *providers.MachineWorkspace) {
	a.r.SetWorkspace(host, ws)
}

func (a providerRouter) BroadcastControl(method string, params any) {
	a.r.BroadcastControl(method, params)
}

func (a providerRouter) BroadcastControlEach(method string, params func(person string) any) {
	a.r.BroadcastControlEach(method, params)
}

func (a providerRouter) DeliverKept(method string, params json.RawMessage, client, kind, host string, patience time.Duration) *providers.Reply {
	m := a.r.DeliverKept(method, params, client, kind, host, patience)
	if m == nil {
		return nil
	}
	reply := &providers.Reply{Result: m.Result}
	if len(m.Error) > 0 {
		var refusal providers.Failure
		json.Unmarshal(m.Error, &refusal)
		reply.Error = &refusal
	}
	return reply
}

func (a providerRouter) TellControl(session, method string, params any) bool {
	return a.r.TellControl(session, method, params)
}

func (a providerRouter) HasSession(session string) bool { return a.r.HasSession(session) }

func (a providerRouter) Holds(host string) bool { return a.r.Holds(host) }

// providerMethods is the methods as the providers see them (their Methods).
type providerMethods struct{ m *Methods }

func (a providerMethods) HostRow(h records.MachineRecord) any { return a.m.hostRow(h) }

func (a providerMethods) RemoveHost(host string, from providers.Caller) error {
	_, err := a.m.Handle("hosts/remove", rawOf(map[string]string{"host": host}),
		Caller{Session: from.Session, Client: from.Client, Kind: from.Kind, Person: from.Person})
	return err
}

func rawOf(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return b
}

// providersCaller is a client as the providers see it.
func providersCaller(c Caller) providers.Caller {
	return providers.Caller{Session: c.Session, Client: c.Client, Kind: c.Kind, Person: c.Person}
}

// sshStart is the providers' SSHStart hook: a host's agentsd started over ssh. The key
// trusted at the install, whatever address the host has now (#1691); else the person's own
// known_hosts (#965). With renewKey, the key it is offered is taken and pinned again for
// its tunnel (#1701).
func (s *Service) sshStart(host records.MachineRecord, destination string, renewKey bool) error {
	known := ""
	if s.tunnels != nil {
		if _, keys, ok := s.tunnels.Installed(host.ID); ok {
			known = keys
		} else {
			// No tunnel to pin a new key for: it is checked as before.
			renewKey = false
		}
	} else {
		renewKey = false
	}
	// A provider may give alex@127.0.0.1 -p 2222: ssh takes it as one word (#857).
	taken, err := s.installer.StartDaemon(context.Background(), providers.SSHDestination(destination), known, host.Name, renewKey)
	if err != nil || !renewKey {
		return err
	}
	if taken != known {
		s.log("workspace: ssh start " + host.Name + ": its host key is new, as its workspace's is at each start; kept")
	}
	_, err = s.tunnels.Repin(context.Background(), host.ID, taken)
	return err
}
