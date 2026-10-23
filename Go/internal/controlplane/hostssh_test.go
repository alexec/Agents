package controlplane

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// The ssh that installs, finds and updates a machine is the control plane
// account's own, so only the local owner, whose ssh it is, uses it. Another person, a
// member or an admin, is refused each method before it reaches ssh.
func TestOnlyTheLocalOwnerUsesTheControlPlanesSSH(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	// The owner's ssh config has one server; this ssh never connects anywhere.
	config := filepath.Join(t.TempDir(), "config")
	if err := os.WriteFile(config, []byte("Host prod-box\n  HostName 192.0.2.1\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	p.s.installer.ConfigFile = config
	p.s.installer.SSH = "/usr/bin/false"

	_, alexWindow := p.client("Alex's Mac")
	sam := p.invite(alexWindow, "Sam", wire.UserRoleMember)
	samMachine := p.machine(sam, "MACHINE-3")
	kim := p.invite(alexWindow, "Kim", wire.UserRoleAdmin)
	kimMachine := p.machine(kim, "MACHINE-4")

	for _, who := range []struct {
		person  *person
		machine *fakeHost
	}{{sam, samMachine}, {kim, kimMachine}} {
		calls := map[string]map[string]any{
			"hosts/install":  {"destination": "prod-box"},
			"hosts/detect":   {},
			"hosts/sshHosts": {},
			"hosts/update":   {"host": who.machine.member.Host, "destination": "prod-box"},
		}
		for method, params := range calls {
			if _, err := who.person.window.Call(context.Background(), "", method, params); err == nil || !strings.Contains(err.Error(), "Only the control plane's owner") {
				t.Errorf("%s as %s: %v", method, who.person.id, err)
			}
		}
	}

	// The local owner is not refused.
	if got := string(call(t, alexWindow, "", "hosts/sshHosts", map[string]any{})); !strings.Contains(got, "prod-box") {
		t.Fatalf("the owner's ssh hosts: %s", got)
	}
	call(t, alexWindow, "", "hosts/detect", map[string]any{})
	if e := callError(t, alexWindow, "", "hosts/install", map[string]any{"destination": " "}); !strings.Contains(e, "Say which server.") {
		t.Fatal(e)
	}
	if e := callError(t, alexWindow, "", "hosts/update", map[string]any{"host": "x", "destination": "prod-box"}); !strings.Contains(e, "There is no such host.") {
		t.Fatal(e)
	}
	// A bot's machine still joins with an admin's code (#1761).
	call(t, kim.window, "", "hosts/startEnroll", map[string]any{})
}
