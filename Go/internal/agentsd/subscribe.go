package agentsd

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/repoalias"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// Subscriptions by provider, type, topic and subject, with debounce (#4730, spec
// 4724-event-bus, "Where agents and people use it"). A wait or a workflow trigger that
// names a provider, a topic or a subject matches on the event's envelope, and also hears
// the person's other machines: this machine sends it to the control plane as a
// subscription on the bus (bus/subscribe), which delivers the events that match it
// (bus/deliver, bus.go). One that names none of them means what it meant before: this
// folder's servers and the app, on this machine only.
//
// From another machine an event has its envelope only, so a pattern that is narrowed by
// `where` (the server's or the app's own keys) is not heard there: `subject` is the plain
// way to say "this thing" on every machine.
//
// debounce holds a burst of matches on one subject and type and delivers the last one,
// with how many came. It is done here, where the wait or the workflow is, so it covers this
// machine's own events too, which never come back from the bus. Best effort: a restart
// drops what is held.

const (
	debounceLeast = time.Second
	debounceMost  = time.Hour
	// debounceHeldMost bounds the bursts held at once; past it, an event goes at once.
	debounceHeldMost = 1_000
	// busSubscribeAfter gathers the changes of a moment into one bus/subscribe.
	busSubscribeAfter = 500 * time.Millisecond
)

var busProviderRule = regexp.MustCompile(`^[a-z0-9-]+(:[A-Za-z0-9_-]+)?$`)

// busFilter is what a wait or a trigger says of an event's envelope.
type busFilter struct {
	provider string
	topics   []string
	subject  *wire.Ref
	debounce time.Duration
}

// wide is whether it names the envelope, so it hears the bus too.
func (f busFilter) wide() bool { return f.provider != "" || len(f.topics) > 0 || f.subject != nil }

// envelopeMatches is whether every field it names is the event's.
func (f busFilter) envelopeMatches(e wire.Event) bool {
	if f.provider != "" && (e.Provider == nil || *e.Provider != f.provider) {
		return false
	}
	if len(f.topics) > 0 && (e.Topic == nil || !slices.ContainsFunc(f.topics, func(t string) bool { return sameTopic(e, t) })) {
		return false
	}
	// A repo whose owner moved is one repo by either name (#4957).
	if f.subject != nil && (e.Subject == nil || repoalias.Ref(*e.Subject).String() != repoalias.Ref(*f.subject).String()) {
		return false
	}
	return true
}

// sameTopic is whether the event's topic is t, by the repo's name now (#4957).
func sameTopic(e wire.Event, t string) bool {
	provider := ""
	if e.Provider != nil {
		provider = *e.Provider
	}
	return repoalias.SameRepo(provider, *e.Topic, t)
}

// busKeys are the keys a wait or a trigger takes for its filter, out of its settings.
var busKeys = map[string]bool{"provider": true, "topic": true, "subject": true, "debounce": true}

// readBusFilter reads the filter from its keys' values (one, or a list for topic), or says
// what is wrong.
func readBusFilter(values map[string][]string) (busFilter, string) {
	var f busFilter
	one := func(k string) (string, string) {
		vs := values[k]
		if len(vs) > 1 {
			return "", "`" + k + "` is one value, not a list."
		}
		if len(vs) == 0 {
			return "", ""
		}
		return strings.TrimSpace(vs[0]), ""
	}
	p, problem := one("provider")
	if problem != "" {
		return f, problem
	}
	if p != "" {
		p = strings.ToLower(p)
		if !busProviderRule.MatchString(p) {
			return f, "`provider` " + strconv.Quote(p) + " is not a provider: such as github, gitlab, jira, slack or agents."
		}
		f.provider = p
	}
	for _, t := range values["topic"] {
		if t = strings.ToLower(strings.TrimSpace(t)); t != "" && !contains(f.topics, t) {
			f.topics = append(f.topics, t)
		}
	}
	if len(f.topics) > 100 {
		return f, "`topic` takes at most 100 topics."
	}
	s, problem := one("subject")
	if problem != "" {
		return f, problem
	}
	if s != "" {
		r, err := wire.ParseRef(s)
		if err != nil {
			return f, "`subject` " + strconv.Quote(s) + " is not a ref: give the full form, provider:type:topic#id, such as github:pr:alexec/agents#4702."
		}
		if f.provider != "" && r.Provider != f.provider {
			return f, "`subject` " + r.String() + " is not of the provider " + f.provider + "."
		}
		f.subject = &r
	}
	dv, problem := one("debounce")
	if problem != "" {
		return f, problem
	}
	if dv != "" {
		dur, ok := parseDebounce(dv)
		if !ok {
			return f, "`debounce` " + strconv.Quote(dv) + " is not a time from 1s to 1h, such as 30s or 2m."
		}
		f.debounce = dur
	}
	return f, ""
}

// parseDebounce is "30s", "2m", "1h", or a number of seconds.
func parseDebounce(s string) (time.Duration, bool) {
	dur, err := time.ParseDuration(s)
	if err != nil {
		n, nerr := strconv.ParseFloat(s, 64)
		if nerr != nil {
			return 0, false
		}
		dur = time.Duration(n * float64(time.Second))
	}
	return dur, dur >= debounceLeast && dur <= debounceMost
}

// filterOfPattern and setFilter carry the filter on the wire's pattern.
func filterOfPattern(w wire.EventPattern) busFilter {
	f := busFilter{topics: w.Topics, subject: w.Subject}
	if w.Provider != nil {
		f.provider = *w.Provider
	}
	if w.Debounce != nil {
		f.debounce = time.Duration(*w.Debounce * float64(time.Second))
	}
	return f
}

func (f busFilter) setOn(w *wire.EventPattern) {
	if f.provider != "" {
		p := f.provider
		w.Provider = &p
	}
	if len(f.topics) > 0 {
		w.Topics = append([]string(nil), f.topics...)
	}
	if f.subject != nil {
		s := *f.subject
		w.Subject = &s
	}
	if f.debounce > 0 {
		secs := f.debounce.Seconds()
		w.Debounce = &secs
	}
}

// localWhere is what a forge's server here is asked for when the filter names a repo or a
// thing and `where` does not: so `subject: github:pr:alexec/agents#4702` hears this
// machine's own server for that pull request, not every one.
func (f busFilter) localWhere(given map[string][]string) map[string][]string {
	provider := f.provider
	if provider == "" && f.subject != nil {
		provider = f.subject.Provider
	}
	repoKey := "repo"
	switch provider {
	case "github", "forgejo", "bitbucket":
	case "gitlab":
		repoKey = "project"
	default:
		return given
	}
	out := map[string][]string{}
	for k, v := range given {
		out[k] = v
	}
	topic := ""
	if len(f.topics) == 1 {
		topic = f.topics[0]
	}
	if f.subject != nil {
		topic = f.subject.Topic
		item := ""
		switch f.subject.Type {
		case "pr", "mr":
			item = "pr"
		case "issue":
			item = "issue"
		}
		if _, set := out[item]; item != "" && !set {
			out[item] = []string{f.subject.ID}
		}
	}
	if _, set := out[repoKey]; topic != "" && !set {
		out[repoKey] = []string{topic}
	}
	return out
}

// fromBus is whether the bus delivered the event from another machine (toldBusDelivery).
func fromBus(e wire.Event) bool {
	_, ok := e.Details["bus_producer"]
	return ok
}

// hintWords is what an agent is told with every event (#4726): its ref and subject, and
// that it is a hint.
func hintWords(e wire.Event) string {
	if e.ID == nil {
		return ""
	}
	s := "Its ref is " + *e.ID
	about := "the thing it is about"
	if e.Subject != nil {
		about = e.Subject.String()
		s += ", about " + about
	}
	return s + ". An event is a hint, not the truth: read the state of " + about + " now before you act on it, and doing it twice must do no harm."
}

// burstWords says that a debounce held more than one.
func burstWords(count int, held time.Duration) string {
	if count <= 1 {
		return ""
	}
	return fmt.Sprintf("%d events like it came in %s; this is the last.", count, held.Round(time.Second))
}

// Debounce: one burst per owner, subject and type.

type debounceBook struct {
	debounceMu sync.Mutex
	bursts     map[string]*heldBurst
}

type heldBurst struct {
	last  wire.Event
	count int
}

// burstKey is the subject and the type of an event, for owner.
func burstKey(owner string, e wire.Event) string {
	subject := ""
	if e.Subject != nil {
		subject = e.Subject.String()
	} else if e.ID != nil {
		subject = *e.ID
	}
	return owner + "\n" + subject + "\n" + e.Name
}

// holdBurst holds e for wait; deliver is called once, wait after the first, with the last
// event and how many came. False when nothing is held (too many held): deliver now.
func (d *Daemon) holdBurst(owner string, wait time.Duration, e wire.Event, deliver func(last wire.Event, count int)) bool {
	key := burstKey(owner, e)
	d.debounceMu.Lock()
	defer d.debounceMu.Unlock()
	if b := d.bursts[key]; b != nil {
		b.last, b.count = copyEvent(e), b.count+1
		return true
	}
	if d.bursts == nil {
		d.bursts = map[string]*heldBurst{}
	}
	if len(d.bursts) >= debounceHeldMost {
		return false
	}
	d.bursts[key] = &heldBurst{last: copyEvent(e), count: 1}
	time.AfterFunc(wait, func() {
		d.debounceMu.Lock()
		b := d.bursts[key]
		delete(d.bursts, key)
		d.debounceMu.Unlock()
		if b != nil && d.ctx.Err() == nil {
			deliver(b.last, b.count)
		}
	})
	return true
}

// Bus subscriptions: every open wait's and every workflow trigger's wide pattern.

type busSubBook struct {
	busSubMu    sync.Mutex
	busSubTimer *time.Timer
	busSubSent  string
}

// busSubscribeSoon sends this machine's subscriptions a short time after a change.
func (d *Daemon) busSubscribeSoon() {
	d.busSubMu.Lock()
	defer d.busSubMu.Unlock()
	if d.busSubTimer == nil {
		d.busSubTimer = time.AfterFunc(busSubscribeAfter, func() {
			d.busSubMu.Lock()
			d.busSubTimer = nil
			d.busSubMu.Unlock()
			d.sendBusSubscriptions(false)
		})
	}
}

// sendBusSubscriptions sends them when they changed since the last send, or always.
func (d *Daemon) sendBusSubscriptions(always bool) {
	ask := d.askControl.Load()
	if ask == nil || !d.controlHas(wire.CapEventsBus1) || d.ctx.Err() != nil {
		return
	}
	subs := d.busSubscriptions()
	body, _ := json.Marshal(subs)
	sum := sha256.Sum256(body)
	digest := hex.EncodeToString(sum[:])
	d.busSubMu.Lock()
	same := d.busSubSent == digest
	d.busSubMu.Unlock()
	if same && !always {
		return
	}
	ctx, cancel := context.WithTimeout(d.ctx, reportPatience)
	defer cancel()
	if _, err := (*ask)(ctx, wire.CallBusSubscribe.Name, wire.BusSubscribe{Subscriptions: subs}); err != nil {
		log.Printf("bus/subscribe: %d subscriptions not sent: %v", len(subs), err)
		return
	}
	d.busSubMu.Lock()
	d.busSubSent = digest
	d.busSubMu.Unlock()
}

// busSubscriptions is every wide pattern with no `where`, of the open waits and of the
// workflows that run here, in a steady order, at most as many as the control plane takes.
func (d *Daemon) busSubscriptions() []wire.BusSubscription {
	out := []wire.BusSubscription{}
	add := func(id, name string, f busFilter) {
		if !f.wide() {
			return
		}
		s := wire.BusSubscription{ID: id, Topics: f.topics, Subject: f.subject}
		if f.provider != "" {
			p := f.provider
			s.Provider = &p
		}
		if name != "" {
			n := name
			s.Type = &n
		}
		out = append(out, s)
	}
	for _, a := range d.Store.LiveAgents() {
		w := a.EventWait
		if w == nil || w.Ending != nil {
			continue
		}
		for i, p := range waitPatterns(w) {
			if len(p.filters) == 0 {
				add(fmt.Sprintf("wait:%s:%d", a.ID, i), p.name, p.bus)
			}
		}
	}
	d.workflowMu.Lock()
	for folder, files := range d.workflowFiles {
		for id, f := range files {
			w := f.wf
			if w.Problem != nil || isArchived(w) || !d.runsHere(w) {
				continue
			}
			for i, t := range w.Triggers {
				if bus, narrowed, ok := triggerBus(t); ok && !narrowed {
					add(fmt.Sprintf("workflow:%s:%s:%d", folder, id, i), triggerName(t), bus)
				}
			}
		}
	}
	d.workflowMu.Unlock()
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	if len(out) > 1_000 {
		log.Printf("bus/subscribe: %d subscriptions, sending the first 1000", len(out))
		out = out[:1_000]
	}
	return out
}

// triggerBus is a trigger's filter; narrowed when it has keys of its own (where), which
// the bus cannot check. False for a trigger that is no event or whose filter is unreadable.
func triggerBus(t wire.WorkflowTrigger) (busFilter, bool, bool) {
	u := t.Unrecognised
	if u == nil || !strings.Contains(u.Name, ".") {
		return busFilter{}, false, false
	}
	values := map[string][]string{}
	narrowed := false
	for k, raw := range u.Keys {
		if !busKeys[k] {
			if k != mcpServerKey {
				narrowed = true
			}
			continue
		}
		var one string
		var list []string
		switch {
		case json.Unmarshal(raw, &one) == nil:
			values[k] = []string{one}
		case json.Unmarshal(raw, &list) == nil:
			values[k] = list
		default:
			return busFilter{}, false, false
		}
	}
	f, problem := readBusFilter(values)
	return f, narrowed, problem == ""
}

// triggerMatches is whether an event fires the trigger: the app's event by its pattern, a
// server's by its subscription here and its envelope, and one from the bus by its envelope
// when the trigger names it and has no `where`.
func triggerMatches(t wire.WorkflowTrigger, e wire.Event) bool {
	if p, ok := triggerPattern(t); ok {
		return p.matches(e)
	}
	mt, ok := serverTrigger(t)
	if !ok {
		return false
	}
	bus, narrowed, _ := triggerBus(t)
	if fromBus(e) {
		return bus.wide() && !narrowed && mt.covers(e.Name) && bus.envelopeMatches(e)
	}
	return mt.matches(e) && bus.envelopeMatches(e)
}

// triggerDebounce is how long a trigger holds a burst; 0 for none.
func triggerDebounce(t wire.WorkflowTrigger) time.Duration {
	f, _, _ := triggerBus(t)
	return f.debounce
}
