package providers

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/wire"
)

// A carried provider's calls go to its machine as providers/carry, with its record and no
// secret, and what the machine answers is the call's (#3398).
func TestACarriedProviderIsCalledOnItsMachine(t *testing.T) {
	router := newFakeRouter()
	router.setOnline(carrier, true)
	var seen wire.ProviderCarry
	router.asking = func(host, method string, params json.RawMessage) json.RawMessage {
		json.Unmarshal(params, &seen)
		return rawOf(wire.ProviderCarried{Result: rawOf(MachineInfo{ID: "ws-1", Name: "ws-1", State: "running"})})
	}
	machine := carrier
	c := &Carried{Record: ProviderRecord{ID: "p", Name: "P", Kind: KindCommands, SecretNames: []string{"TOKEN"},
		Machine: &machine}, Router: router, Name: func(string) string { return "carrier" }}
	got, err := c.Start("ws-1")
	if err != nil || got == nil || got.State != "running" {
		t.Fatalf("%+v %v", got, err)
	}
	if seen.Call != "start" || deref(seen.Workspace) != "ws-1" || seen.Provider != "p" || len(seen.Secrets) != 0 {
		t.Fatalf("%+v", seen)
	}
	var record ProviderRecord
	if err := json.Unmarshal(seen.Record, &record); err != nil || record.ID != "p" || deref(record.Machine) != carrier {
		t.Fatalf("%s %v", seen.Record, err)
	}
	// Its machine's refusal is the call's, in its words.
	router.asking = func(string, string, json.RawMessage) json.RawMessage {
		words := "It answered with HTTP 401."
		return rawOf(wire.ProviderCarried{Error: &words})
	}
	if _, err := c.List(); err == nil || err.Error() != "It answered with HTTP 401." {
		t.Fatalf("%v", err)
	}
	// Its machine offline: said, and not asked.
	router.setOnline(carrier, false)
	before := len(router.asks())
	if _, err := c.Stop("ws-1"); err == nil || !strings.Contains(err.Error(), "carrier, which carries it, is offline") {
		t.Fatalf("%v", err)
	}
	if len(router.asks()) != before {
		t.Fatal("an offline machine was asked")
	}
	// One made before machines carried them: added again.
	c.Record.Machine = nil
	if _, err := c.List(); err == nil || !strings.Contains(err.Error(), "add it again") {
		t.Fatalf("%v", err)
	}
}

// A provider is carried by the machine its add names, else by the caller's first online
// machine; never by another person's, nor an offline one. The list says which, and says when
// it is offline.
func TestAProviderIsCarriedByOneOfTheCallersMachines(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	s := summaryOf(t, h, id)
	if s.Machine == nil || string(*s.Machine) != carrier || deref(s.MachineName) != "carrier" || s.MachineOffline != nil {
		t.Fatalf("%+v", s)
	}
	h.router.setOnline(carrier, false)
	if s := summaryOf(t, h, id); s.MachineOffline == nil || !*s.MachineOffline {
		t.Fatalf("%+v", s)
	}
	_, err := h.call(MethodProvidersAdd, map[string]any{"name": "Second", "kind": "commands",
		"commands": map[string]any{"preset": "doctl"}})
	if f := failureOf(err); f == nil || !strings.Contains(f.Message, "None of yours is online") {
		t.Fatalf("%v", err)
	}
	_, err = h.call(MethodProvidersAdd, map[string]any{"name": "Second", "kind": "commands", "machine": devbox,
		"commands": map[string]any{"preset": "doctl"}})
	if f := failureOf(err); f == nil || !strings.Contains(f.Message, "devbox is offline") {
		t.Fatalf("%v", err)
	}
	h.enroll("theirs01", "theirs")
	h.router.setOnline("theirs01", true)
	h.providers.hooks.OwnerOf = func(host string) string {
		if host == "theirs01" {
			return "kim"
		}
		return ""
	}
	_, err = h.call(MethodProvidersAdd, map[string]any{"name": "Second", "kind": "commands", "machine": "theirs01",
		"commands": map[string]any{"preset": "doctl"}})
	if f := failureOf(err); f == nil || !strings.Contains(f.Message, "No machine of yours") {
		t.Fatalf("%v", err)
	}
}

// A removed provider is forgotten on its machine, which deletes its secrets (#3398).
func TestARemovedProviderIsForgottenOnItsMachine(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	h.must(MethodProvidersRemove, map[string]string{"id": id})
	if !eventually(t, func() bool {
		for _, a := range h.router.asks() {
			if a.host == carrier && a.method == wire.CallProvidersForget.Name && strings.Contains(string(a.params), id) {
				return true
			}
		}
		return false
	}) {
		t.Fatalf("%v", h.router.asks())
	}
}

// Its secrets go to its machine once, and are in no record of the control plane's; an
// update that leaves them out keeps their names (#3398).
func TestAProvidersSecretsGoToItsMachineAndNowhereElse(t *testing.T) {
	h := newHarness(t)
	id := h.add()
	listed, _ := h.store.List(context.Background(), "")
	for _, key := range listed {
		object, _ := h.store.Get(context.Background(), key.Key)
		if strings.Contains(string(object.Data), "hunter2") {
			t.Errorf("%s holds the secret", key.Key)
		}
	}
	h.must(MethodProvidersUpdate, map[string]any{"id": id, "name": "DigitalOcean", "kind": "commands",
		"commands": map[string]any{"preset": "doctl", "tag": "other"}})
	s := summaryOf(t, h, id)
	if !s.Secrets["DIGITALOCEAN_TOKEN"] {
		t.Fatalf("%+v", s.Secrets)
	}
	var record ProviderRecord
	object, _ := h.store.Get(context.Background(), ProviderKey(id))
	json.Unmarshal(object.Data, &record)
	if deref(record.Machine) != carrier {
		t.Fatalf("%+v", record)
	}
	// Moved to another machine, its secrets must be given again: the old one keeps them.
	h.router.setOnline(devbox, true)
	_, err := h.call(MethodProvidersUpdate, map[string]any{"id": id, "name": "DigitalOcean", "kind": "commands",
		"machine": devbox, "commands": map[string]any{"preset": "doctl"}})
	if f := failureOf(err); f == nil || !strings.Contains(f.Message, "Give its DIGITALOCEAN_TOKEN again") {
		t.Fatalf("%v", err)
	}
}

func summaryOf(t *testing.T, h *harness, id string) ProviderSummary {
	t.Helper()
	for _, s := range h.providers.Summaries() {
		if string(s.ID) == id {
			return s
		}
	}
	t.Fatalf("no provider %s", id)
	return ProviderSummary{}
}
