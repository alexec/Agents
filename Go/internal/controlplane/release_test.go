package controlplane

import (
	"encoding/json"
	"sync"
	"testing"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// At its join, a machine that updates Agents Host itself is told the release this control
// plane names, its own version; one that does not is told nothing (#2178).
func TestAMachineIsToldTheRelease(t *testing.T) {
	t.Parallel()
	p := startPlane(t, store.NewMemory(), controllink.NewPrivateKey())
	p.s.cfg.Version = "0.12.0"
	var mu sync.Mutex
	told := map[string]string{}
	p.told = func(host, method string, params json.RawMessage) {
		if method != wire.NotifyMachineRelease.Name {
			return
		}
		var r wire.MachineRelease
		json.Unmarshal(params, &r)
		mu.Lock()
		told[host] = r.Version
		mu.Unlock()
	}
	hello := fakeHello("MACHINE-2")
	hello.Capabilities = append(append([]string{}, hello.Capabilities...), wire.CapHostUpdate1)
	mac := p.hostSaying(hello, nil)
	server := p.hostSaying(fakeHello("MACHINE-3"), nil)
	last := func(host string) string {
		mu.Lock()
		defer mu.Unlock()
		return told[host]
	}
	p.waitFor(func() bool { return last(mac.member.Host) != "" }, "the Mac told the release")
	if v := last(mac.member.Host); v != "0.12.0" {
		t.Fatalf("told %q", v)
	}
	if v := last(server.member.Host); v != "" {
		t.Fatalf("a machine without host.update/1 was told %q", v)
	}
}
