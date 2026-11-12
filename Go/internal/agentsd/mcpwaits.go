package agentsd

import (
	"encoding/json"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// A wait on a server's event (#577), as the Swift host has it: a subscription the wait
// holds, as a trigger's is, checked against what the folder's servers offer, `where` as
// its arguments. It is matched by the subscription that raised the event, never by its
// details; the subscription goes when nothing holds it.

// mcpTriggerOfWire is a wait's server event as a trigger.
func mcpTriggerOfWire(t wire.MCPEventTrigger) mcpTrigger {
	args := t.Arguments
	if args == nil {
		args = map[string]json.RawMessage{}
	}
	return mcpTrigger{event: t.Event, servers: t.Servers, arguments: args}
}

func (t mcpTrigger) wire() wire.MCPEventTrigger {
	args := t.arguments
	if args == nil {
		args = map[string]json.RawMessage{}
	}
	return wire.MCPEventTrigger{Event: t.event, Servers: t.servers, Arguments: args}
}

// waitServerLabel is WaitServerEvent.label: "pr.merged on ci (repo alexec/Agents)".
func waitServerLabel(se wire.WaitServerEvent) string {
	from := se.Servers
	if len(from) == 0 {
		from = se.Trigger.Servers
	}
	keys := make([]string, 0, len(se.Trigger.Arguments))
	for k := range se.Trigger.Arguments {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		parts = append(parts, k+" "+jsonWords(se.Trigger.Arguments[k]))
	}
	s := se.Trigger.Event
	if len(from) > 0 {
		s += " on " + strings.Join(from, " or ")
	}
	if len(parts) > 0 {
		s += " (" + strings.Join(parts, ", ") + ")"
	}
	return s
}

func subscribedWords(events []wire.WaitServerEvent) string {
	var made []string
	for _, e := range events {
		if len(e.Servers) > 0 {
			made = append(made, waitServerLabel(e))
		}
	}
	if len(made) == 0 {
		return ""
	}
	return "Subscribed to " + strings.Join(made, " and ") + ". "
}

func notOfferedWords(name string, offers map[string][]string) string {
	words := "No server here offers " + name + "."
	servers := make([]string, 0, len(offers))
	for s := range offers {
		servers = append(servers, s)
	}
	sort.Strings(servers)
	for _, s := range servers {
		if len(offers[s]) == 0 {
			words += " " + s + " offers no events."
		} else {
			words += " " + s + " offers " + strings.Join(offers[s], ", ") + "."
		}
	}
	if len(offers) == 0 {
		words += " This folder has no MCP server that offers events."
	}
	if g := closestEvent(name); g != "" {
		words += " Did you mean " + g + "?"
	}
	return words
}

func serversMayComeBackWords(name string, why []string) string {
	return name + " could not be checked: " + strings.Join(why, " ") + " The wait is kept, and subscribes when " +
		"the server can be asked; if it never offers " + name + ", this wait never ends. "
}

// mcpWaitArguments is `where`'s values as a server's arguments: text, or the number or
// true/false the server's schema asks for, since `where` comes as text. A list is a list.
func mcpWaitArguments(filters map[string][]string, schema json.RawMessage) map[string]json.RawMessage {
	var s struct {
		Properties map[string]json.RawMessage `json:"properties"`
	}
	json.Unmarshal(schema, &s)
	typesOf := func(p json.RawMessage) []string {
		var x struct {
			Type json.RawMessage `json:"type"`
		}
		json.Unmarshal(p, &x)
		var one string
		var many []string
		if json.Unmarshal(x.Type, &one) == nil {
			return []string{one}
		}
		json.Unmarshal(x.Type, &many)
		return many
	}
	typed := func(text string, p json.RawMessage) json.RawMessage {
		types := typesOf(p)
		if contains(types, "integer") || contains(types, "number") {
			if n, err := strconv.Atoi(text); err == nil {
				return mustRaw(n)
			}
		}
		if contains(types, "number") {
			if f, err := strconv.ParseFloat(text, 64); err == nil {
				return mustRaw(f)
			}
		}
		if contains(types, "boolean") && (text == "true" || text == "false") {
			return mustRaw(text == "true")
		}
		return mustRaw(text)
	}
	out := map[string]json.RawMessage{}
	for k, vs := range filters {
		p := s.Properties[k]
		if len(vs) == 1 && !contains(typesOf(p), "array") {
			out[k] = typed(vs[0], p)
			continue
		}
		var items struct {
			Items json.RawMessage `json:"items"`
		}
		json.Unmarshal(p, &items)
		list := make([]json.RawMessage, 0, len(vs))
		for _, v := range vs {
			list = append(list, typed(v, items.Items))
		}
		out[k] = mustRaw(list)
	}
	return out
}

// namedEvents are the server events about one thing (#3797): a wait on one names that
// thing, by the keys that say which, or sets any: true. A wait that does neither woke on
// every PR that merged in the repo. Workflow triggers are not checked: a trigger on every
// merge is the usual one, written in a file a person reads.
var namedEvents = map[string]struct {
	thing, every string
	keys         []string
}{
	"pr.merged":       {"PR", "every PR in the repo", prNamingKeys},
	"pr.closed":       {"PR", "every PR in the repo", prNamingKeys},
	"pr.conflicted":   {"PR", "every PR in the repo", prNamingKeys},
	"pr.commented":    {"PR", "every PR in the repo", prNamingKeys},
	"pr.reviewed":     {"PR", "every PR in the repo", prNamingKeys},
	"pr.labelled":     {"PR", "every PR in the repo", prNamingKeys},
	"pr.unlabelled":   {"PR", "every PR in the repo", prNamingKeys},
	"review.posted":   {"PR", "every PR in the repo", prNamingKeys},
	"review.comment":  {"PR", "every PR in the repo", prNamingKeys},
	"checks.failed":   {"PR", "every PR in the repo", prNamingKeys},
	"checks.passed":   {"PR", "every PR in the repo", prNamingKeys},
	"run.completed":   {"run", "every run in the repo", []string{"run", "branch", "workflow", "pipeline"}},
	"issue.closed":    {"issue", "every issue in the repo", []string{"issue", "label"}},
	"issue.commented": {"issue", "every issue in the repo", []string{"issue", "label"}},
	"issue.labelled":  {"issue", "every issue in the repo", []string{"issue", "label"}},
}

var prNamingKeys = []string{"pr", "branch", "fixes", "mine"}

// unnamedWaitWords is why a wait on a server's event that names nothing is refused, or
// "". Only a server whose event offers any is held to it: one that does not yet (a forge
// added since) waits as before.
func unnamedWaitWords(name string, given map[string][]string, schema json.RawMessage) string {
	named, ok := namedEvents[name]
	if !ok {
		return ""
	}
	offers := propertiesOf(schema)
	if !offers["any"] {
		return ""
	}
	if all := given["any"]; len(all) == 1 && all[0] == "true" {
		return ""
	}
	var keys []string
	for _, k := range named.keys {
		if !offers[k] {
			continue
		}
		if v, set := given[k]; set && !(k == "mine" && (len(v) != 1 || v[0] != "true")) {
			return ""
		}
		keys = append(keys, "`"+k+"`")
	}
	return "Name the " + named.thing + " (" + orList(keys) + "), or set `any: true` to wake on " + named.every + "."
}

// propertiesOf is the keys a server's event takes, from its inputSchema.
func propertiesOf(schema json.RawMessage) map[string]bool {
	var s struct {
		Properties map[string]json.RawMessage `json:"properties"`
	}
	json.Unmarshal(schema, &s)
	out := map[string]bool{}
	for k := range s.Properties {
		out[k] = true
	}
	return out
}

// orList is "a, b or c".
func orList(items []string) string {
	if len(items) <= 1 {
		return strings.Join(items, "")
	}
	return strings.Join(items[:len(items)-1], ", ") + " or " + items[len(items)-1]
}

type offeredEvents struct {
	server eventServer
	events []mcpEventDef
}

// mcpOfferedEvents is each of these servers' events as listed now, only those it may
// raise, or why it could not be asked.
func (d *Daemon) mcpOfferedEvents(names []string, folder string) (map[string]offeredEvents, []string) {
	secrets := d.secrets()
	offered := map[string]offeredEvents{}
	var mayComeBack []string
	for _, name := range names {
		s, problem := d.eventServerNamed(name, folder, secrets)
		switch problem {
		case "":
			listing := d.mcpEventListing(s)
			if listing.offers {
				var events []mcpEventDef
				for _, e := range listing.events {
					if isServerEventName(e.Name) {
						events = append(events, e)
					}
				}
				offered[name] = offeredEvents{s, events}
			} else if listing.failure != nil {
				mayComeBack = append(mayComeBack, mcpEventsWords(listing.failure, name))
			}
		case "waiting":
			mayComeBack = append(mayComeBack, name+" is waiting for approval in this folder's Connectors.")
		}
	}
	return offered, mayComeBack
}

// mcpWaitCheck is what a wait's servers' events come to when it is made.
type mcpWaitCheck struct {
	events  []wire.WaitServerEvent
	warning string
	// fresh are records of subscriptions it would make that nothing holds now: cleared,
	// so the subscription starts from now rather than from an old wait's cursor.
	fresh []string
}

// checkMCPWait checks a wait's servers' events as a trigger's are checked. Refused, with
// the sentence, when no server offers a name or its arguments fit none; a server that
// could not be asked is a warning.
func (d *Daemon) checkMCPWait(names []string, filters map[string][]string, folder string) (mcpWaitCheck, error) {
	var check mcpWaitCheck
	if len(names) == 0 {
		return check, nil
	}
	given := map[string][]string{}
	for k, v := range filters {
		given[k] = v
	}
	narrowed, isNarrowed := given[mcpServerKey]
	delete(given, mcpServerKey)
	here := d.mcpServerNames(folder)
	if isNarrowed {
		for _, n := range narrowed {
			if !contains(here, n) {
				msg := n + " is not an MCP server here."
				if len(here) > 0 {
					sorted := append([]string(nil), here...)
					sort.Strings(sorted)
					msg += " Servers here: " + strings.Join(sorted, ", ") + "."
				}
				return check, eventRefused(msg + " Nothing is waiting.")
			}
		}
	}
	asked := here
	if isNarrowed {
		asked = narrowed
	}
	asked = append([]string(nil), asked...)
	sort.Strings(asked)
	offered, mayComeBack := d.mcpOfferedEvents(asked, folder)
	servers := make([]string, 0, len(offered))
	for s := range offered {
		servers = append(servers, s)
	}
	sort.Strings(servers)
	var servedBy []string
	if isNarrowed {
		servedBy = narrowed
	}
	// One where for several events (#3797): each event takes only the keys it offers, so a
	// lead names its children's issues for issue.closed and their fixes for pr.merged in one
	// wait. A key none of them offers still goes to each, which says what it takes.
	takenBySome := map[string]bool{}
	for _, name := range names {
		probe := mcpTrigger{event: name, servers: servedBy}
		for _, server := range servers {
			for _, def := range offered[server].events {
				if probe.covers(def.Name) && def.offersPoll() {
					for k := range propertiesOf(def.InputSchema) {
						takenBySome[k] = true
					}
				}
			}
		}
	}
	var warnings, unnamed []string
	for _, name := range names {
		probe := mcpTrigger{event: name, servers: servedBy}
		var on []string
		var arguments map[string]json.RawMessage
		var problems []string
		var keys []string
		for _, server := range servers {
			for _, def := range offered[server].events {
				if !probe.covers(def.Name) || !def.offersPoll() {
					continue
				}
				own := given
				if len(names) > 1 {
					own = map[string][]string{}
					offers := propertiesOf(def.InputSchema)
					for k, v := range given {
						if offers[k] || !takenBySome[k] {
							own[k] = v
						}
					}
				}
				typed := mcpWaitArguments(own, def.InputSchema)
				if len(def.InputSchema) > 0 {
					if p := jsonSchemaProblem(mustRaw(typed), def.InputSchema, server+"'s "+def.Name); p != "" {
						problems = append(problems, p)
						continue
					}
				}
				if p := unnamedWaitWords(def.Name, own, def.InputSchema); p != "" {
					unnamed = append(unnamed, server+"'s "+def.Name+": "+p)
					continue
				}
				if arguments == nil {
					arguments = typed
				}
				if !contains(on, server) {
					on = append(on, server)
				}
				key := mcpTrigger{event: def.Name, servers: servedBy, arguments: arguments}.subscriptionKey(server)
				keys = append(keys, mcpRecordKey(folder, key))
			}
		}
		if arguments == nil {
			arguments = mcpWaitArguments(given, nil)
		}
		trigger := mcpTrigger{event: name, servers: servedBy, arguments: arguments}
		switch {
		case len(on) > 0:
			check.events = append(check.events, wire.WaitServerEvent{Trigger: trigger.wire(), Servers: on})
			d.mcpEvMu.Lock()
			for _, k := range keys {
				if d.mcpSubs[k] == nil {
					check.fresh = append(check.fresh, k)
				}
			}
			d.mcpEvMu.Unlock()
		case len(problems) > 0:
			return check, eventRefused(strings.Join(problems, " ") + " Nothing is waiting.")
		case len(unnamed) > 0:
			return mcpWaitCheck{}, eventRefused(strings.Join(unnamed, " ") + " Nothing is waiting.")
		case len(mayComeBack) > 0:
			check.events = append(check.events, wire.WaitServerEvent{Trigger: trigger.wire(), Servers: []string{}})
			warnings = append(warnings, serversMayComeBackWords(name, mayComeBack))
		default:
			offers := map[string][]string{}
			for s, o := range offered {
				var n []string
				for _, e := range o.events {
					n = append(n, e.Name)
				}
				sort.Strings(n)
				offers[s] = n
			}
			return check, eventRefused(notOfferedWords(name, offers) + " Nothing is waiting.")
		}
	}
	// One server's event that names nothing refuses the whole wait, not only that server's
	// subscription: a wait the others took would never wake for it.
	if len(unnamed) > 0 {
		return mcpWaitCheck{}, eventRefused(strings.Join(unnamed, " ") + " Nothing is waiting.")
	}
	check.warning = strings.Join(warnings, "")
	return check, nil
}

// startMCPWait starts a new wait's subscriptions from now: an old wait's record, kept a
// day, is not where this one starts. A record polled less than waitLooksBack ago is kept
// (#4716): its cursor brings what happened since the last wait stopped, such as a pull
// request that merged in the seconds between two waits, which a first poll never raises.
// Then the next look subscribes.
func (d *Daemon) startMCPWait(check mcpWaitCheck) {
	if len(check.events) == 0 {
		return
	}
	d.mcpEvMu.Lock()
	cleared := false
	recs := d.mcpRecordsLocked()
	recent := time.Now().Add(-waitLooksBack)
	for _, id := range check.fresh {
		r := recs.Subscriptions[id]
		if r != nil && r.Cursor != nil && r.LastPolledAt != nil && !r.LastPolledAt.Time().Before(recent) {
			continue
		}
		if d.mcpSubs[id] == nil && r != nil {
			delete(recs.Subscriptions, id)
			cleared = true
		}
	}
	if cleared {
		d.saveMCPRecordsLocked()
	}
	d.mcpEvMu.Unlock()
	d.kickMCPEvents()
}

// waitingOnServers is every open wait's server events, by agent, for the subscriptions.
type serverWait struct {
	agent  wire.UUID
	wait   wire.UUID
	folder string
	events []wire.WaitServerEvent
}

func (d *Daemon) serverWaits() []serverWait {
	var out []serverWait
	for _, a := range d.Store.LiveAgents() {
		w := a.EventWait
		if w == nil || w.Ending != nil || len(w.ServerEvents) == 0 {
			continue
		}
		out = append(out, serverWait{agent: a.ID, wait: w.ID, folder: folderPath(&a), events: w.ServerEvents})
	}
	sort.Slice(out, func(i, j int) bool { return out[i].agent < out[j].agent })
	return out
}
