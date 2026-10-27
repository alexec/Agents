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
	"github.com/alexec/agents/Go/wire"
)

// deliveries is every machine/userSettings each machine was told, by machine.
type deliveries struct {
	mu  sync.Mutex
	got map[string][]wire.MachineUserSettings
}

func (d *deliveries) heard(host, method string, params json.RawMessage) {
	if method != wire.NotifyMachineUserSettings.Name {
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

// takingHello is a machine that writes machine/userSettings (it serves settings/userPart).
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
	contents := base64.StdEncoding.EncodeToString([]byte("Sam's shared instructions"))
	if _, err := samBox.uplink.Ask(t.Context(), wire.CallUserSetAgentConfigFile.Name, wire.AgentConfigFileRequest{
		Path: "AGENTS.md", Contents: &contents, Time: time.Now().UnixMilli(),
	}); err != nil {
		t.Fatalf("host could not sync its configuration: %v", err)
	}
	p.waitFor(func() bool {
		u, _ := told.last(samBox.member.Host)
		return u.Settings.AgentConfigFiles != nil && len(u.Settings.AgentConfigFiles.Files) == 1
	}, "Sam's machine gets its synced configuration")
	if got, _ := told.last(samBox.member.Host); got.Settings.AgentConfigFiles.Files[0].Machine != "MACHINE-21" {
		t.Fatalf("clock uses host id instead of machine id: %+v", got.Settings.AgentConfigFiles.Files[0])
	}
	var stored wire.UserSettings
	json.Unmarshal(call(t, sam.window, "", "user/settings", nil), &stored)
	if stored.AgentConfigFiles == nil || stored.AgentConfigFiles.Files[0].Contents != nil {
		t.Fatalf("client saw file contents: %+v", stored.AgentConfigFiles)
	}
	if _, err := samBox.uplink.Ask(t.Context(), wire.CallUserSetAgentConfigFile.Name, wire.AgentConfigFileRequest{
		Path: "AGENTS.md", Contents: &contents, Time: time.Now().UnixMilli(),
	}); err != nil {
		t.Fatal(err)
	}
	alexContents := base64.StdEncoding.EncodeToString([]byte("Alex's own instructions"))
	if _, err := alexBox.uplink.Ask(t.Context(), wire.CallUserSetAgentConfigFile.Name, wire.AgentConfigFileRequest{
		Path: "AGENTS.md", Contents: &alexContents, Time: time.Now().UnixMilli(),
	}); err != nil {
		t.Fatalf("Alex's machine could not sync its own configuration: %v", err)
	}
	json.Unmarshal(call(t, sam.window, "", "user/settings", nil), &stored)
	if stored.AgentConfigFiles.Files[0].Contents != nil || stored.AgentConfigFiles.Files[0].Digest == "" {
		t.Fatalf("Sam's configuration was not kept independently: %+v", stored.AgentConfigFiles)
	}
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
	call(t, sam.window, "", "machines/remove", wire.MachineRequest{Host: wire.MachineRef(next.member.Host)})
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
