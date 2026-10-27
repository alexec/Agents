package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/usersettings"
	"github.com/alexec/agents/Go/wire"
)

// The user scope (#1760, spec 736 US4): each person's settings and secrets, kept here and
// sent to each machine of theirs on its channel 0 when it joins and when they change. Only
// a person's own clients change them; a machine only receives them, so a machine taken over
// cannot put an MCP server (a command) on its person's other machines.

// CapHostUserSettings is what a machine says when it writes machine/userSettings into its
// ~/.agents and ~/.agents-secrets. A machine that does not say it is sent nothing: no
// secret goes where it would not be used.
const CapHostUserSettings = wire.CapHostUserSettings1

// userDeliveryTimeout bounds opening a person's secrets for one machine.
const userDeliveryTimeout = 30 * time.Second

// toldUsers is what each machine here was last sent, by a hash, so a change tells only the
// machines whose delivery differs.
type toldUsers struct {
	mu   sync.Mutex
	last map[string][sha256.Size]byte
}

func (m *Methods) userMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.callerPerson(from)
	book := m.s.users
	switch method {
	case "user/settings":
		return book.Settings(ctx, user)
	case "user/setAgentConfigFile":
		request, err := require[wire.AgentConfigFileRequest](params, "AgentConfigFileRequest")
		if err != nil {
			return nil, err
		}
		if from.Kind != "host" || !m.owns(from, from.Client) {
			return nil, fail(notPermitted, "Only one of your own machines can sync its agent configuration files.")
		}
		changed, err := book.SetAgentConfigFile(ctx, user, from.Client, request)
		if err != nil {
			return nil, userFailure(err)
		}
		if changed {
			m.s.userAgentConfigChanged(user, from.Client)
		}
		return wire.Empty{}, nil
	case "user/secretNames":
		rows, err := book.Names(ctx, user)
		if err != nil {
			return nil, err
		}
		return wire.UserSecretNames{Secrets: rows, Sealing: book.Sealing()}, nil
	case "user/setSettings":
		request, err := require[wire.UserSettingsPart](params, "UserSettingsPart")
		if err != nil {
			return nil, err
		}
		var fields map[string]json.RawMessage
		json.Unmarshal(params, &fields)
		changed, err := book.SetPart(ctx, user, request.Part, fields["value"])
		if err != nil {
			return nil, userFailure(err)
		}
		if changed {
			m.s.userChanged(user, []wire.UserSettingsPartName{request.Part}, false, from.Client)
		}
		return wire.Empty{}, nil
	case "user/setSecret":
		request, err := require[wire.UserSecret](params, "UserSecret")
		if err != nil {
			return nil, err
		}
		if err := book.SetSecret(ctx, user, string(request.Name), request.Value); err != nil {
			return nil, userFailure(err)
		}
		m.s.log("secret " + string(request.Name) + " set for " + user)
		m.s.userChanged(user, nil, true, from.Client)
		return wire.Empty{}, nil
	case "user/removeSecret":
		request, err := require[wire.UserSecretRequest](params, "UserSecretRequest")
		if err != nil {
			return nil, err
		}
		had, err := book.RemoveSecret(ctx, user, string(request.Name))
		if err != nil {
			return nil, userFailure(err)
		}
		if had {
			m.s.log("secret " + string(request.Name) + " removed for " + user)
			m.s.userChanged(user, nil, true, from.Client)
		}
		return wire.Empty{}, nil
	}
	return nil, fail(methodNotFound, "No method %s.", method)
}

// userAgentConfigChanged fans one file edit out to every machine and client of the person.
func (s *Service) userAgentConfigChanged(user, by string) {
	s.announce("userSettingsChanged", user, by)
	yes := true
	s.router.TellPerson(user, wire.NotifyControlUserSettingsChanged.Name, wire.UserSettingsChanged{AgentConfigFiles: &yes})
	for _, host := range s.router.HostsHeldHere() {
		if s.ownerOf(host) == user {
			go s.sendUserSettings(host, false)
		}
	}
}

// userFailure is a book's error as words for the client. None holds a secret's value.
func userFailure(err error) error {
	switch {
	case errors.Is(err, usersettings.ErrNoSealing):
		return fail(notSupported, "This control plane has no key to seal secrets with. Start it with a key file or AGENTS_CONTROL_KMS.")
	case errors.Is(err, usersettings.ErrInvalid):
		return fail(invalidParams, "%s", strings.TrimPrefix(err.Error(), usersettings.ErrInvalid.Error()+": "))
	}
	return err
}

// userChanged is a person's settings or secrets changed here: the other copies are told,
// then this copy's machines and clients of that person.
func (s *Service) userChanged(user string, parts []wire.UserSettingsPartName, secrets bool, by string) {
	s.announce("userSettingsChanged", user, by)
	s.userChangedHere(user, parts, secrets)
}

// userChangedHere is userChanged's effect on this copy: each machine of the person's whose
// uplink ends here gets what changed, and their clients read again.
func (s *Service) userChangedHere(user string, parts []wire.UserSettingsPartName, secrets bool) {
	changed := wire.UserSettingsChanged{Parts: parts}
	if secrets || parts == nil {
		yes := true
		changed.Secrets = &yes
	}
	s.router.TellPerson(user, wire.NotifyControlUserSettingsChanged.Name, changed)
	for _, host := range s.router.HostsHeldHere() {
		if s.ownerOf(host) == user {
			go s.sendUserSettings(host, false)
		}
	}
}

// takesUserSettings says a machine writes machine/userSettings.
func (s *Service) takesUserSettings(host string) bool {
	h := s.records.Host(host)
	return h != nil && slices.Contains(hostCapabilities(*h), CapHostUserSettings)
}

// sendUserSettings sends a machine its person's settings and secrets, on its channel 0
// and only there (FR-025). always sends even what it was sent last (a hello).
func (s *Service) sendUserSettings(host string, always bool) {
	if s.users == nil || !s.takesUserSettings(host) {
		return
	}
	user := s.ownerOf(host)
	ctx, cancel := context.WithTimeout(context.Background(), userDeliveryTimeout)
	defer cancel()
	delivery, skipped, err := s.users.Delivery(ctx, user)
	if err != nil {
		s.log("user settings for " + host + " could not be read: " + err.Error())
		return
	}
	if len(skipped) > 0 {
		s.log(fmt.Sprintf("user settings for %s: %d secrets do not open with this control plane's key and were not sent: %s",
			host, len(skipped), strings.Join(skipped, ", ")))
	}
	b, _ := json.Marshal(delivery)
	sum := sha256.Sum256(b)
	s.toldUsers.mu.Lock()
	if s.toldUsers.last == nil {
		s.toldUsers.last = map[string][sha256.Size]byte{}
	}
	same := s.toldUsers.last[host] == sum
	s.toldUsers.mu.Unlock()
	if same && !always {
		return
	}
	// The person may have changed while the secrets were opened: a machine that is no
	// longer theirs is sent nothing.
	if s.records.Host(host) == nil || s.ownerOf(host) != user || !s.router.Tell(host, wire.NotifyMachineUserSettings.Name, delivery) {
		s.toldUsers.mu.Lock()
		delete(s.toldUsers.last, host)
		s.toldUsers.mu.Unlock()
		return
	}
	s.toldUsers.mu.Lock()
	s.toldUsers.last[host] = sum
	s.toldUsers.mu.Unlock()
	names := make([]string, 0, len(delivery.Secrets))
	for _, secret := range delivery.Secrets {
		names = append(names, string(secret.Name))
	}
	if err := s.users.Sent(ctx, user, host, names); err != nil {
		s.log("which secrets " + host + " has could not be kept: " + err.Error())
	}
	s.log(fmt.Sprintf("user settings sent to %s (%d secrets)", host, len(names)))
}

// machineLeft is a machine removed (FR-026): it is sent nothing more, and its person is
// told which secrets were on it.
func (s *Service) machineLeft(host, user, name string) {
	s.toldUsers.mu.Lock()
	delete(s.toldUsers.last, host)
	s.toldUsers.mu.Unlock()
	if s.users == nil {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), userDeliveryTimeout)
	defer cancel()
	had, err := s.users.Left(ctx, user, host, name)
	if err != nil {
		s.log("the secrets on " + host + " could not be noted: " + err.Error())
	}
	if len(had) == 0 {
		return
	}
	names := make([]wire.UserSecretName, len(had))
	for i, n := range had {
		names[i] = wire.UserSecretName(n)
	}
	s.log(fmt.Sprintf("%s was removed with %d of %s's secrets on it", host, len(had), user))
	s.router.TellPerson(user, wire.NotifyControlSecretsLeft.Name, wire.SecretsLeft{Host: wire.MachineRef(host), Name: name, Secrets: names})
	s.announce("userSettingsChanged", user, host)
	s.router.TellPerson(user, wire.NotifyControlUserSettingsChanged.Name, wire.UserSettingsChanged{Secrets: optional(true)})
}

// openUserBook is the user scope over the store, with the keeper for secrets when one is
// given. A keeper that does not open stops the start: secrets kept with it would not open.
func openUserBook(cfg Config) (*usersettings.Book, error) {
	if cfg.SecretKeeper == "" {
		return usersettings.New(cfg.Store, nil, ""), nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), userDeliveryTimeout)
	defer cancel()
	k, err := kms.Keeper(ctx, cfg.SecretKeeper)
	if err != nil {
		return nil, fmt.Errorf("the keeper for secrets %s: %w", kms.Describe(cfg.SecretKeeper), err)
	}
	return usersettings.New(cfg.Store, k, cfg.SecretKeeper), nil
}
