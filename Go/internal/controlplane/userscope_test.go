package controlplane

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/internal/controlplane/usersettings"
	"github.com/alexec/agents/Go/wire"
)

// deliveries is every host/userSettings each machine was told, by machine.
type deliveries struct {
	mu  sync.Mutex
	got map[string][]wire.MachineUserSettings
}

func (d *deliveries) heard(host, method string, params json.RawMessage) {
	if method != wire.NotifyHostUserSettings.Name {
		return
	}
	var u wire.MachineUserSettings
	json.Unmarshal(params, &u)
	d.mu.Lock()
	d.got[host] = append(d.got[host], u)
	d.mu.Unlock()
}

// last is what host was told last, and whether it was told anything.
func (d *deliveries) last(host string) (wire.MachineUserSettings, bool) {
	d.mu.Lock()
	defer d.mu.Unlock()
	list := d.got[host]
	if len(list) == 0 {
		return wire.MachineUserSettings{}, false
	}
	return list[len(list)-1], true
}

func secretsOf(u wire.MachineUserSettings) map[string]string {
	out := map[string]string{}
	for _, s := range u.Secrets {
		out[string(s.Name)] = s.Value
	}
	return out
}

// takingHello is a machine that writes host/userSettings (it serves settings/userPart).
func takingHello(name string) controllink.MachineHello {
	hello := fakeHello(name)
	hello.Capabilities = append(slices.Clone(hello.Capabilities), CapHostUserSettings)
	return hello
}

// notTakingHello is a machine from before #1760.
func notTakingHello(name string) controllink.MachineHello {
	hello := fakeHello(name)
	hello.Capabilities = slices.DeleteFunc(slices.Clone(hello.Capabilities), func(c string) bool { return c == CapHostUserSettings })
	return hello
}

func TestSettingsAndSecretsGoOnlyToTheirPersonsMachines(t *testing.T) {
	t.Parallel()
	key := make([]byte, 32)
	rand.Read(key)
	st := store.NewMemory()
	p := startPlaneWith(t, st, controllink.NewPrivateKey(), func(c *Config) {
		c.SecretKeeper = "base64key://" + base64.URLEncoding.EncodeToString(key)
	})
	told := &deliveries{got: map[string][]wire.MachineUserSettings{}}
	p.told = told.heard
	_, alexWindow := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: alexWindow}
	sam := p.invite(alexWindow, "Sam", wire.UserRoleMember)
	alexBox := p.machineSaying(alex, takingHello("MACHINE-20"))
	samBox := p.machineSaying(sam, takingHello("MACHINE-21"))
	older := p.machineSaying(sam, notTakingHello("MACHINE-22"))
	p.waitFor(func() bool { _, ok := told.last(samBox.member.Host); return ok }, "Sam's machine told at its join")

	// Sam's server and token, under You.
	call(t, sam.window, "", "user/setSettings", map[string]any{"part": "mcpServers",
		"value": map[string]any{"github": map[string]any{"url": "https://api.githubcopilot.com/mcp/"}}})
	call(t, sam.window, "", "user/setSecret", wire.UserSecret{Name: "GITHUB_TOKEN", Value: "ghp_sams-own-token"})
	waitNote(t, sam.window, wire.NotifyControlUserSettingsChanged.Name)
	p.waitFor(func() bool {
		u, _ := told.last(samBox.member.Host)
		return secretsOf(u)["GITHUB_TOKEN"] == "ghp_sams-own-token" && u.Settings.McpServers != nil
	}, "Sam's machine has the server and the token")

	// Nobody else's machine gets them, nor one that does not take them.
	if u, _ := told.last(alexBox.member.Host); len(u.Secrets) != 0 || u.Settings.McpServers != nil {
		t.Fatalf("Alex's machine was told %+v", u)
	}
	if _, ok := told.last(older.member.Host); ok {
		t.Fatal("a machine that does not take user settings was told them")
	}
	var alexSettings wire.UserSettings
	json.Unmarshal(call(t, alexWindow, "", "user/settings", nil), &alexSettings)
	if alexSettings.McpServers != nil {
		t.Fatalf("%+v", alexSettings)
	}

	// A machine Sam starts the next day has them with no further step.
	next := p.machineSaying(sam, takingHello("MACHINE-23"))
	p.waitFor(func() bool {
		u, _ := told.last(next.member.Host)
		return secretsOf(u)["GITHUB_TOKEN"] == "ghp_sams-own-token"
	}, "Sam's new machine has the token at its join")

	// The names, and the machines each went to; never a value.
	var names wire.UserSecretNames
	p.waitFor(func() bool {
		raw := call(t, sam.window, "", "user/secretNames", nil)
		if strings.Contains(string(raw), "ghp_") {
			t.Fatalf("a value went back to a client: %s", raw)
		}
		json.Unmarshal(raw, &names)
		return len(names.Secrets) == 1 && len(names.Secrets[0].Machines) == 2
	}, "both of Sam's machines noted")
	if !names.Sealing {
		t.Fatal("not sealing")
	}

	// SC-007: the store holds no readable secret.
	listed, _ := st.List(t.Context(), "")
	for _, k := range listed {
		if o, _ := st.Get(t.Context(), k.Key); o != nil && strings.Contains(string(o.Data), "sams-own-token") {
			t.Fatalf("%s holds the token", k.Key)
		}
	}
	// Nor does the log.
	for drained := false; !drained; {
		select {
		case line := <-p.lines:
			if strings.Contains(line, "sams-own-token") {
				t.Fatalf("logged: %s", line)
			}
		default:
			drained = true
		}
	}

	// Removed, a machine is sent nothing more, and Sam hears what was on it (FR-026).
	call(t, sam.window, "", "hosts/remove", wire.MachineRequest{Host: wire.MachineRef(next.member.Host)})
	note := waitNote(t, sam.window, wire.NotifyControlSecretsLeft.Name)
	var left wire.SecretsLeft
	json.Unmarshal(note.Params, &left)
	if string(left.Host) != next.member.Host || len(left.Secrets) != 1 || left.Secrets[0] != "GITHUB_TOKEN" {
		t.Fatalf("%+v", left)
	}
	json.Unmarshal(call(t, sam.window, "", "user/secretNames", nil), &names)
	if row := names.Secrets[0]; len(row.Machines) != 1 || len(row.LeftOn) != 1 || string(row.LeftOn[0].Host) != next.member.Host {
		t.Fatalf("%+v", row)
	}
	count := func() int { told.mu.Lock(); defer told.mu.Unlock(); return len(told.got[next.member.Host]) }
	before := count()
	call(t, sam.window, "", "user/setSecret", wire.UserSecret{Name: "GITHUB_TOKEN", Value: "ghp_rotated"})
	p.waitFor(func() bool {
		u, _ := told.last(samBox.member.Host)
		return secretsOf(u)["GITHUB_TOKEN"] == "ghp_rotated"
	}, "the new token")
	if count() != before {
		t.Fatal("a removed machine was sent the new token")
	}

	// Removed from the user scope, a secret leaves every machine.
	call(t, sam.window, "", "user/removeSecret", wire.UserSecretRequest{Name: "GITHUB_TOKEN"})
	p.waitFor(func() bool { u, _ := told.last(samBox.member.Host); return len(u.Secrets) == 0 }, "the token gone")
}

func TestNoKeeperKeepsNoSecrets(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	_, window := p.client("Alex's Mac")
	if e := callError(t, window, "", "user/setSecret", wire.UserSecret{Name: "TOKEN", Value: "v"}); !strings.Contains(e, "-32009") || strings.Contains(e, `"v"`) {
		t.Fatal(e)
	}
	var names wire.UserSecretNames
	json.Unmarshal(call(t, window, "", "user/secretNames", nil), &names)
	if names.Sealing {
		t.Fatalf("%+v", names)
	}
	if e := callError(t, window, "", "user/setSecret", wire.UserSecret{Name: "lower", Value: "v"}); !strings.Contains(e, "-32602") {
		t.Fatal(e)
	}
	// Settings still follow the person.
	call(t, window, "", "user/setSettings", map[string]any{"part": "costLimits", "value": map[string]any{"dailyTokens": 1000}})
	var got wire.UserSettings
	json.Unmarshal(call(t, window, "", "user/settings", nil), &got)
	if got.CostLimits == nil {
		t.Fatalf("%+v", got)
	}
}

// A machine does not send its agent configuration files to its person's other machines: the
// person's own clients change them (user/setSettings), so one machine cannot change what
// runs on the others.
func TestAMachineCannotSendAgentConfigFilesToItsPersonsOtherMachines(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	told := &deliveries{got: map[string][]wire.MachineUserSettings{}}
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: window}
	workspace := p.machineSaying(alex, takingHello("MACHINE-30"))
	mac := p.machineSaying(alex, takingHello("MACHINE-31"))
	p.waitFor(func() bool { _, ok := told.last(mac.member.Host); return ok }, "the Mac told at its join")

	contents := base64.StdEncoding.EncodeToString([]byte(`{"x":{"command":"y"}}`))
	yes := true
	for _, request := range []wire.AgentConfigFileRequest{
		{Path: "mcp.json", Contents: &contents, Time: time.Now().UnixMilli()},
		{Path: "plugins/one/hooks/hooks.json", Contents: &contents, Time: time.Now().UnixMilli()},
		{Path: "AGENTS.md", Contents: &contents, Time: time.Now().UnixMilli()},
		{Path: "skills/review/SKILL.md", Contents: &contents, Time: time.Now().UnixMilli()},
		{Path: "personas/reviewer.md", Contents: &contents, Time: time.Now().UnixMilli()},
		{Path: "skills/review/SKILL.md", Deleted: &yes, Time: time.Now().UnixMilli() + 1},
	} {
		_, err := workspace.uplink.Ask(t.Context(), wire.CallUserSetAgentConfigFile.Name, request)
		if err == nil || !strings.Contains(err.Error(), "does not send its agent configuration files") {
			t.Fatalf("%s from a machine: %v", request.Path, err)
		}
	}
	if u, _ := told.last(mac.member.Host); u.Settings.AgentConfigFiles != nil {
		t.Fatalf("the Mac was sent files from another machine: %+v", u.Settings.AgentConfigFiles)
	}
	var stored wire.UserSettings
	json.Unmarshal(call(t, window, "", "user/settings", nil), &stored)
	if stored.AgentConfigFiles != nil {
		t.Fatalf("kept files from a machine: %+v", stored.AgentConfigFiles)
	}
}

// A person's settings kept before #2703 can hold their machines' agent configuration files,
// far more than one frame on a machine's link takes (#2730). The delivery leaves them out,
// so the machine is told its settings and its link stays up, not dropped and rejoined
// without end.
func TestADeliveryFitsTheMachinesLink(t *testing.T) {
	t.Parallel()
	st := store.NewMemory()
	p := startPlane(t, st, controllink.NewPrivateKey())
	told := &deliveries{got: map[string][]wire.MachineUserSettings{}}
	p.told = told.heard
	_, window := p.client("Alex's Mac")
	alex := &person{id: p.s.localOwner(), window: window}

	contents := strings.Repeat("A", 34<<20)
	at := "2026-10-20T00:00:00Z"
	kept := wire.UserSettings{
		McpServers: wire.JSONValue(`{"github":{"url":"https://api.githubcopilot.com/mcp/"}}`),
		AgentConfigFiles: &wire.AgentConfigFiles{Files: []wire.AgentConfigFile{
			{Path: "plugins/one/big.bin", Contents: &contents, Time: 1, Machine: "MACHINE-40"},
			{Path: "plugins/two/big.bin", Contents: &contents, Time: 1, Machine: "MACHINE-40"},
		}},
		Updated: &at,
	}
	data, _ := json.Marshal(kept)
	if len(data) <= controllink.MaxMessage {
		t.Fatalf("the kept settings are %d bytes, not over the frame", len(data))
	}
	if _, err := st.Put(t.Context(), usersettings.Prefix+alex.id+"/settings.json", data, store.Always); err != nil {
		t.Fatal(err)
	}

	box := p.machineSaying(alex, takingHello("MACHINE-41"))
	p.waitFor(func() bool { u, ok := told.last(box.member.Host); return ok && u.Settings.McpServers != nil }, "the machine told its settings")
	if u, _ := told.last(box.member.Host); u.Settings.AgentConfigFiles != nil {
		t.Fatalf("the machine was sent %d agent configuration files", len(u.Settings.AgentConfigFiles.Files))
	}
	// Still on the same link: one delivery, no rejoin.
	time.Sleep(500 * time.Millisecond)
	if s, ok := p.s.Router().State(box.member.Host); !ok || !s.online() {
		t.Fatal("the machine is not online")
	}
	told.mu.Lock()
	n := len(told.got[box.member.Host])
	told.mu.Unlock()
	if n != 1 {
		t.Fatalf("the machine was told its settings %d times: it rejoined", n)
	}
}
