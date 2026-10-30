package controlplane

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// person is one person's window on a plane, and the machines they joined.
type person struct {
	id       string
	member   *controllink.ClientMembership
	window   *controllink.Session
	machines []*fakeHost
	// The users each machine was told on the channels it opened.
	mu     sync.Mutex
	actors []string
}

// invite has the local owner's window invite a person, who pairs with the code.
func (p *plane) invite(owner *controllink.Session, name string, role wire.UserRole) *person {
	p.t.Helper()
	var invited wire.PersonInvited
	json.Unmarshal(call(p.t, owner, "", "people/invite", wire.PersonInvite{Name: name, Role: role}), &invited)
	code, err := controllink.ParseCode(invited.Text)
	if err != nil {
		p.t.Fatal(err)
	}
	m, err := controllink.PairClient(context.Background(), code, name+"'s Mac")
	if err != nil {
		p.t.Fatal(err)
	}
	s, err := controllink.DialClient(context.Background(), m)
	if err != nil {
		p.t.Fatal(err)
	}
	p.t.Cleanup(s.Close)
	var status wire.ControlStatus
	json.Unmarshal(call(p.t, s, "", "control/status", nil), &status)
	if status.Person == nil || status.Person.Name != name || status.Person.Role != role {
		p.t.Fatalf("%+v", status.Person)
	}
	return &person{id: status.Person.ID, member: m, window: s}
}

// machine joins a machine with a code the person's window made.
func (p *plane) machine(who *person, name string) *fakeHost {
	p.t.Helper()
	return p.machineSaying(who, fakeHello(name))
}

// machineSaying is machine, with its own hello.
func (p *plane) machineSaying(who *person, hello controllink.MachineHello) *fakeHost {
	p.t.Helper()
	var shown wire.ControlCodeShown
	json.Unmarshal(call(p.t, who.window, "", "hosts/startEnroll", nil), &shown)
	code, err := controllink.ParseCode(shown.Text)
	if err != nil {
		p.t.Fatal(err)
	}
	root, private := p.t.TempDir(), controllink.NewPrivateKey()
	member, err := controllink.Enroll(context.Background(), root, code, private, hello)
	if err != nil {
		p.t.Fatal(err)
	}
	h := p.serveHost(root, member, private, hello, func(c controllink.Conn) {
		if a, ok := c.(controllink.Actored); ok && a.Actor() != nil {
			who.mu.Lock()
			who.actors = append(who.actors, a.Actor().User)
			who.mu.Unlock()
		}
	})
	who.machines = append(who.machines, h)
	return h
}

func listedHosts(t *testing.T, s *controllink.Session) []string {
	t.Helper()
	var list []wire.ControlMachine
	json.Unmarshal(call(t, s, "", "hosts/list", nil), &list)
	out := []string{}
	for _, h := range list {
		out = append(out, string(h.ID))
	}
	sort.Strings(out)
	return out
}

func idsOf(hosts []*fakeHost) []string {
	out := []string{}
	for _, h := range hosts {
		out = append(out, h.member.Host)
	}
	sort.Strings(out)
	return out
}

// US1 (T012): one person sees no change. A code-paired client and a code-enrolled host
// are the local owner's, who is the one admin.
func TestOnePersonSeesNoChange(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	box := p.host("MACHINE-2")
	_, window := p.client("Test window")
	owner := p.s.localOwner()

	if got := listedHosts(t, window); len(got) != 1 || got[0] != box.member.Host {
		t.Fatal(got)
	}
	call(t, window, box.member.Host, "agents/list", nil)
	var people wire.PeopleList
	json.Unmarshal(call(t, window, "", "people/list", nil), &people)
	if !people.Admin || len(people.People) != 1 {
		t.Fatalf("%+v", people)
	}
	me := people.People[0]
	if me.ID != owner || me.Role != wire.UserRoleAdmin || me.LocalOwner == nil || me.You == nil ||
		len(me.Machines) != 1 || len(me.Clients) != 1 || len(me.SignIns) != 1 || me.SignIns[0].Provider != records.ProviderLocal {
		t.Fatalf("%+v", me)
	}
	if h := p.s.Records().Host(box.member.Host); h.Owner == nil || *h.Owner != owner {
		t.Fatalf("%+v", h.Owner)
	}
}

// FR-018 (SC-003): with three people and two machines each, every person reaches only
// their own machines; another's is not found, through the router and through every
// control-plane method that names a machine. Admins see the name, user and state only.
func TestEachPersonReachesOnlyTheirOwnMachines(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, alexWindow := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: alexWindow}
	sam := p.invite(alexWindow, "Sam", wire.UserRoleMember)
	kim := p.invite(alexWindow, "Kim", wire.UserRoleAdmin)
	everyone := []*person{alex, sam, kim}
	for i, who := range everyone {
		p.machine(who, "MACHINE-"+itoa(10+2*i))
		p.machine(who, "MACHINE-"+itoa(11+2*i))
	}

	for _, who := range everyone {
		if got, want := listedHosts(t, who.window), idsOf(who.machines); strings.Join(got, ",") != strings.Join(want, ",") {
			t.Fatalf("%s lists %v, owns %v", who.id, got, want)
		}
		for _, other := range everyone {
			for _, h := range other.machines {
				if other == who {
					call(t, who.window, h.member.Host, "agents/list", nil)
					continue
				}
				if e := callError(t, who.window, h.member.Host, "agents/list", nil); !strings.Contains(e, "-32091") {
					t.Fatalf("%s reached %s's machine: %s", who.id, other.id, e)
				}
			}
		}
	}
	// Each machine opened channels for its own person's clients only.
	for _, who := range everyone[1:] {
		who.mu.Lock()
		for _, user := range who.actors {
			if user != who.id {
				t.Fatalf("%s's machine opened a channel for %s", who.id, user)
			}
		}
		who.mu.Unlock()
	}

	// People: an admin sees everyone's machines by name and state; a member only themselves.
	var list wire.PeopleList
	json.Unmarshal(call(t, kim.window, "", "people/list", nil), &list)
	if !list.Admin || len(list.People) != 3 || len(list.People[1].Machines) != 2 {
		t.Fatalf("%+v", list)
	}
	json.Unmarshal(call(t, sam.window, "", "people/list", nil), &list)
	if list.Admin || len(list.People) != 1 || list.People[0].ID != sam.id {
		t.Fatalf("%+v", list)
	}
	if e := callError(t, sam.window, "", "people/invite", wire.PersonInvite{Name: "Eve", Role: wire.UserRoleAdmin}); !strings.Contains(e, "-32045") {
		t.Fatal(e)
	}
	// Clients: each person's own.
	var clients []wire.ClientRecord
	json.Unmarshal(call(t, sam.window, "", "clients/list", nil), &clients)
	if len(clients) != 1 || string(clients[0].ID) != sam.member.Client {
		t.Fatalf("%+v", clients)
	}
	if e := callError(t, sam.window, "", "clients/forget", wire.ClientRequest{Client: wire.UUID(kim.member.Client)}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
}

// hostNamingMethods are the control-plane methods that name a machine by host (and
// lendSignIn and lendGit by from too): each refuses another person's as not found.
var hostNamingMethods = map[string]bool{
	"hosts/update": true, "hosts/checkAgain": true, "hosts/remove": true, "hosts/setRelay": true,
	"hosts/lendSignIn": true, "hosts/lendGit": true, "hosts/lastHeard": true,
	"hosts/link": true, "hosts/unlink": true, "hosts/start": true, "hosts/stop": true, "hosts/keep": true,
	"hosts/deleteMachine": true, "hosts/setMachineOptions": true,
}

// hostNamingParams are params that would do something with host for each of them.
func hostNamingParams(host string) map[string]any {
	return map[string]any{"host": host, "from": host, "runtime": "claude", "allowed": true, "server": "github.com",
		"relay": false, "provider": "x", "method": "agents/start", "params": map[string]any{}}
}

// T010: every control-plane method a client may call says whether it names a machine,
// and each that does refuses another person's as not found. A method added with no
// entry here fails.
func TestEveryClientMethodChecksTheOwner(t *testing.T) {
	t.Parallel()
	p := startPlaneWith(t, store.NewMemory(), controllink.NewPrivateKey(), func(c *Config) { c.ProviderHome = t.TempDir() })
	_, alexWindow := p.client("Alex's Mac")
	alexMachine := p.host("MACHINE-2")
	sam := p.invite(alexWindow, "Sam", wire.UserRoleMember)
	samMachine := p.machine(sam, "MACHINE-3")

	// Methods that name no machine: answered for the caller alone.
	namesNone := map[string]bool{
		"daemon/ping": true, "control/status": true, "hosts/list": true, "hosts/startEnroll": true, "hosts/install": true,
		"hosts/detect": true, "hosts/sshHosts": true, "control/setFolderDetection": true, "clients/list": true,
		"clients/startPairing": true, "clients/stopPairing": true, "clients/setGrant": true, "clients/forget": true,
		"clients/connections": true, "clients/forgetSelf": true, "clients/setPushToken": true, "clients/setActivityToken": true, "devices/list": true,
		"devices/startPairing": true, "devices/stopPairing": true, "devices/forget": true, "audit/list": true, "audit/sinks": true, "audit/setSinks": true,
		"audit/export": true, "control/setAuditDays": true, "people/list": true, "people/invite": true,
		"people/setRole": true, "people/remove": true, "people/removePreview": true, "hosts/joinRequests": true, "hosts/approveJoin": true,
		"hosts/denyJoin": true, "control/rotate": true,
		"providers/list": true, "providers/refresh": true, "providers/add": true, "providers/update": true,
		"providers/remove": true, "providers/options": true, "providers/runtimes": true, "providers/draftStart": true,
		"providers/draftAnswer": true, "providers/draftCancel": true, "providers/create": true, "hosts/listKept": true,
		"hosts/retryKept": true, "hosts/dropKept": true, "reports/usage": true, "reports/export": true, "reports/value": true,
		"user/settings": true, "user/setSettings": true, "user/setAgentConfigFile": true, "user/setSecret": true, "user/removeSecret": true,
		"user/secretNames": true, "groups/list": true, "groups/set": true, "groups/remove": true,
		"providers/setGroup": true, "bots/make": true, "bots/setCaps": true,
		"links/list": true, "links/requests": true, "links/approve": true, "links/deny": true, "links/remove": true,
		"signIn/providers": true, "signIn/pair": true, "signIn/addToMe": true, "signIn/removeFromMe": true,
		"signIn/configure": true, "signIn/requests": true, "signIn/approve": true, "signIn/deny": true,
		"signIn/discover": true, "signIn/orgStart": true, "signIn/ticket": true, "signIn/orgProviders/list": true,
		"signIn/orgProviders/set": true, "signIn/orgProviders/check": true, "signIn/orgProviders/remove": true,
		"signIn/domains/list": true, "signIn/domains/claim": true, "signIn/domains/check": true, "signIn/domains/set": true,
		"signIn/domains/preview": true, "signIn/domains/remove": true,
		"policy/get": true, "policy/mine": true, "policy/set": true, "policy/stopAll": true, "policy/raise": true,
		"orgRoutes/mine": true, "orgRoutes/list": true, "orgRoutes/set": true, "orgRoutes/replaceKey": true,
		"orgRoutes/check": true, "orgRoutes/remove": true,
		"scim/set": true, "scim/tokens/list": true, "scim/tokens/make": true, "scim/tokens/revoke": true,
		"groups/setRole": true, "people/removeRequests": true,
		"projects/list": true, "projects/set": true, "projects/remove": true, "projects/setSlot": true,
		"governance/usage": true, "governance/request": true, "governance/requests": true, "governance/decide": true,
		"governance/approvals": true, "governance/revoke": true,
		"readApi/list": true, "readApi/make": true, "readApi/revoke": true,
		// It names a bot's machine, an admin's to stop, and checks that itself (#1761).
		"bots/stopRun": true,
	}
	namesHost := hostNamingMethods
	all := map[string]bool{}
	for method := range own {
		all[method] = true
	}
	for method := range workspaceMethods {
		all[method] = true
	}
	for method := range all {
		if namesNone[method] == namesHost[method] {
			t.Errorf("%s: say whether it names a machine (#994)", method)
		}
	}
	for method := range namesHost {
		if !all[method] {
			t.Errorf("%s is not a method any more", method)
		}
		for _, field := range []string{"host", "from"} {
			params := hostNamingParams(samMachine.member.Host)
			params[field] = alexMachine.member.Host
			e := callError(t, sam.window, "", method, params)
			if !strings.Contains(e, "-32091") {
				t.Errorf("%s with Alex's machine as %s: %s", method, field, e)
			}
		}
	}
	if p.s.Records().Host(alexMachine.member.Host) == nil {
		t.Fatal("Sam removed Alex's machine")
	}
}

// FR-006: a control plane keeps one admin at least; a removed person's clients are cut
// off and their machines leave, and the code they paired with does nothing again.
func TestRolesAndRemoval(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, alexWindow := p.client("Alex's Mac")
	alex := p.s.localOwner()
	if e := callError(t, alexWindow, "", "people/setRole", wire.PersonRoleRequest{User: alex, Role: wire.UserRoleMember}); !strings.Contains(e, "only admin") {
		t.Fatal(e)
	}
	sam := p.invite(alexWindow, "Sam", wire.UserRoleMember)
	samMachine := p.machine(sam, "MACHINE-3")
	call(t, alexWindow, "", "people/setRole", wire.PersonRoleRequest{User: sam.id, Role: wire.UserRoleAdmin})
	call(t, sam.window, "", "people/setRole", wire.PersonRoleRequest{User: alex, Role: wire.UserRoleMember})
	if e := callError(t, sam.window, "", "people/setRole", wire.PersonRoleRequest{User: sam.id, Role: wire.UserRoleMember}); !strings.Contains(e, "only admin") {
		t.Fatal(e)
	}
	call(t, sam.window, "", "people/setRole", wire.PersonRoleRequest{User: alex, Role: wire.UserRoleAdmin})
	if e := callError(t, alexWindow, "", "people/remove", wire.PersonRequest{User: alex}); !strings.Contains(e, "yourself") {
		t.Fatal(e)
	}
	if e := callError(t, sam.window, "", "people/remove", wire.PersonRequest{User: alex}); !strings.Contains(e, "local owner") {
		t.Fatal(e)
	}
	// An invite not used yet, and a code Sam made, are spent by nobody after the removal.
	var shown wire.ControlCodeShown
	json.Unmarshal(call(t, sam.window, "", "clients/startPairing", nil), &shown)

	call(t, alexWindow, "", "people/remove", wire.PersonRequest{User: sam.id})
	p.waitFor(func() bool { return p.s.Records().Client(sam.member.Client) == nil }, "Sam's client forgotten")
	if p.s.Records().Host(samMachine.member.Host) != nil {
		t.Fatal("Sam's machine is still there")
	}
	if _, err := sam.window.Call(context.Background(), "", "daemon/ping", nil); err == nil {
		t.Fatal("Sam's window still talks")
	}
	code, _ := controllink.ParseCode(shown.Text)
	if _, err := controllink.PairClient(context.Background(), code, "Sam's phone"); err == nil {
		t.Fatal("a removed person's code paired")
	}
	var list wire.PeopleList
	json.Unmarshal(call(t, alexWindow, "", "people/list", nil), &list)
	if len(list.People) != 1 {
		t.Fatalf("%+v", list)
	}
}

// FR-017: a machine with no code asks to join as a person, and joins once that person
// approves it, as theirs. Another person cannot decide it, and a denied one ends.
func TestAMachineJoinsByApproval(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, alexWindow := p.client("Alex's Mac")
	sam := p.invite(alexWindow, "Sam", wire.UserRoleMember)

	root, private := t.TempDir(), controllink.NewPrivateKey()
	codes := make(chan string, 1)
	joined := make(chan *controllink.Membership, 1)
	failed := make(chan error, 1)
	go func() {
		m, err := controllink.AskToJoin(context.Background(), root, controllink.JoinAsk{URL: p.url, Pin: "-", Person: "sam"},
			private, fakeHello("sam-build"), func(code string) { codes <- code })
		if err != nil {
			failed <- err
			return
		}
		joined <- m
	}()
	code := <-codes
	note := waitNote(t, sam.window, "control/joinRequested")
	var asked wire.JoinRequest
	json.Unmarshal(note.Params, &asked)
	if asked.Code != code || asked.For != sam.id || asked.Name != "box sam-build" {
		t.Fatalf("%+v", asked)
	}
	var waiting []wire.JoinRequest
	json.Unmarshal(call(t, alexWindow, "", "hosts/joinRequests", nil), &waiting)
	if len(waiting) != 0 {
		t.Fatalf("Alex sees Sam's request: %+v", waiting)
	}
	if e := callError(t, alexWindow, "", "hosts/approveJoin", wire.JoinRequestDecide{Request: asked.Request}); !strings.Contains(e, "no such request") {
		t.Fatal(e)
	}
	var approved wire.JoinApproved
	json.Unmarshal(call(t, sam.window, "", "hosts/approveJoin", wire.JoinRequestDecide{Request: asked.Request}), &approved)
	var member *controllink.Membership
	select {
	case member = <-joined:
	case err := <-failed:
		t.Fatal(err)
	case <-time.After(10 * time.Second):
		t.Fatal("the machine did not hear it was approved")
	}
	if member.Host != string(approved.Host) {
		t.Fatalf("%s %s", member.Host, approved.Host)
	}
	p.serveHost(root, member, private, fakeHello("sam-build"), nil)
	if got := listedHosts(t, sam.window); len(got) != 1 || got[0] != member.Host {
		t.Fatal(got)
	}
	call(t, sam.window, member.Host, "agents/list", nil)
	if e := callError(t, alexWindow, member.Host, "agents/list", nil); !strings.Contains(e, "-32091") {
		t.Fatal(e)
	}
	if e := callError(t, sam.window, "", "hosts/approveJoin", wire.JoinRequestDecide{Request: asked.Request}); !strings.Contains(e, "ended") {
		t.Fatal(e)
	}

	// One that names nobody is an admin's to decide; denied, the machine hears so.
	body, _ := json.Marshal(wire.MachineJoinAsk{Name: "stray", Platform: "Linux", PublicKey: mustPublic(t)})
	resp, err := http.Post(p.url+"/v1/join", "application/json", bytes.NewReader(body))
	if err != nil {
		t.Fatal(err)
	}
	var ticket wire.MachineJoinTicket
	json.NewDecoder(resp.Body).Decode(&ticket)
	resp.Body.Close()
	json.Unmarshal(call(t, sam.window, "", "hosts/joinRequests", nil), &waiting)
	if len(waiting) != 0 {
		t.Fatalf("a member sees a request that names nobody: %+v", waiting)
	}
	json.Unmarshal(call(t, alexWindow, "", "hosts/joinRequests", nil), &waiting)
	if len(waiting) != 1 || waiting[0].Request != ticket.Request {
		t.Fatalf("%+v", waiting)
	}
	call(t, alexWindow, "", "hosts/denyJoin", wire.JoinRequestDecide{Request: ticket.Request})
	resp, err = http.Get(p.url + "/v1/join/" + ticket.Request)
	if err != nil {
		t.Fatal(err)
	}
	var decision wire.MachineJoinDecision
	json.NewDecoder(resp.Body).Decode(&decision)
	resp.Body.Close()
	if decision.Result != "denied" || decision.Host != nil {
		t.Fatalf("%+v", decision)
	}
}

func mustPublic(t *testing.T) []byte {
	pub, err := controllink.PublicKey(controllink.NewPrivateKey())
	if err != nil {
		t.Fatal(err)
	}
	return pub
}

func waitNote(t *testing.T, s *controllink.Session, method string) controllink.Note {
	t.Helper()
	deadline := time.After(10 * time.Second)
	for {
		select {
		case n := <-s.Notes:
			if n.Method == method {
				return n
			}
		case <-deadline:
			t.Fatalf("no %s", method)
		}
	}
}

// A workspace's machine is the person's who started it (FR-028): the host code its first
// boot uses names them.
func TestACodeMadeForAPersonMakesTheirMachine(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	shown, err := p.s.Codes().Issue(withCodeOwner(context.Background(), "someone"), true, false, time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	code, _ := controllink.ParseCode(shown.Text)
	member, err := controllink.Enroll(context.Background(), t.TempDir(), code, controllink.NewPrivateKey(), fakeHello("ws"))
	if err != nil {
		t.Fatal(err)
	}
	if h := p.s.Records().Host(member.Host); h == nil || h.Owner == nil || *h.Owner != "someone" {
		t.Fatalf("%+v", h)
	}
}

// FR-020, FR-021: a machine is told only its own user's windows, and lends and borrows a
// sign-in or git access only within one user. A lend made before the team tier by another
// user's machine is neither shown nor used.
func TestLendsAndWindowsStayWithinOneUser(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	ctx := context.Background()
	_, alexWindow := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: alexWindow}
	sam := p.invite(alexWindow, "Sam", wire.UserRoleMember)
	alexMac := p.machine(alex, "ALEX-MAC").member.Host
	samBox := p.machine(sam, "SAM-BOX").member.Host
	samMac := p.machine(sam, "SAM-MAC").member.Host
	for _, mac := range []string{alexMac, samMac} {
		record := *p.s.Records().Host(mac)
		record.Platform = "macOS arm64"
		if err := p.s.Records().SaveHost(ctx, record); err != nil {
			t.Fatal(err)
		}
	}

	// host/clients names the host's user, and only that user's windows.
	clients := p.s.hostClients(samBox)
	if clients.User == nil || *clients.User != sam.id {
		t.Fatalf("user: %+v", clients.User)
	}
	for _, c := range clients.Clients {
		if c.Person == nil || *c.Person != sam.id {
			t.Fatalf("another person's window told to Sam's machine: %+v", c)
		}
	}

	// Sam cannot name Alex's machine as a lender.
	if e := callError(t, sam.window, "", "hosts/lendSignIn", wire.LendSignIn{Host: wire.MachineRef(samBox), From: wire.MachineRef(alexMac),
		Runtime: "claude", Allowed: true}); !strings.Contains(e, "-32091") {
		t.Fatalf("a lend from another user's machine: %s", e)
	}
	call(t, sam.window, "", "hosts/lendSignIn", wire.LendSignIn{Host: wire.MachineRef(samBox), From: wire.MachineRef(samMac),
		Runtime: "codex", Allowed: true})

	// A lend from before the team tier, from Alex's Mac, is not shown and not used.
	record := *p.s.Records().Host(samBox)
	record.SignInFrom["claude"] = alexMac
	record.GitFrom = map[string]string{"github.com": alexMac}
	if err := p.s.Records().SaveHost(ctx, record); err != nil {
		t.Fatal(err)
	}
	var hosts []wire.ControlMachine
	json.Unmarshal(call(t, sam.window, "", "hosts/list", nil), &hosts)
	for _, h := range hosts {
		if string(h.ID) != samBox {
			continue
		}
		if _, ok := h.SignInFrom["claude"]; ok || h.GitFrom != nil || string(h.SignInFrom["codex"]) != samMac {
			t.Fatalf("Sam's machine's lends: %+v %+v", h.SignInFrom, h.GitFrom)
		}
	}
	params, _ := json.Marshal(wire.TunnelOpen{Runtime: "claude", Ref: "r"})
	if _, err := p.s.methods.HostSaid(samBox, "tunnel/open", params); err == nil || !strings.Contains(err.Error(), "-32045") {
		t.Fatalf("a tunnel to another user's machine: %v", err)
	}
	// Git access is asked of Sam's own Mac only, never Alex's.
	if lender := p.s.methods.gitLender(samBox); lender != samMac {
		t.Fatalf("git lender: %s", lender)
	}
}

// FR-029, T036: Remove first lists the person's started machines, each with the work on it
// that is not pushed, and their registered machines. Only an admin may ask. Remove then
// takes every machine off at once.
func TestRemoveFirstSaysWhatWorkIsNotPushed(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	ctx := context.Background()
	_, alexWindow := p.client("Alex's Mac")
	sam := p.invite(alexWindow, "Sam", wire.UserRoleMember)
	started := p.machine(sam, "SAM-WS").member.Host
	registered := p.machine(sam, "SAM-MAC").member.Host
	record := *p.s.Records().Host(started)
	record.Workspace, _ = json.Marshal(providers.WorkspaceLink{Provider: "docker", Workspace: "sam-ws"})
	if err := p.s.Records().SaveHost(ctx, record); err != nil {
		t.Fatal(err)
	}

	if e := callError(t, sam.window, "", "people/removePreview", wire.PersonRequest{User: sam.id}); !strings.Contains(e, "-32045") {
		t.Fatalf("a member asked: %s", e)
	}
	var preview wire.PersonRemovePreview
	json.Unmarshal(call(t, alexWindow, "", "people/removePreview", wire.PersonRequest{User: sam.id}), &preview)
	if len(preview.RegisteredMachines) != 1 || string(preview.RegisteredMachines[0].ID) != registered {
		t.Fatalf("registered: %+v", preview.RegisteredMachines)
	}
	if len(preview.StartedMachines) != 1 || string(preview.StartedMachines[0].Host) != started || preview.StartedMachines[0].Unknown != nil {
		t.Fatalf("started: %+v", preview.StartedMachines)
	}
	// The fake host's worktrees: one ahead, one with no upstream and commits not on main,
	// one with changes not committed, and one pushed, which is left out.
	work := preview.StartedMachines[0].Unpushed
	if len(work) != 3 || deref(work[0].Branch) != "agents/ahead" || deref(work[0].Ahead) != 2 ||
		deref(work[1].Unmerged) != 4 || deref(work[2].Uncommitted) != 1 {
		t.Fatalf("unpushed: %+v", work)
	}

	call(t, alexWindow, "", "people/remove", wire.PersonRequest{User: sam.id})
	if p.s.Records().Host(started) != nil || p.s.Records().Host(registered) != nil {
		t.Fatal("a machine of Sam's is still there")
	}
	if e := callError(t, alexWindow, "", "people/removePreview", wire.PersonRequest{User: sam.id}); !strings.Contains(e, "no such person") {
		t.Fatalf("a removed person: %s", e)
	}
}
