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
// takes, and what New Machine makes it with (#3979). Next only goes up, so a number is
// never used again, also after its machine is deleted or renamed.
type machineNames struct {
	Next int `json:"next"`
	// The provider New Machine uses: the one made on last, or chosen with Make Default.
	Default string `json:"default,omitempty"`
	// The options each provider made a machine with last, by provider id.
	Options map[string]json.RawMessage `json:"options,omitempty"`
}

// keptFailedMakes is how many makes that failed a provider keeps as rows, newest last.
const keptFailedMakes = 5

// failedMake is a make that failed (#3972): a row in the failed state with the provider's
// reason, shown only to the person who made it, until the control plane restarts.
type failedMake struct {
	info   MachineInfo
	person string
}

// defaultProvider is the person's default provider: the one they made a machine on last or
// chose with Make Default (#3979), or else the first one added that they may make machines
// from. One added before addedAt was kept comes first, by name.
func (p *Providers) defaultProvider(person string) string {
	p.mu.Lock()
	held := make([]ProviderRecord, 0, len(p.providers))
	for _, h := range p.providers {
		held = append(held, h.record)
	}
	p.mu.Unlock()
	var mayMake []ProviderRecord
	for _, r := range held {
		if p.mayMakeOn(person, r) {
			mayMake = append(mayMake, r)
		}
	}
	if chosen := p.choices(person).Default; chosen != "" {
		for _, r := range mayMake {
			if r.ID == chosen {
				return chosen
			}
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

// mayMakeOn says the person may make machines on the provider.
func (p *Providers) mayMakeOn(person string, r ProviderRecord) bool {
	return (r.Forgotten == nil || !*r.Forgotten) && contains(r.Capabilities, "create") && p.sees(person, r) && p.MayUse(person, r)
}

// makeDefault is providers/makeDefault (#3979): New Machine uses the provider for the
// person until they make a machine on another one.
func (p *Providers) makeDefault(person, id string) error {
	r, ok := p.record(id)
	if !ok || !p.sees(person, r) {
		return invalid("There is no such provider.")
	}
	if !p.mayMakeOn(person, r) {
		return invalid("%s can’t make machines for you.", r.Name)
	}
	if err := p.changeChoices(person, func(c *machineNames) { c.Default = id }); err != nil {
		return err
	}
	p.changed()
	return nil
}

// lastOptions is what the person made a machine on the provider with last, or nil.
func (p *Providers) lastOptions(person, id string) any {
	raw, ok := p.choices(person).Options[id]
	if !ok {
		return nil
	}
	var v any
	if json.Unmarshal(raw, &v) != nil {
		return nil
	}
	return v
}

// madeOn keeps the provider and the options a make used (#3979), for the next New Machine.
func (p *Providers) madeOn(person, id string, options json.RawMessage) {
	err := p.changeChoices(person, func(c *machineNames) {
		c.Default = id
		if len(options) > 0 && string(options) != "null" {
			if c.Options == nil {
				c.Options = map[string]json.RawMessage{}
			}
			c.Options[id] = options
		}
	})
	if err != nil {
		p.log("workspace: could not keep the options " + id + " made a machine with: " + errorWords(err))
	}
}

// choices is the person's v1/machine-names record; empty when there is none or it can't be read.
func (p *Providers) choices(person string) machineNames {
	names := machineNames{Next: 1}
	object, err := p.store.Get(context.Background(), machineNamesKey(person))
	if err != nil || object == nil {
		return names
	}
	_ = json.Unmarshal(object.Data, &names)
	return names
}

// changeChoices changes the person's v1/machine-names record, again when another write got there first.
func (p *Providers) changeChoices(person string, change func(*machineNames)) error {
	key := machineNamesKey(person)
	ctx := context.Background()
	for range 5 {
		names := machineNames{Next: 1}
		when := store.Absent
		object, err := p.store.Get(ctx, key)
		if err != nil {
			return err
		}
		if object != nil {
			if err := json.Unmarshal(object.Data, &names); err != nil {
				return err
			}
			when = store.Matching(object.ETag)
		}
		change(&names)
		data, _ := json.Marshal(names)
		if _, err := p.store.Put(ctx, key, data, when); err != nil {
			var conflict *store.ConflictError
			if errors.As(err, &conflict) {
				continue
			}
			return err
		}
		return nil
	}
	return fail(CodeInternalError, "Could not keep what New Machine makes. Try again.")
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
	name := ""
	err := p.changeChoices(person, func(c *machineNames) {
		n := max(c.Next, 1)
		for taken[fmt.Sprintf("machine-%d", n)] {
			n++
		}
		c.Next = n + 1
		name = fmt.Sprintf("machine-%d", n)
	})
	if err != nil {
		return "", err
	}
	return name, nil
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
