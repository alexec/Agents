package controlplane

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// People (#994, spec 736 T1): every client belongs to a person, and every machine to one
// user. A person reaches only their own machines; another's is not found (FR-018). The
// first person is the local owner and an admin; with one person, nothing changes.

// inviteLifetime is how long an invite code works (FR-007).
const inviteLifetime = 7 * 24 * time.Hour

// codeOwnerKey carries, through a context, the person a code is made for.
type codeOwnerKey struct{}

// withCodeOwner says whose a client or machine that uses the code made under ctx is.
func withCodeOwner(ctx context.Context, person string) context.Context {
	if person == "" {
		return ctx
	}
	return context.WithValue(ctx, codeOwnerKey{}, person)
}

func codeOwnerOf(ctx context.Context) *string {
	if person, ok := ctx.Value(codeOwnerKey{}).(string); ok && person != "" {
		return &person
	}
	return nil
}

// localOwner is the first person: control.json's owner, or "local" before it has one.
func (s *Service) localOwner() string {
	if settings := s.records.Settings(); settings != nil && settings.Owner != nil && *settings.Owner != "" {
		return *settings.Owner
	}
	return "local"
}

// PersonOf is the person a client belongs to: its owner, else the local owner.
func (s *Service) PersonOf(client string) string {
	if c := s.records.Client(client); c != nil && c.Owner != nil && *c.Owner != "" {
		return *c.Owner
	}
	return s.localOwner()
}

// OwnerOf is the user a machine belongs to: its owner, else the local owner.
func (s *Service) OwnerOf(host string) string { return s.ownerOf(host) }

func (s *Service) ownerOf(host string) string {
	if h := s.records.Host(host); h != nil && h.Owner != nil && *h.Owner != "" {
		return *h.Owner
	}
	return s.localOwner()
}

// isAdmin says whether a person is an admin. The local owner with no record yet is.
func (s *Service) isAdmin(user string) bool {
	p := s.records.Person(user)
	if p == nil {
		return user == s.localOwner()
	}
	return !p.IsRemoved() && p.IsAdmin()
}

// personName is what a person is called, for the screen.
func (s *Service) personName(user string) string {
	if p := s.records.Person(user); p != nil && p.Name != "" {
		return p.Name
	}
	return ""
}

// owns says a caller owns a machine that is there.
func (m *Methods) owns(from Caller, host string) bool {
	return m.records.Host(host) != nil && m.s.ownerOf(host) == m.callerPerson(from)
}

// callerPerson is the caller's person: as the router knew it, or from the records.
func (m *Methods) callerPerson(from Caller) string {
	if from.Person != "" {
		return from.Person
	}
	return m.s.PersonOf(from.Client)
}

// namedHosts are the machines a call names, by the fields that name one: each must be
// the caller's, or the call is refused as if there were no such machine (FR-018).
var hostFields = []string{"host", "from"}

func (m *Methods) refuseOthersHosts(params json.RawMessage, from Caller) error {
	var fields map[string]json.RawMessage
	if json.Unmarshal(params, &fields) != nil {
		return nil
	}
	for _, field := range hostFields {
		var host string
		if raw, ok := fields[field]; !ok || json.Unmarshal(raw, &host) != nil || host == "" {
			continue
		}
		if m.records.Host(host) != nil && !m.owns(from, host) {
			return fail(noSuchHost, "No machine is called %s.", host)
		}
	}
	return nil
}

// me is control/status's person: who the caller belongs to.
func (m *Methods) me(from Caller) *wire.ControlPerson {
	user := m.callerPerson(from)
	me := &wire.ControlPerson{ID: user, Name: m.s.personName(user), Role: wire.UserRoleMember}
	if m.s.isAdmin(user) {
		me.Role = wire.UserRoleAdmin
	}
	if user == m.s.localOwner() {
		yes := true
		me.LocalOwner = &yes
		if me.Name == "" || (m.records.Settings() != nil && me.Name == m.records.Settings().Name) {
			me.Name = localOwnerName
		}
	}
	return me
}

// localOwnerName is the local owner as the screen says them, until they give a name.
const localOwnerName = "Local owner"

// peopleMethod answers people/list, people/invite, people/setRole and people/remove.
func (m *Methods) peopleMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	user := m.callerPerson(from)
	admin := m.s.isAdmin(user)
	switch method {
	case "people/list":
		return m.peopleList(user, admin), nil
	case "people/removeRequests":
		if !admin {
			return nil, fail(notPermitted, "Only an admin sees the requests.")
		}
		return m.s.removeRequests(ctx)
	case "people/invite":
		if !admin {
			return nil, fail(notPermitted, "Only an admin can invite a person.")
		}
		request, err := require[wire.PersonInvite](params, "PersonInvite")
		if err != nil {
			return nil, err
		}
		name := strings.TrimSpace(request.Name)
		if name == "" || len([]rune(name)) > 80 {
			return nil, fail(invalidParams, "Give the person a name of 1 to 80 characters.")
		}
		if request.Role != wire.UserRoleAdmin && request.Role != wire.UserRoleMember {
			return nil, fail(invalidParams, "A role is admin or member.")
		}
		shown, err := m.s.codes.Invite(ctx, invite{Name: name, Role: string(request.Role), By: user}, inviteLifetime)
		if err != nil {
			return nil, err
		}
		return wire.PersonInvited{Text: shown.Text, Expires: shown.Expires, Name: name, Role: request.Role}, nil
	case "people/setRole":
		if !admin {
			return nil, fail(notPermitted, "Only an admin can change a role.")
		}
		request, err := require[wire.PersonRoleRequest](params, "PersonRoleRequest")
		if err != nil {
			return nil, err
		}
		if request.Role != wire.UserRoleAdmin && request.Role != wire.UserRoleMember {
			return nil, fail(invalidParams, "A role is admin or member.")
		}
		err = m.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
			p, ok := all[request.User]
			if !ok || p.IsRemoved() {
				return nil, fail(invalidParams, "There is no such person.")
			}
			if p.RoleOrAdmin() == string(request.Role) {
				return nil, nil
			}
			// A role a SCIM group gives is the provider's to change (FR-020).
			if len(p.RoleFrom) > 0 {
				return nil, fail(managedByProvider, "%s's role is set by their organisation's groups. Change it there.", p.Name)
			}
			if request.Role == wire.UserRoleMember && admins(all) <= 1 {
				return nil, fail(notPermitted, "%s is the only admin. Make another person an admin first.", p.Name)
			}
			p.Role = string(request.Role)
			return []records.Person{p}, nil
		})
		if err != nil {
			return nil, err
		}
		m.s.peopleChanged(request.User, false)
		return map[string]any{}, nil
	case "people/forViews":
		return m.peopleForViews(user), nil
	case "people/setForgeLogins":
		request, err := require[wire.ForgeLogins](params, "ForgeLogins")
		if err != nil {
			return nil, err
		}
		err = m.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
			p, ok := all[user]
			if !ok || p.IsRemoved() {
				// The local owner's own record may not exist yet (#994's migration).
				p = records.Person{ID: user, Kind: records.KindPerson, Role: records.RoleAdmin}
			}
			if request.Github != nil {
				p.GitHubLogin = *request.Github
			}
			if request.Gitlab != nil {
				p.GitLabLogin = *request.Gitlab
			}
			if request.Linear != nil {
				p.LinearLogin = *request.Linear
			}
			return []records.Person{p}, nil
		})
		if err != nil {
			return nil, err
		}
		m.s.peopleChanged(user, false)
		return map[string]any{}, nil
	case "people/remove", "people/removePreview":
		if !admin {
			return nil, fail(notPermitted, "Only an admin can remove a person.")
		}
		request, err := require[wire.PersonRequest](params, "PersonRequest")
		if err != nil {
			return nil, err
		}
		if request.User == user {
			return nil, fail(notPermitted, "You can't remove yourself. Another admin can.")
		}
		if request.User == m.s.localOwner() {
			return nil, fail(notPermitted, "The local owner holds the control plane's key, and stays.")
		}
		if method == "people/removePreview" {
			if p := m.records.Person(request.User); p == nil || p.IsRemoved() {
				return nil, fail(invalidParams, "There is no such person.")
			}
			return m.removePreview(request.User, from), nil
		}
		return map[string]any{}, m.removePerson(ctx, request.User, from)
	}
	return nil, notFound(method)
}

func admins(all map[string]records.Person) int {
	n := 0
	for _, p := range all {
		if !p.IsRemoved() && p.Kind != records.KindBot && p.IsAdmin() {
			n++
		}
	}
	return n
}

// peopleList is every user for an admin, and only themselves for a member. Machines say
// their name and state, and nothing inside them (FR-019).
func (m *Methods) peopleList(user string, admin bool) wire.PeopleList {
	clients := map[string][]wire.PersonClient{}
	for _, c := range m.records.Clients() {
		person := m.s.PersonOf(c.ID)
		clients[person] = append(clients[person], wire.PersonClient{ID: wire.UUID(c.ID), Name: c.Name, Kind: wire.ClientKind(c.Kind)})
	}
	machines := map[string][]wire.PersonMachine{}
	for _, h := range m.records.Hosts() {
		owner := m.s.ownerOf(h.ID)
		state, _ := m.router.Described(h.ID)["state"].(string)
		machines[owner] = append(machines[owner], wire.PersonMachine{ID: wire.MachineRef(h.ID), Name: h.Name, State: state,
			Platform: optional(h.Platform)})
	}
	people := m.records.People()
	if len(people) == 0 {
		// Before the migration has written the local owner.
		people = []records.Person{{ID: m.s.localOwner(), Kind: records.KindPerson, Role: records.RoleAdmin}}
	}
	out := wire.PeopleList{People: []wire.PersonRow{}, Admin: admin}
	for _, p := range people {
		if !admin && p.ID != user {
			continue
		}
		row := wire.PersonRow{ID: p.ID, Name: p.Name, Kind: kindOf(p), Role: wire.UserRole(p.RoleOrAdmin()),
			SignIns: []wire.SignIn{}, Clients: clients[p.ID], Machines: machines[p.ID]}
		// A bot's group, caps and spend today (#1761).
		if p.IsBot() {
			row.Role = wire.UserRoleMember
			row.Group = optional(p.Group)
			row.Caps = capsOnWire(p.Caps)
			row.SpentTodayUSD = new(m.s.spentToday(context.Background(), p.ID, time.Now()))
		}
		if row.Clients == nil {
			row.Clients = []wire.PersonClient{}
		}
		if row.Machines == nil {
			row.Machines = []wire.PersonMachine{}
		}
		// What their org provider says of them (#1002, FR-028).
		if p.SCIM != nil && !p.SCIM.Deleted {
			row.Scim = &wire.PersonSCIM{Provider: p.SCIM.Provider, ExternalId: optional(p.SCIM.ExternalID), UserName: p.SCIM.UserName,
				Name: p.SCIM.Name, DisplayName: optional(p.SCIM.DisplayName), Emails: p.SCIM.Emails, Active: p.SCIM.Active}
		}
		if p.Provisioned {
			row.Provisioned = new(true)
		}
		if p.Suspended != nil {
			row.Suspended = &wire.PersonSuspended{By: p.Suspended.By, Provider: p.Suspended.Provider, At: wire.DateOf(p.Suspended.At.Time),
				Why: optional(p.Suspended.Why)}
		}
		if len(p.RoleFrom) > 0 {
			row.RoleFrom = p.RoleFrom
		}
		for _, sign := range p.SignIns {
			in := wire.SignIn{Provider: sign.Provider, Email: optional(sign.Email), Login: optional(sign.Login)}
			if sign.Added != nil {
				in.Added = new(dateOf(sign.Added.Time))
			}
			// An outside account, so its person can take it off (#995); never a code's, which
			// is part of the code's secret.
			if outsideProvider(sign.Provider) {
				in.Account = optional(sign.Account)
			}
			row.SignIns = append(row.SignIns, in)
		}
		yes := true
		if p.ID == m.s.localOwner() {
			row.LocalOwner = &yes
			if row.Name == "" || (m.records.Settings() != nil && row.Name == m.records.Settings().Name) {
				row.Name = localOwnerName
			}
		}
		if p.ID == user {
			row.You = &yes
		}
		out.People = append(out.People, row)
	}
	return out
}

// peopleForViews is people/forViews (#2951): every person and bot on this control plane,
// open to a member as much as an admin, for the github, gitlab and linear servers' Team
// section and "An agent is on it". Narrower than peopleList: no role, clients or machines.
func (m *Methods) peopleForViews(user string) wire.PeopleForViews {
	people := m.records.People()
	if len(people) == 0 {
		people = []records.Person{{ID: m.s.localOwner(), Kind: records.KindPerson, Role: records.RoleAdmin}}
	}
	out := wire.PeopleForViews{People: []wire.TeamPerson{}}
	for _, p := range people {
		row := wire.TeamPerson{ID: p.ID, Name: p.Name, Kind: kindOf(p),
			GithubLogin: optional(p.GitHubLogin), GitlabLogin: optional(p.GitLabLogin), LinearLogin: optional(p.LinearLogin)}
		if p.ID == m.s.localOwner() && (row.Name == "" || (m.records.Settings() != nil && row.Name == m.records.Settings().Name)) {
			row.Name = localOwnerName
		}
		if p.ID == user {
			yes := true
			row.You = &yes
		}
		out.People = append(out.People, row)
	}
	return out
}

func kindOf(p records.Person) string {
	if p.Kind == "" {
		return records.KindPerson
	}
	return p.Kind
}

// removePerson is people/remove (FR-029): the person's clients are forgotten (their
// sockets close with 4403), their machines leave the control plane, and their record is
// kept removed, so the code they paired with does nothing again.
func (m *Methods) removePerson(ctx context.Context, user string, from Caller) error {
	err := m.records.ChangePeople(ctx, func(all map[string]records.Person) ([]records.Person, error) {
		p, ok := all[user]
		if !ok || p.IsRemoved() {
			return nil, fail(invalidParams, "There is no such person.")
		}
		if p.IsAdmin() && admins(all) <= 1 {
			return nil, fail(notPermitted, "%s is the only admin.", p.Name)
		}
		yes, now := true, records.Now()
		p.Removed, p.RemovedAt = &yes, &now
		return []records.Person{p}, nil
	})
	if err != nil {
		return err
	}
	for _, c := range m.records.Clients() {
		if m.s.PersonOf(c.ID) == user {
			if err := m.forget(ctx, c.ID, 0); err != nil {
				return err
			}
			m.s.announce("clientForgotten", c.ID, from.Client)
		}
	}
	for _, h := range m.records.Hosts() {
		if m.s.ownerOf(h.ID) != user {
			continue
		}
		// A started machine is stopped and deleted through its provider (FR-029), after it
		// has left the control plane: that may take minutes, and the removal may not wait.
		link := providers.LinkOf(&h)
		if _, err := m.removeHost(ctx, h.ID, from); err != nil {
			return err
		}
		if link != nil && m.s.providers != nil {
			name, provided := h.Name, m.s.providers
			safe.Go("delete a removed person's machine", func() { provided.DeleteForRemoval(*link, name, user) })
		}
	}
	m.s.joins.dropFor(ctx, user)
	m.s.links.dropFor(ctx, user)
	// A Remove request answered, and the refresh tokens kept for them (#1002).
	_ = m.s.cfg.Store.Delete(ctx, removeRequestKey(user))
	m.s.signIns.dropRefreshes(ctx, user)
	// Their user settings, sealed secrets and saved report views (#2293).
	if m.s.users != nil {
		if err := m.s.users.Forget(ctx, user); err != nil {
			m.s.log("person " + user + ": their settings could not be deleted: " + err.Error())
		}
	}
	_ = m.s.cfg.Store.Delete(ctx, reportViewsKey(user))
	m.s.peopleChanged(user, true)
	m.s.log("person " + user + " removed")
	return nil
}

// previewPatience is how long Remove's preview waits for each started machine to say what
// work on it is not pushed.
var previewPatience = 10 * time.Second

// removePreview is people/removePreview (FR-029): the person's started machines, each
// asked at once for the work on it that is not pushed, and their registered machines.
func (m *Methods) removePreview(user string, from Caller) wire.PersonRemovePreview {
	out := wire.PersonRemovePreview{StartedMachines: []wire.StartedMachinePreview{}, RegisteredMachines: []wire.PersonMachine{}}
	var started []records.MachineRecord
	for _, h := range m.records.Hosts() {
		if m.s.ownerOf(h.ID) != user {
			continue
		}
		if providers.LinkOf(&h) != nil {
			started = append(started, h)
			continue
		}
		state, _ := m.router.Described(h.ID)["state"].(string)
		out.RegisteredMachines = append(out.RegisteredMachines, wire.PersonMachine{ID: wire.MachineRef(h.ID), Name: h.Name,
			State: state, Platform: optional(h.Platform)})
	}
	previews := make([]wire.StartedMachinePreview, len(started))
	var wg sync.WaitGroup
	for i, h := range started {
		wg.Add(1)
		go func() {
			defer wg.Done()
			previews[i] = m.unpushedOn(h, from)
		}()
	}
	wg.Wait()
	out.StartedMachines = append(out.StartedMachines, previews...)
	return out
}

// unpushedOn asks a started machine for its worktrees, on a channel bound to the admin
// who asked, and keeps those with work that is not pushed.
func (m *Methods) unpushedOn(h records.MachineRecord, from Caller) wire.StartedMachinePreview {
	state, _ := m.router.Described(h.ID)["state"].(string)
	preview := wire.StartedMachinePreview{Host: wire.MachineRef(h.ID), Name: h.Name, State: state, Unpushed: []wire.UnpushedWork{}}
	if s, ok := m.router.State(h.ID); !ok || !s.online() {
		preview.Unknown = optional(h.Name + " is not online, so it could not be asked.")
		return preview
	}
	answer := m.router.DeliverKept(wire.CallWorktreesAll.Name, wire.Empty{}, from.Client, from.Kind, h.ID, previewPatience)
	var folders []wire.FolderWorktrees
	if answer == nil || len(answer.Error) > 0 || json.Unmarshal(answer.Result, &folders) != nil {
		preview.Unknown = optional(h.Name + " did not say what work on it is not pushed.")
		return preview
	}
	for _, p := range folders {
		for _, w := range p.Worktrees {
			if w.Status == nil || !unpushed(*w.Status) {
				continue
			}
			work := wire.UnpushedWork{Folder: p.Folder, Worktree: w.Root, Branch: w.Branch, Ahead: w.Status.Ahead,
				Unmerged: w.Status.Unmerged}
			if w.Status.Uncommitted > 0 {
				work.Uncommitted = new(w.Status.Uncommitted)
			}
			preview.Unpushed = append(preview.Unpushed, work)
		}
	}
	return preview
}

// unpushed says a worktree has work that would be lost: changes not committed, commits
// ahead of its upstream, or, with no upstream, commits not on the base.
func unpushed(s wire.WorktreeStatus) bool {
	if s.Uncommitted > 0 || (s.Ahead != nil && *s.Ahead > 0) {
		return true
	}
	return s.Ahead == nil && s.Unmerged != nil && *s.Unmerged > 0
}

// peopleChanged tells every admin's sessions, and the person changed.
func (s *Service) peopleChanged(user string, removed bool) {
	change := wire.PeopleChanged{}
	if user != "" {
		change.User = &user
	}
	if removed {
		change.Removed = &removed
	}
	told := map[string]bool{}
	for _, p := range s.records.People() {
		if p.IsAdmin() || p.ID == user {
			s.router.TellPerson(p.ID, "control/peopleChanged", change)
			told[p.ID] = true
		}
	}
	if !told[s.localOwner()] {
		s.router.TellPerson(s.localOwner(), "control/peopleChanged", change)
	}
	s.noteTeam()
	if s.providers != nil {
		// A role or a removal changes which providers each person is shown (#1761).
		s.providers.Republish()
	}
	// A bot made, renamed or removed changes which bots' workflows each person's machine
	// hears (#2027).
	s.tellPeoplesMachines()
	// A person removed may use no org route (#999).
	s.resendOrgRoutes()
	s.announce("peopleChanged", user, "")
}

// redeemInvite makes the person an invite code names, as its first client pairs (#994):
// once, as the code itself is spent once. A code replayed by the same key finds the
// person made the first time.
func (s *Service) redeemInvite(ctx context.Context, codeID string, in invite) (string, error) {
	id := personIDFor(codeID)
	if p := s.records.Person(id); p != nil {
		if p.IsRemoved() {
			return "", fail(notPermitted, "This invite was for a person who has since been removed. Ask for a new invite.")
		}
		return id, nil
	}
	now := records.Now()
	person := records.Person{ID: id, Name: in.Name, Kind: records.KindPerson, Role: in.Role,
		SignIns: []records.SignIn{{Provider: records.ProviderCode, Account: codeID, Added: &now}}}
	if err := s.records.SavePerson(ctx, person); err != nil {
		return "", err
	}
	s.peopleChanged(id, false)
	s.log("person " + id + " joined by an invite from " + in.By)
	return id, nil
}

// personIDFor is the person an invite makes: the same for the same code at every copy,
// so two copies spending one code make one person.
// It is a hash of the code's id, which is part of its secret.
func personIDFor(codeID string) string {
	sum := sha256.Sum256([]byte("agents-person\x00" + strings.ToLower(codeID)))
	id := hex.EncodeToString(sum[:16])
	return id[0:8] + "-" + id[8:12] + "-4" + id[13:16] + "-8" + id[17:20] + "-" + id[20:32]
}

// joinCommand is control/status's joinCommand: the line that asks to join as person.
func (s *Service) joinCommand(person string) string {
	if s.codes.URL == "" || person == "" {
		return ""
	}
	return JoinCommand(s.codes.URL, s.codes.Pin, person)
}
