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
	"github.com/alexec/agents/Go/wire"
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
// reason, shown only to the person who made it. The rows are kept in the store too
// (#4747), at FailedMakesPrefix, so a restart or a redeploy does not lose the reason.
type failedMake struct {
	info   MachineInfo
	person string
}

// FailedMakesPrefix is where each provider's failed makes are kept: one record a provider,
// at most keptFailedMakes rows, the newest last.
const FailedMakesPrefix = "v1/failed-makes/"

// failedMakesKey is a provider's record of failed makes.
func failedMakesKey(provider string) string {
	return FailedMakesPrefix + url.PathEscape(provider) + ".json"
}

// keptFailedMake is a failed make as the store keeps it.
type keptFailedMake struct {
	Name   string `json:"name"`
	Reason string `json:"reason"`
	Person string `json:"person,omitempty"`
}

func failedRow(name, person, reason string) failedMake {
	return failedMake{info: MachineInfo{ID: "failed-" + name, Name: name, State: "failed", Reason: &reason}, person: person}
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
	taken := p.takenNames(provider)
	name := ""
	err := p.changeChoices(person, func(c *machineNames) {
		n := freeNumber(taken, c.Next)
		c.Next = n + 1
		name = fmt.Sprintf("machine-%d", n)
	})
	if err != nil {
		return "", err
	}
	return name, nil
}

// peekName is the name nextName would give, without keeping it: what the New Machine
// sheet fills in (#4634).
func (p *Providers) peekName(person, provider string) string {
	return fmt.Sprintf("machine-%d", freeNumber(p.takenNames(provider), p.choices(person).Next))
}

// freeNumber is the first n, from next, whose machine-n is not taken.
func freeNumber(taken map[string]bool, next int) int {
	n := max(next, 1)
	for taken[fmt.Sprintf("machine-%d", n)] {
		n++
	}
	return n
}

// usedName keeps a machine-N that a make was given by name, as the New Machine sheet
// gives the one peekName filled in, so the counter never gives that number again.
func (p *Providers) usedName(person, name string) {
	var n int
	if _, err := fmt.Sscanf(name, "machine-%d", &n); err != nil || fmt.Sprintf("machine-%d", n) != name {
		return
	}
	if p.choices(person).Next > n {
		return
	}
	err := p.changeChoices(person, func(c *machineNames) { c.Next = max(c.Next, n+1) })
	if err != nil {
		p.log("workspace: could not keep the name " + name + ": " + errorWords(err))
	}
}

// newMachineForm is providers/options (#4634): the provider's New Machine form, with the
// values and the name New Machine would make it with. With no id, the default provider.
func (p *Providers) newMachineForm(person, id string) (any, error) {
	if id == "" {
		if id = p.defaultProvider(person); id == "" {
			return nil, invalid("There is no machine provider you may make machines with. Add one in Settings ▸ Machine Providers.")
		}
	}
	schema, err := p.providerCall(id, func(c Provider) (any, error) { return c.Options() })
	if err != nil {
		return nil, err
	}
	name := p.peekName(person, id)
	provider := wire.ProviderID(id)
	return ProviderOptions{Schema: rawOf(schema), ID: &provider, Values: jsonValue(p.formValues(person, id)), Name: &name}, nil
}

// formValues is what New Machine makes with on the provider: the options the person made a
// machine with last, over the form's defaults, keeping only the fields the form still has.
func (p *Providers) formValues(person, id string) map[string]any {
	values := p.defaultOptions(id)
	last, _ := p.lastOptions(person, id).(map[string]any)
	if len(last) == 0 {
		return values
	}
	schema, err := p.providerCall(id, func(c Provider) (any, error) { return c.Options() })
	if err != nil {
		return values
	}
	form, _ := valueOf(rawOf(schema)).(map[string]any)
	properties, _ := form["properties"].(map[string]any)
	for key, v := range last {
		if _, ok := properties[key]; ok {
			values[key] = v
		}
	}
	return values
}

// takenNames is every host's name and every workspace's name on the provider, in lower case.
func (p *Providers) takenNames(provider string) map[string]bool {
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
	return taken
}

// loadFailed reads the provider's failed makes back from the store, the newest last.
func (p *Providers) loadFailed(provider string) {
	object, err := p.store.Get(context.Background(), failedMakesKey(provider))
	if err != nil || object == nil {
		return
	}
	var kept []keptFailedMake
	if json.Unmarshal(object.Data, &kept) != nil {
		return
	}
	if len(kept) > keptFailedMakes {
		kept = kept[len(kept)-keptFailedMakes:]
	}
	rows := make([]failedMake, 0, len(kept))
	for _, k := range kept {
		rows = append(rows, failedRow(k.Name, k.Person, k.Reason))
	}
	p.mu.Lock()
	p.failedMakes[provider] = rows
	p.mu.Unlock()
}

// keepFailed adds a failed make to the provider's record in the store, the oldest gone
// past keptFailedMakes, again when another copy wrote first, and returns the rows kept.
// Another copy's rows come in too, as the record holds them.
func (p *Providers) keepFailed(provider string, row keptFailedMake) ([]keptFailedMake, error) {
	key := failedMakesKey(provider)
	ctx := context.Background()
	for range 5 {
		var kept []keptFailedMake
		when := store.Absent
		object, err := p.store.Get(ctx, key)
		if err != nil {
			return nil, err
		}
		if object != nil {
			_ = json.Unmarshal(object.Data, &kept)
			when = store.Matching(object.ETag)
		}
		kept = append(kept, row)
		if len(kept) > keptFailedMakes {
			kept = kept[len(kept)-keptFailedMakes:]
		}
		data, _ := json.Marshal(kept)
		if _, err := p.store.Put(ctx, key, data, when); err != nil {
			var conflict *store.ConflictError
			if errors.As(err, &conflict) {
				continue
			}
			return nil, err
		}
		return kept, nil
	}
	return nil, errors.New("another copy kept changing the record")
}

// failed keeps a make that failed as a row of the provider's, the oldest gone past
// keptFailedMakes: in the store, so a restart keeps it (#4747), and here. When the store
// can't take it, the row is kept here only.
func (p *Providers) failed(provider, name, person, reason string) {
	row := keptFailedMake{Name: name, Reason: reason, Person: person}
	kept, err := p.keepFailed(provider, row)
	if err != nil {
		p.log("workspace: could not keep the failed make " + name + " of " + provider + ": " + errorWords(err))
		p.mu.Lock()
		for _, f := range p.failedMakes[provider] {
			kept = append(kept, keptFailedMake{Name: f.info.Name, Reason: deref(f.info.Reason), Person: f.person})
		}
		p.mu.Unlock()
		kept = append(kept, row)
		if len(kept) > keptFailedMakes {
			kept = kept[len(kept)-keptFailedMakes:]
		}
	}
	rows := make([]failedMake, 0, len(kept))
	for _, k := range kept {
		rows = append(rows, failedRow(k.Name, k.Person, k.Reason))
	}
	p.mu.Lock()
	p.failedMakes[provider] = rows
	p.mu.Unlock()
	p.changed()
}

// forgetFailed deletes a provider's failed makes, when the provider goes.
func (p *Providers) forgetFailed(provider string) {
	p.mu.Lock()
	delete(p.failedMakes, provider)
	p.mu.Unlock()
	if err := p.store.Delete(context.Background(), failedMakesKey(provider)); err != nil {
		p.log("workspace: could not forget the failed makes of " + provider + ": " + errorWords(err))
	}
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
