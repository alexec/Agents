package providers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane/store"
)

// New Machine with no questions (#3972): a make with no provider, name or options takes
// the person's default provider, the name machine-N and the provider's default options.

// MachineNamesPrefix is where each person's machine-N counter is kept.
const MachineNamesPrefix = "v1/machine-names/"

// machineNamesKey is a person's counter; the admin who signs in with no person has one too.
func machineNamesKey(person string) string {
	if person == "" {
		person = "-"
	}
	return MachineNamesPrefix + url.PathEscape(person) + ".json"
}

// machineNames is v1/machine-names/<person>.json: the number the person's next machine-N
// takes. It only goes up, so a number is never used again, also after its machine is
// deleted or renamed.
type machineNames struct {
	Next int `json:"next"`
}

// keptFailedMakes is how many makes that failed a provider keeps as rows, newest last.
const keptFailedMakes = 5

// failedMake is a make that failed (#3972): a row in the failed state with the provider's
// reason, shown only to the person who made it, until the control plane restarts.
type failedMake struct {
	info   MachineInfo
	person string
}

// defaultProvider is the person's default provider: the first one added that they may
// make machines from. One added before addedAt was kept comes first, by name.
func (p *Providers) defaultProvider(person string) string {
	p.mu.Lock()
	held := make([]ProviderRecord, 0, len(p.providers))
	for _, h := range p.providers {
		held = append(held, h.record)
	}
	p.mu.Unlock()
	var mayMake []ProviderRecord
	for _, r := range held {
		if (r.Forgotten == nil || !*r.Forgotten) && contains(r.Capabilities, "create") && p.sees(person, r) && p.MayUse(person, r) {
			mayMake = append(mayMake, r)
		}
	}
	sort.Slice(mayMake, func(i, j int) bool {
		a, b := mayMake[i], mayMake[j]
		if (a.AddedAt == nil) != (b.AddedAt == nil) {
			return a.AddedAt == nil
		}
		if a.AddedAt != nil && !a.AddedAt.Equal(b.AddedAt.Time) {
			return a.AddedAt.Before(b.AddedAt.Time)
		}
		if a.Name != b.Name {
			return a.Name < b.Name
		}
		return a.ID < b.ID
	})
	if len(mayMake) == 0 {
		return ""
	}
	return mayMake[0].ID
}

// defaultOptions is the provider's New Machine form filled with its defaults: each field's
// `default`, or else the first of its `enum`, as the Mac's form shows it.
func (p *Providers) defaultOptions(id string) map[string]any {
	chosen := map[string]any{}
	schema, err := p.providerCall(id, func(c Provider) (any, error) { return c.Options() })
	if err != nil {
		return chosen
	}
	form, _ := valueOf(rawOf(schema)).(map[string]any)
	properties, _ := form["properties"].(map[string]any)
	for key, property := range properties {
		field, _ := property.(map[string]any)
		if d, ok := field["default"]; ok {
			chosen[key] = d
		} else if choices, _ := field["enum"].([]any); len(choices) > 0 {
			chosen[key] = choices[0]
		}
	}
	return chosen
}

// nextName is the person's next machine-N that neither the provider nor a host has yet,
// with the counter moved past it.
func (p *Providers) nextName(person, provider string) (string, error) {
	taken := map[string]bool{}
	for _, h := range p.records.Hosts() {
		taken[strings.ToLower(h.Name)] = true
	}
	p.mu.Lock()
	if l := p.listed[provider]; l != nil {
		for _, w := range l.workspaces {
			taken[strings.ToLower(w.Name)] = true
		}
	}
	p.mu.Unlock()
	key := machineNamesKey(person)
	ctx := context.Background()
	for range 5 {
		names := machineNames{Next: 1}
		when := store.Absent
		object, err := p.store.Get(ctx, key)
		if err != nil {
			return "", err
		}
		if object != nil {
			if err := json.Unmarshal(object.Data, &names); err != nil {
				return "", err
			}
			when = store.Matching(object.ETag)
		}
		n := max(names.Next, 1)
		for taken[fmt.Sprintf("machine-%d", n)] {
			n++
		}
		data, _ := json.Marshal(machineNames{Next: n + 1})
		if _, err := p.store.Put(ctx, key, data, when); err != nil {
			var conflict *store.ConflictError
			if errors.As(err, &conflict) {
				continue
			}
			return "", err
		}
		return fmt.Sprintf("machine-%d", n), nil
	}
	return "", fail(CodeInternalError, "Could not choose a name for the machine. Try again.")
}

// failed keeps a make that failed as a row of the provider's, the oldest gone past
// keptFailedMakes.
func (p *Providers) failed(provider, name, person, reason string) {
	row := failedMake{info: MachineInfo{ID: "failed-" + name, Name: name, State: "failed", Reason: &reason}, person: person}
	p.mu.Lock()
	kept := append(p.failedMakes[provider], row)
	if len(kept) > keptFailedMakes {
		kept = kept[len(kept)-keptFailedMakes:]
	}
	p.failedMakes[provider] = kept
	p.mu.Unlock()
	p.changed()
}

// failedOwner is who made the failed row, and whether it is one.
func (p *Providers) failedOwner(provider, workspace string) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, f := range p.failedMakes[provider] {
		if f.info.ID == workspace {
			return f.person, true
		}
	}
	return "", false
}
