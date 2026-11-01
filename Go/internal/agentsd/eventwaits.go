package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Agents waiting for something to happen, as DaemonCore+EventWaits keeps them on the Swift
// host. wait_for_event holds the call open up to eventHoldLimit; an event inside that
// answers it, and after it the call says "still waiting" and the agent may end its turn.
// An event after that ends the wait and queues the app's prompt that says so in one write,
// so an agent is started again once for one wait, across a restart as much as within one.
// The words are EventWords', the event names EventCatalogue's (Go/wire/event-catalogue.json).

// eventHoldLimit is how long a wait_for_event call is held open (LeaseLimits.waitLimit).
var eventHoldLimit = 45 * time.Second

const (
	waitMinutesLow  = 1
	waitMinutesHigh = 1440
	waitSymbol      = "◷"
)

// eventKind is one entry of the catalogue.
type eventKind struct {
	Name          string          `json:"name"`
	Scope         string          `json:"scope"`
	MacOnly       bool            `json:"macOnly"`
	Meaning       string          `json:"meaning"`
	InputSchema   json.RawMessage `json:"inputSchema"`
	PayloadSchema json.RawMessage `json:"payloadSchema"`
}

var catalogue = sync.OnceValues(func() ([]eventKind, string) {
	var c struct {
		Kinds    []eventKind `json:"kinds"`
		ListText string      `json:"listText"`
	}
	if err := json.Unmarshal(wire.EventCatalogue, &c); err != nil {
		log.Printf("event catalogue: %v", err)
	}
	return c.Kinds, c.ListText
})

func kindNamed(name string) *eventKind {
	kinds, _ := catalogue()
	for i := range kinds {
		if kinds[i].Name == name {
			return &kinds[i]
		}
	}
	return nil
}

var eventSubjects = []string{"agent", "folder", "workflow", "branch", "dropbox", "lease", "mac", "machine", "person", "cost", "server", "system"}

func isSubject(s string) bool {
	for _, x := range eventSubjects {
		if x == s {
			return true
		}
	}
	return false
}

// isServerEventName is EventCatalogue.isServerEventName: noun.verbed, not the app's.
func isServerEventName(name string) bool {
	if !serverNameShape.MatchString(name) || kindNamed(name) != nil {
		return false
	}
	noun, _, _ := strings.Cut(name, ".")
	return !isSubject(noun) && noun != "custom"
}

// isServerPattern is EventWait.isServerPattern.
func isServerPattern(name string) bool {
	return isServerEventName(name) || strings.HasSuffix(name, ".*") && !isSubject(strings.TrimSuffix(name, ".*"))
}

// forPersonEventNames are server events always raised about the connected account, never
// the repo (#2034): review.requested and issue.assigned, the same names on GitHub and
// GitLab. Waiting on one is waiting for something only that person can settle, so it
// shows as needing them (#3051), unlike an ownership filter such as mine, which only
// narrows which PRs to watch.
var forPersonEventNames = map[string]bool{"review.requested": true, "issue.assigned": true}

// isForPersonEvent is whether a wait on this event name can only be settled by the
// connected person.
func isForPersonEvent(name string) bool { return forPersonEventNames[name] }

// isMacOnly is EventCatalogue.isMacOnly.
func isMacOnly(name string) bool {
	kinds, _ := catalogue()
	if subject, ok := strings.CutSuffix(name, ".*"); ok {
		n := 0
		for _, k := range kinds {
			if strings.HasPrefix(k.Name, subject+".") {
				if !k.MacOnly {
					return false
				}
				n++
			}
		}
		return n > 0
	}
	if k := kindNamed(name); k != nil {
		return k.MacOnly
	}
	return false
}

type jsonSchema struct {
	Type                 any                   `json:"type"`
	Enum                 []string              `json:"enum"`
	Properties           map[string]jsonSchema `json:"properties"`
	Required             []string              `json:"required"`
	AdditionalProperties *bool                 `json:"additionalProperties"`
}

// inputSchemaFor is EventCatalogue.inputSchema(for:): a kind's own, or for subject.* those
// of every kind in the subject.
func inputSchemaFor(name string) jsonSchema {
	closed := false
	if k := kindNamed(name); k != nil {
		var s jsonSchema
		json.Unmarshal(k.InputSchema, &s)
		return s
	}
	out := jsonSchema{Properties: map[string]jsonSchema{}, AdditionalProperties: &closed}
	if subject, ok := strings.CutSuffix(name, ".*"); ok && isSubject(subject) {
		kinds, _ := catalogue()
		for _, k := range kinds {
			if strings.HasPrefix(k.Name, subject+".") {
				var s jsonSchema
				json.Unmarshal(k.InputSchema, &s)
				for key, p := range s.Properties {
					if _, had := out.Properties[key]; !had {
						out.Properties[key] = p
					}
				}
			}
		}
	}
	return out
}

// schemaProblem is JSONSchemaSubset.check for an object of text values.
func schemaProblem(values map[string]string, s jsonSchema, name string) string {
	keys := make([]string, 0, len(values))
	for k := range values {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	takes := func(problem string) string {
		var listed []string
		props := make([]string, 0, len(s.Properties))
		for k := range s.Properties {
			props = append(props, k)
		}
		sort.Strings(props)
		required := map[string]bool{}
		for _, r := range s.Required {
			required[r] = true
		}
		for _, k := range props {
			if required[k] {
				listed = append(listed, k+" (required)")
			} else {
				listed = append(listed, k)
			}
		}
		t := "takes no arguments"
		if len(listed) > 0 {
			t = "takes " + strings.Join(listed, ", ")
		}
		return name + " " + t + "; " + problem + "."
	}
	for _, r := range s.Required {
		if _, ok := values[r]; !ok {
			return takes(r + " is needed")
		}
	}
	if s.AdditionalProperties != nil && !*s.AdditionalProperties {
		for _, k := range keys {
			if _, ok := s.Properties[k]; !ok {
				return takes(`"` + k + `" is not one of its arguments`)
			}
		}
	}
	for _, k := range keys {
		p, ok := s.Properties[k]
		if !ok || len(p.Enum) == 0 {
			continue
		}
		found := false
		for _, e := range p.Enum {
			if e == values[k] {
				found = true
			}
		}
		if !found {
			return name + ": " + k + " is one of " + strings.Join(p.Enum, ", ") + ", not " + values[k] + "."
		}
	}
	return ""
}

// waitPattern is EventPattern on the Go side: a name, and the values each detail may take.
type waitPattern struct {
	name    string
	filters map[string][]string
}

func (p waitPattern) wire() wire.EventPattern {
	w := wire.EventPattern{Name: p.name, Filters: map[string]string{}}
	for k, vs := range p.filters {
		w.Filters[k] = strings.Join(vs, "|")
		if len(vs) > 1 {
			if w.AnyOf == nil {
				w.AnyOf = map[string][]string{}
			}
			w.AnyOf[k] = vs
		}
	}
	return w
}

func patternOf(w wire.EventPattern) waitPattern {
	p := waitPattern{name: w.Name, filters: map[string][]string{}}
	for k, v := range w.Filters {
		p.filters[k] = []string{v}
	}
	for k, vs := range w.AnyOf {
		if len(vs) > 0 {
			p.filters[k] = vs
		}
	}
	return p
}

// label is EventPattern.label: "branch.moved branch main|develop".
func (p waitPattern) label() string {
	parts := []string{p.name}
	keys := make([]string, 0, len(p.filters))
	for k := range p.filters {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		parts = append(parts, k+" "+strings.Join(p.filters[k], "|"))
	}
	return strings.Join(parts, " ")
}

func (p waitPattern) matches(e wire.Event) bool {
	if subject, ok := strings.CutSuffix(p.name, ".*"); ok {
		if isSubject(subject) {
			if !strings.HasPrefix(e.Name, subject+".") {
				return false
			}
		} else if !strings.HasPrefix(e.Name, subject+".") || !isServerEventName(e.Name) {
			return false
		}
	} else if e.Name != p.name {
		return false
	}
	for k, vs := range p.filters {
		v, ok := e.Details[k]
		if !ok || !contains(vs, v) {
			return false
		}
	}
	return true
}

func contains(vs []string, v string) bool {
	for _, x := range vs {
		if x == v {
			return true
		}
	}
	return false
}

// levenshtein is EventPatternProblem.distance.
func levenshtein(a, b string) int {
	ra, rb := []rune(a), []rune(b)
	prev := make([]int, len(rb)+1)
	for j := range prev {
		prev[j] = j
	}
	for i := 1; i <= len(ra); i++ {
		cur := make([]int, len(rb)+1)
		cur[0] = i
		for j := 1; j <= len(rb); j++ {
			c := 1
			if ra[i-1] == rb[j-1] {
				c = 0
			}
			cur[j] = min(prev[j]+1, cur[j-1]+1, prev[j-1]+c)
		}
		prev = cur
	}
	return prev[len(rb)]
}

// closestEvent is EventPatternProblem.closest.
func closestEvent(name string) string {
	kinds, _ := catalogue()
	best, score := "", -1
	for _, k := range kinds {
		if d := levenshtein(name, k.Name); score < 0 || d < score {
			best, score = k.Name, d
		}
	}
	if score >= 0 && score <= max(2, len([]rune(name))/4) {
		return best
	}
	noun, verb, ok := strings.Cut(name, ".")
	if !ok || verb == "" || !(isSubject(noun) || noun == "custom") {
		return ""
	}
	var same []string
	for _, k := range kinds {
		if strings.HasSuffix(k.Name, "."+verb) {
			same = append(same, k.Name)
		}
	}
	if len(same) == 1 {
		return same[0]
	}
	return ""
}

// parsePattern is EventPattern.parse, with its problem's message.
func parsePattern(given string, filters map[string][]string) (waitPattern, string) {
	name := strings.ToLower(strings.TrimSpace(given))
	clean := map[string][]string{}
	for k, vs := range filters {
		var out []string
		for _, v := range vs {
			out = append(out, strings.TrimSpace(v))
		}
		clean[strings.TrimSpace(k)] = out
	}
	p := waitPattern{name: name, filters: clean}
	if name == "custom" || strings.HasPrefix(name, "custom.") {
		return p, `"` + name + `" is never raised: agents no longer publish events, so there are no custom.* events to wait or trigger on. ` +
			"Use one the app raises, such as agent.finished or branch.moved; to wait for particular agents, use wait_for_agents."
	}
	unknown := func() (waitPattern, string) {
		kinds, _ := catalogue()
		var names []string
		for _, k := range kinds {
			names = append(names, k.Name)
		}
		guess := ""
		if g := closestEvent(name); g != "" {
			guess = " Did you mean " + g + "?"
		}
		return p, `"` + name + `" is not an event.` + guess + " Events you can wait on: " + strings.Join(names, ", ") +
			", or a subject with .* such as agent.*."
	}
	if subject, ok := strings.CutSuffix(name, ".*"); ok {
		if !isSubject(subject) {
			if isServerEventName(subject + ".any") {
				return p, ""
			}
			return unknown()
		}
	} else if kindNamed(name) == nil {
		if isServerEventName(name) {
			return p, ""
		}
		return unknown()
	}
	schema := inputSchemaFor(name)
	first := map[string]string{}
	for k, vs := range clean {
		first[k] = vs[0]
	}
	problem := schemaProblem(first, schema, name)
	if problem == "" {
		keys := make([]string, 0, len(clean))
		for k := range clean {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		for _, k := range keys {
			for _, v := range clean[k][1:] {
				if problem = schemaProblem(map[string]string{k: v}, schema, name); problem != "" {
					break
				}
			}
			if problem != "" {
				break
			}
		}
	}
	if problem != "" {
		if strings.HasPrefix(name, "agent.") {
			problem += " To wait for particular agents, use wait_for_agents."
		}
		return p, problem
	}
	return p, ""
}

// The wait on the agent's record, and its words.

func waitPatterns(w *wire.EventWait) []waitPattern {
	var out []waitPattern
	for _, p := range w.Patterns {
		out = append(out, patternOf(p))
	}
	return out
}

// waitLabel is EventWait.label: a server's event says the servers it was subscribed to; a
// place in a lease's line, "your turn with build" (#2361).
func waitLabel(w *wire.EventWait) string {
	if len(w.Patterns) == 1 {
		p := patternOf(w.Patterns[0])
		if who := p.filters["agent"]; len(who) == 1 {
			if name, ok := lineWaitResource(w, wire.UUID(who[0])); ok {
				return "your turn with " + string(name)
			}
		}
	}
	var labels []string
	for _, p := range waitPatterns(w) {
		label := p.label()
		for _, se := range w.ServerEvents {
			if se.Trigger.Event == p.name {
				label = waitServerLabel(se)
				break
			}
		}
		labels = append(labels, label)
	}
	return strings.Join(labels, " or ")
}

// waitMatches is EventWait.matches: a server's event matches by the subscription that
// raised it (#577), never by its details, since its `where` went to the server.
func waitMatches(w *wire.EventWait, e wire.Event) bool {
	if e.Position <= w.From {
		return false
	}
	for _, se := range w.ServerEvents {
		if mcpTriggerOfWire(se.Trigger).matches(e) {
			return true
		}
	}
	for _, p := range waitPatterns(w) {
		if (len(w.ServerEvents) == 0 || !isServerPattern(p.name)) && p.matches(e) {
			return true
		}
	}
	return false
}

func detailsLine(e wire.Event) string {
	keys := make([]string, 0, len(e.Details))
	for k := range e.Details {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	var parts []string
	for _, k := range keys {
		parts = append(parts, k+"="+e.Details[k])
	}
	return strings.Join(parts, ", ")
}

func matchedWords(e wire.Event, waited *int) string {
	after := ""
	if waited != nil {
		after = fmt.Sprintf(" after waiting %d s", *waited)
	}
	details := ""
	if l := detailsLine(e); l != "" {
		details = ". " + l
	}
	message := ""
	if e.Message != nil {
		message = ". Message: " + *e.Message
	}
	return fmt.Sprintf("%s happened at %s (position %d)%s: %s%s%s. You can carry on.", e.Name, clock(e.At), e.Position, after,
		e.Sentence, details, message)
}

func stillWaitingWords(w *wire.EventWait) string {
	until := ""
	if w.Deadline != nil {
		until = ", until " + clock(*w.Deadline)
	}
	return "Still waiting for " + waitLabel(w) + ", since " + clock(w.Since) + until +
		". Your place is kept; you can end your turn. You'll be started again when it happens."
}

func replacedWords(w *wire.EventWait) string {
	return "Replaced your earlier wait on " + waitLabel(w) + ". "
}

func deadlineRequiredWords() string {
	return fmt.Sprintf("until_minutes is required: say how long to wait, from %d minute to 24 hours (%d). "+
		"When it runs out you are started again and can wait again.", waitMinutesLow, waitMinutesHigh)
}

func neverHereWords(names []string) string {
	if len(names) == 1 {
		return names[0] + " is only raised on a Mac, and this machine is a Linux server, so it never happens here."
	}
	return strings.Join(names, ", ") + " are only raised on a Mac, and this machine is a Linux server, so they never happen here."
}

func wakeWords(e wire.Event, extra int) string {
	lines := []string{"The event you were waiting for happened.", "",
		fmt.Sprintf("%s at %s (position %d)", e.Name, clock(e.At), e.Position), e.Sentence}
	keys := make([]string, 0, len(e.Details))
	for k := range e.Details {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if k == "agent_title" {
			continue
		}
		v := e.Details[k]
		if t, ok := e.Details["agent_title"]; k == "agent" && ok {
			v = t + " (" + v + ")"
		}
		lines = append(lines, k+": "+v)
	}
	if e.Publisher != nil {
		lines = append(lines, "published by: "+e.Publisher.Title)
	}
	if e.Message != nil {
		lines = append(lines, "message: "+*e.Message)
	}
	if extra > 0 {
		more := fmt.Sprintf("%d more matches arrived", extra)
		if extra == 1 {
			more = "1 more match arrived"
		}
		lines = append(lines, "", more+" before you resumed; they are in this folder's events.")
	}
	return strings.Join(lines, "\n")
}

func timedOutWords(w *wire.EventWait, at wire.Date) string {
	return "Your wait for " + waitLabel(w) + " timed out at " + clock(at) + " with no match."
}

func endedWords(w *wire.EventWait, by wire.EventWaitEndingCanceller) string {
	l := waitLabel(w)
	switch by {
	case "person":
		// End Wait means the same whether this call is still open or not (#3152): nothing
		// starts the agent again for it. Carry On is the person's way to say carry on.
		return "The person ended your wait for " + l + ". Do not carry on with what needed it, and do not wait for it again: end your turn. The person will tell you when to go on."
	case "prompt":
		return "The person sent you a message, which cancelled your wait for " + l + "."
	case "stopped":
		return "You were stopped, which ended your wait for " + l + "."
	case "archived":
		return "You were archived, which ended your wait for " + l + "."
	case "archiveRequested":
		return "You asked to be archived, which ended your wait for " + l + "."
	}
	return "Stopped waiting for " + l + "."
}

// waitStatus is WaitStatus.of for an event wait.
func (d *Daemon) waitStatus(a *wire.Agent) *wire.WaitStatus {
	w := a.EventWait
	if w == nil || w.Ending != nil {
		// A block on agents reads the same, and goes when the person prompts.
		if isOpenBlock(a.Report) && a.Report.Block != nil && len(a.Report.Block.Waits) > 0 {
			var names []string
			for _, w := range a.Report.Block.Waits {
				names = append(names, "\u201C"+d.waitName(w)+"\u201D")
			}
			what := listWords(names) + " to finish"
			return &wire.WaitStatus{Line: waitSymbol + " Waiting for " + what, Mark: waitSymbol + " Waiting for " + what}
		}
		return nil
	}
	what := waitLabel(w)
	ps := waitPatterns(w)
	var finishing []string
	for _, p := range ps {
		if v := p.filters["agent"]; p.name == "agent.finished" && len(p.filters) == 1 && len(v) == 1 {
			name := v[0]
			if other := d.Store.Agent(wire.UUID(v[0])); other != nil && other.Title != nil {
				name = *other.Title
			}
			finishing = append(finishing, "“"+name+"”")
		}
	}
	if len(finishing) == len(ps) && len(ps) > 0 {
		what = listWords(finishing) + " to finish"
	}
	line := waitSymbol + " Waiting for " + what + " · since " + clock(w.Since)
	if w.Deadline != nil {
		line += " · until " + clock(*w.Deadline)
	}
	return &wire.WaitStatus{Line: line, Mark: waitSymbol + " Waiting for " + what, Cancellable: true}
}

// waitingAgents is the Events page's Waiting now strip, oldest wait first.
func (d *Daemon) waitingAgents() []wire.WaitingAgent {
	type row struct {
		w     wire.WaitingAgent
		since wire.Date
	}
	var rows []row
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived {
			continue
		}
		s := d.waitStatus(&a)
		if s == nil {
			continue
		}
		title := "Untitled"
		if a.Title != nil {
			title = *a.Title
		}
		since := a.LastActivityAt
		if a.EventWait != nil {
			since = a.EventWait.Since
		}
		rows = append(rows, row{wire.WaitingAgent{AgentID: a.ID, Title: title, Folder: store.FolderURL(folderPath(&a)), Status: *s}, since})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i].since < rows[j].since })
	out := []wire.WaitingAgent{}
	for _, r := range rows {
		out = append(out, r.w)
	}
	return out
}

// The calls held open, and the one deadline timer.

type openEventCall struct {
	waitID  wire.UUID
	answer  chan string
	started time.Time
}

type eventWaitState struct {
	waitMu     sync.Mutex
	openWaits  map[wire.UUID]*openEventCall // by agent
	waitTimer  *time.Timer
	blockTimer *time.Timer
}

func (d *Daemon) inScope(e wire.Event, a *wire.Agent) bool {
	return e.Scope.Mac != nil || e.Scope.Folder != nil && store.FolderPath(e.Scope.Folder.Value) == folderPath(a)
}

func (d *Daemon) takeOpenWait(agent wire.UUID) *openEventCall {
	d.waitMu.Lock()
	defer d.waitMu.Unlock()
	c := d.openWaits[agent]
	delete(d.openWaits, agent)
	return c
}

// defaultBranch is origin/HEAD's branch, else main, else master.
func defaultBranch(dir string) string {
	if out, err := git(dir, "symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"); err == nil {
		if b := strings.TrimPrefix(strings.TrimSpace(out), "origin/"); b != "" {
			return b
		}
	}
	if _, err := git(dir, "rev-parse", "--verify", "--quiet", "refs/heads/main"); err == nil {
		return "main"
	}
	if _, err := git(dir, "rev-parse", "--verify", "--quiet", "refs/heads/master"); err == nil {
		return "master"
	}
	return "main"
}

// waitForEvent is wait_for_event on events. The call is held open up to eventHoldLimit.
func (d *Daemon) waitForEvent(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	a := d.Store.Agent(agent)
	if a == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: leaseNoCall}
	}

	var names []string
	if s, err := stringList(args, "events"); err == nil {
		for _, n := range s {
			if n = strings.TrimSpace(n); n != "" {
				names = append(names, n)
			}
		}
	}
	if len(names) == 0 {
		return "", eventRefused(`Say what to wait for in events, e.g. ["agent.finished"]. Unknown events and filters say what is offered.`)
	}
	minutes, ok := argInt(args, "until_minutes")
	if !ok {
		return "", eventRefused(deadlineRequiredWords())
	}
	if minutes < waitMinutesLow || minutes > waitMinutesHigh {
		return "", eventRefused(fmt.Sprintf("until_minutes has to be from %d to %d.", waitMinutesLow, waitMinutesHigh))
	}
	filters, problem := readFilters(args["where"])
	if problem != "" {
		return "", eventRefused(problem)
	}
	var patterns []waitPattern
	var serverNames []string
	for _, n := range names {
		p, problem := parsePattern(n, filters)
		if problem != "" {
			return "", eventRefused(problem)
		}
		if isServerPattern(p.name) {
			// A server's event is matched by its subscription, not its details: `where`
			// goes to the server (#577).
			patterns = append(patterns, waitPattern{name: p.name, filters: map[string][]string{}})
			serverNames = append(serverNames, p.name)
			continue
		}
		patterns = append(patterns, p)
	}
	if branches, ok := filters["branch"]; ok {
		for _, p := range patterns {
			if p.name == "branch.moved" {
				if main := defaultBranch(folderPath(a)); contains(branches, main) {
					return "", eventRefused("branch.moved is not raised for " + main + ", the default branch: this Mac's copy moves only when someone " +
						"pulls. To wait for a pull request to land, wait for pr.merged (or pr.closed) with its pr. Nothing is waiting.")
				}
			}
		}
	}
	// A server never raises what only a Mac does: a wait on nothing else is refused.
	var neverHere []string
	for _, p := range patterns {
		if isMacOnly(p.name) {
			neverHere = append(neverHere, p.name)
		}
	}
	if len(neverHere) > 0 && len(neverHere) == len(patterns) {
		return "", eventRefused(neverHereWords(neverHere) + " Nothing is waiting.")
	}
	warning := ""
	if len(neverHere) > 0 {
		warning = neverHereWords(neverHere) + " "
	}
	// A server's event is a subscription the wait holds, as a trigger's is (#577):
	// checked against what the folder's servers offer, `where` as its arguments.
	servers, err := d.checkMCPWait(serverNames, filters, folderPath(a))
	if err != nil {
		return "", err
	}
	warning += servers.warning
	d.eventMu.Lock()
	from := d.eventHead()
	d.eventMu.Unlock()
	at := now()
	deadline := wire.DateOf(at.Time().Add(time.Duration(minutes) * time.Minute))
	wait := wire.EventWait{ID: store.NewUUID(), From: from, Deadline: &deadline, Since: at}
	if len(serverNames) > 0 {
		wait.ServerEvents = servers.events
	}
	for _, p := range patterns {
		wait.Patterns = append(wait.Patterns, p.wire())
	}
	for _, n := range serverNames {
		if isForPersonEvent(n) {
			forPerson := true
			wait.ForPerson = &forPerson
			break
		}
	}

	// Something already after from: answered now, and nothing is left waiting.
	var hit *wire.Event
	d.eventMu.Lock()
	for _, e := range d.eventList {
		if d.inScope(e, a) && waitMatches(&wait, e) {
			c := copyEvent(e)
			hit = &c
			break
		}
	}
	d.eventMu.Unlock()
	if hit != nil {
		prev := d.endWait(agent, "agent", true)
		replaced := ""
		if prev != nil {
			replaced = replacedWords(prev)
		}
		return warning + replaced + matchedWords(*hit, nil), nil
	}
	prev := d.endWait(agent, "agent", true)
	// Only one of EventWait and an open Block is ever current (#3094): the chat draws one
	// card at the foot of the chat, not both.
	d.dropBlock(agent)
	call := &openEventCall{waitID: wait.ID, answer: make(chan string, 1), started: time.Now()}
	// Parked before the record says it waits, so an event in the next instant finds the
	// call to answer rather than starting the agent again.
	d.waitMu.Lock()
	if d.openWaits == nil {
		d.openWaits = map[wire.UUID]*openEventCall{}
	}
	d.openWaits[agent] = call
	d.waitMu.Unlock()
	if d.change(agent, func(a *wire.Agent) { a.EventWait = &wait }) == nil {
		d.takeOpenWait(agent)
		return "", &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
	}
	d.startMCPWait(servers)
	d.tellEvents(nil)
	d.armWaitTimer()
	prefix := warning + subscribedWords(servers.events)
	if prev != nil {
		prefix += replacedWords(prev)
	}
	hold := time.AfterFunc(eventHoldLimit, func() { d.eventHoldReached(agent, wait.ID) })
	defer hold.Stop()
	select {
	case text := <-call.answer:
		return prefix + text, nil
	case <-d.ctx.Done():
		return prefix + stillWaitingWords(&wait), nil
	}
}

func argBool(args map[string]json.RawMessage, key string) bool {
	raw, ok := args[key]
	if !ok || string(raw) == "null" {
		return false
	}
	var b bool
	if json.Unmarshal(raw, &b) == nil {
		return b
	}
	return false
}

func argInt(args map[string]json.RawMessage, key string) (int, bool) {
	raw, ok := args[key]
	if !ok || string(raw) == "null" {
		return 0, false
	}
	var n float64
	if json.Unmarshal(raw, &n) == nil && n == float64(int(n)) {
		return int(n), true
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if i, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
			return i, true
		}
	}
	return 0, false
}

// readFilters is each where key's value, one or a list (WorkflowTrigger.filter).
func readFilters(raw json.RawMessage) (map[string][]string, string) {
	var obj map[string]json.RawMessage
	if len(raw) == 0 || json.Unmarshal(raw, &obj) != nil {
		return map[string][]string{}, ""
	}
	scalar := func(r json.RawMessage) (string, bool) {
		var s string
		if json.Unmarshal(r, &s) == nil {
			return s, true
		}
		var b bool
		if json.Unmarshal(r, &b) == nil {
			return strconv.FormatBool(b), true
		}
		var n float64
		if json.Unmarshal(r, &n) == nil && n == float64(int64(n)) {
			return strconv.FormatInt(int64(n), 10), true
		}
		return "", false
	}
	keys := make([]string, 0, len(obj))
	for k := range obj {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	out := map[string][]string{}
	for _, k := range keys {
		if one, ok := scalar(obj[k]); ok {
			out[k] = []string{one}
			continue
		}
		var items []json.RawMessage
		var vs []string
		if json.Unmarshal(obj[k], &items) == nil && len(items) > 0 {
			for _, it := range items {
				if v, ok := scalar(it); ok {
					vs = append(vs, v)
				}
			}
		}
		if len(vs) == 0 || len(vs) != len(items) {
			return nil, `Nothing is waited for: the "` + k + `" in where is not a value. A value is text, ` +
				`a number, true or false, or a list of those, e.g. {"branch": ["main", "develop"]}.`
		}
		out[k] = vs
	}
	return out, ""
}

// cancelWait is cancel_wait.
func (d *Daemon) cancelWait(agent wire.UUID, _ map[string]json.RawMessage) (string, error) {
	if d.Store.Agent(agent) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: leaseNoCall}
	}
	w := d.endWait(agent, "agent", false)
	if w == nil {
		return "", &Error{Code: wire.FailureNoWait, Message: "You weren't waiting on anything."}
	}
	return "Stopped waiting for " + waitLabel(w) + ".", nil
}

// endWait ends an agent's open wait without waking it; a call still open hears why. It is
// the wait that ended, or nil.
func (d *Daemon) endWait(agent wire.UUID, by wire.EventWaitEndingCanceller, quietly bool) *wire.EventWait {
	a := d.Store.Agent(agent)
	if a == nil || a.EventWait == nil || a.EventWait.Ending != nil {
		return nil
	}
	w := *a.EventWait
	d.change(agent, func(a *wire.Agent) { a.EventWait = nil })
	// Stop Waiting, or cancel_wait, on a place in a line leaves the line (#2361); a wait
	// that replaces it keeps the place.
	if name, ok := lineWaitResource(&w, agent); ok && !quietly && (by == "person" || by == "agent") {
		d.leaveLine(agent, name)
	}
	if c := d.takeOpenWait(agent); c != nil {
		if quietly {
			c.answer <- replacedWords(&w)
		} else {
			c.answer <- endedWords(&w, by)
		}
	}
	d.tellEvents(nil)
	d.armWaitTimer()
	return &w
}

// matchWaits is every wait this event satisfies: the call answered when it is still open,
// else the wait ended and the wake queued in one write.
func (d *Daemon) matchWaits(e wire.Event) {
	for _, a := range d.Store.Agents() {
		w := a.EventWait
		// An agent's own events do not wake it, but for its own grant, which is the one
		// thing its place in a line waits for (#2361).
		if w == nil || !d.inScope(e, &a) || !waitMatches(w, e) || e.Details["agent"] == string(a.ID) && e.Name != "lease.granted" {
			continue
		}
		title := "Untitled"
		if a.Title != nil {
			title = *a.Title
		}
		if w.Ending == nil {
			if c := d.takeOpenWait(a.ID); c != nil {
				waited := int(time.Since(c.started).Round(time.Second).Seconds())
				d.change(a.ID, func(a *wire.Agent) { a.EventWait = nil })
				c.answer <- matchedWords(e, &waited) + d.restartNotice(w)
			} else {
				prompt := wire.QueuedPrompt{ID: store.NewUUID(), Text: wakeWords(e, 0) + d.restartNotice(w), QueuedAt: now(), From: wire.PromptOriginApp,
					Attachments: []wire.Attachment{}}
				ended := *w
				ended.Ending = &wire.EventWaitEnding{Matched: &wire.EventWaitEndingMatched{Position: e.Position}}
				ended.ResumePromptID = &prompt.ID
				d.change(a.ID, func(a *wire.Agent) {
					a.EventWait = &ended
					a.QueuedPrompts = append(append([]wire.QueuedPrompt{}, a.QueuedPrompts...), prompt)
				})
				id, pos := a.ID, e.Position
				safe.Go("event wake", func() { d.sendEventResume(id, prompt.ID, &pos) })
			}
			d.addConsequence(wire.Consequence{Woke: &wire.ConsequenceWoke{AgentID: a.ID, Title: title}}, e.Position)
			d.tellEvents(nil)
			d.armWaitTimer()
		} else if m := w.Ending.Matched; m != nil && w.ResumePromptID != nil && e.Position != m.Position {
			// Woken, and not running yet: counted in the prompt it will read.
			first := d.event(m.Position)
			if first == nil {
				continue
			}
			promptID := *w.ResumePromptID
			notice := d.restartNotice(w)
			d.change(a.ID, func(a *wire.Agent) {
				if a.EventWait == nil || a.EventWait.Ending == nil || a.EventWait.Ending.Matched == nil {
					return
				}
				// Copied, not written through: the record's parts are shared with readers.
				prompts := append([]wire.QueuedPrompt{}, a.QueuedPrompts...)
				for i := range prompts {
					if prompts[i].ID == promptID {
						w, ending, matched := *a.EventWait, *a.EventWait.Ending, *a.EventWait.Ending.Matched
						matched.ExtraMatches++
						ending.Matched, w.Ending = &matched, &ending
						a.EventWait = &w
						prompts[i].Text = wakeWords(*first, int(matched.ExtraMatches)) + notice
					}
				}
				a.QueuedPrompts = prompts
			})
		}
	}
}

// sendEventResume sends a queued wake; one that cannot go drops the wait, records that the
// agent could not be woken, and says in its chat what it missed.
func (d *Daemon) sendEventResume(id, promptID wire.UUID, position *int64) {
	a := d.Store.Agent(id)
	if a == nil {
		return
	}
	err := d.refuseToRun(a)
	if err == nil {
		err = d.needsSignIn(a.RuntimeID)
	}
	if err == nil {
		d.live(id).kick()
		return
	}
	why := err.Error()
	if e, ok := err.(*Error); ok {
		why = e.Message
	}
	d.change(id, func(a *wire.Agent) {
		kept := a.QueuedPrompts[:0:0]
		for _, q := range a.QueuedPrompts {
			if q.ID != promptID {
				kept = append(kept, q)
			}
		}
		a.QueuedPrompts = kept
		if a.EventWait != nil {
			w := *a.EventWait
			w.Ending = &wire.EventWaitEnding{CouldNotWake: &wire.EventWaitEndingCouldNotWake{Reason: why}}
			a.EventWait = &w
		}
	})
	var e *wire.Event
	if position != nil {
		e = d.event(*position)
	}
	if e == nil {
		d.record(id, runtimeNote("Could not be started again when its wait ended: "+why+"."))
	} else {
		d.record(id, runtimeNote("Missed "+e.Name+" at "+clock(e.At)+" ("+e.Sentence+"): could not be started again, "+why+"."))
		title := "Untitled"
		if a.Title != nil {
			title = *a.Title
		}
		d.addConsequence(wire.Consequence{CouldNotWake: &wire.ConsequenceCouldNotWake{AgentID: id, Title: title, Reason: why}}, *position)
	}
	d.tellEvents(nil)
}

// eventHoldReached answers a call held as long as a call may: still waiting, and the
// agent is waiting now.
func (d *Daemon) eventHoldReached(agent, waitID wire.UUID) {
	a := d.Store.Agent(agent)
	if a == nil || a.EventWait == nil || a.EventWait.ID != waitID || a.EventWait.Ending != nil {
		return
	}
	d.waitMu.Lock()
	c := d.openWaits[agent]
	if c == nil || c.waitID != waitID {
		d.waitMu.Unlock()
		return
	}
	delete(d.openWaits, agent)
	d.waitMu.Unlock()
	c.answer <- stillWaitingWords(a.EventWait)
	label := waitLabel(a.EventWait)
	d.raiseAgentEvent("agent.waiting", agent, "is waiting for "+label+".", map[string]string{"waiting_on": label})
}

// armWaitTimer aims the one timer at the earliest deadline of any open wait.
func (d *Daemon) armWaitTimer() {
	// A wait that ended may have held a server's subscription (#577).
	d.kickMCPEvents()
	var next *time.Time
	for _, a := range d.Store.Agents() {
		if w := a.EventWait; w != nil && w.Ending == nil && w.Deadline != nil {
			t := w.Deadline.Time()
			if next == nil || t.Before(*next) {
				next = &t
			}
		}
	}
	d.waitMu.Lock()
	defer d.waitMu.Unlock()
	if d.waitTimer != nil {
		d.waitTimer.Stop()
		d.waitTimer = nil
	}
	if next == nil || d.ctx.Err() != nil {
		return
	}
	d.waitTimer = time.AfterFunc(max(0, time.Until(*next))+20*time.Millisecond, d.waitDeadlinesPassed)
}

// waitDeadlinesPassed ends every open wait whose deadline has come, timed out: an open call
// hears it, and an agent whose turn has ended is started again to be told.
func (d *Daemon) waitDeadlinesPassed() {
	at := now()
	for _, a := range d.Store.Agents() {
		w := a.EventWait
		if w == nil || w.Ending != nil || w.Deadline == nil || w.Deadline.Time().After(at.Time()) {
			continue
		}
		d.endWaitWithNoMatch(a.ID, w, timedOutWords(w, at))
	}
	d.tellEvents(nil)
	d.armWaitTimer()
}

// endWaitWithNoMatch ends an open wait as a time-out does, with words: an open call hears
// them, and an agent whose turn has ended is started again to be told.
func (d *Daemon) endWaitWithNoMatch(id wire.UUID, w *wire.EventWait, words string) {
	if c := d.takeOpenWait(id); c != nil {
		d.change(id, func(a *wire.Agent) { a.EventWait = nil })
		c.answer <- words + d.restartNotice(w)
		return
	}
	prompt := wire.QueuedPrompt{ID: store.NewUUID(), Text: words + d.restartNotice(w), QueuedAt: now(), From: wire.PromptOriginApp,
		Attachments: []wire.Attachment{}}
	ended := *w
	ended.Ending = &wire.EventWaitEnding{TimedOut: &struct{}{}}
	ended.ResumePromptID = &prompt.ID
	d.change(id, func(a *wire.Agent) {
		a.EventWait = &ended
		a.QueuedPrompts = append(append([]wire.QueuedPrompt{}, a.QueuedPrompts...), prompt)
	})
	safe.Go("event timeout", func() { d.sendEventResume(id, prompt.ID, nil) })
}

// resumeEventWaits is resumeEventWaitsAfterRestart: no call survives a restart, so every
// open wait is an agent to start when its event comes; a wake queued and never sent is
// sent once; a deadline that passed while the host was down ends now.
func (d *Daemon) resumeEventWaits() {
	latest := wire.DateOf(time.Now().Add(waitMinutesHigh * time.Minute))
	for _, a := range d.Store.Agents() {
		w := a.EventWait
		if w == nil {
			continue
		}
		if w.Ending == nil && w.Deadline == nil {
			d.change(a.ID, func(a *wire.Agent) {
				if a.EventWait != nil {
					w := *a.EventWait
					w.Deadline = &latest
					a.EventWait = &w
				}
			})
			continue
		}
		if w.Ending != nil && w.ResumePromptID != nil && len(a.QueuedPrompts) > 0 && a.QueuedPrompts[0].ID == *w.ResumePromptID {
			var pos *int64
			if m := w.Ending.Matched; m != nil {
				p := m.Position
				pos = &p
			}
			d.sendEventResume(a.ID, *w.ResumePromptID, pos)
		}
	}
	d.waitDeadlinesPassed()
}

func (d *Daemon) stopEventWaits() {
	d.waitMu.Lock()
	defer d.waitMu.Unlock()
	if d.waitTimer != nil {
		d.waitTimer.Stop()
		d.waitTimer = nil
	}
	if d.blockTimer != nil {
		d.blockTimer.Stop()
		d.blockTimer = nil
	}
}

func (d *Daemon) registerEventWaits() {
	// events/cancelWait: the person, from a window. Nothing starts the agent again for it.
	On(d, wire.CallEventsCancelWait, func(ctx context.Context, c *Client, r wire.CancelWaitRequest) ([]wire.WaitingAgent, error) {
		if d.Store.Agent(r.AgentID) == nil {
			return nil, &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."}
		}
		if d.endWait(r.AgentID, "person", false) == nil {
			return nil, &Error{Code: wire.FailureNoWait, Message: "That agent is not waiting on anything."}
		}
		return d.waitingAgents(), nil
	})
}
