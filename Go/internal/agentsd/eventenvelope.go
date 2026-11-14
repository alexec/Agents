package agentsd

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agents/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The event envelope (#4728, spec 4724-event-bus, "An event" and "Topics"): every event
// is a CloudEvents 1.0 event with two extensions, provider and topic. Its id is its ref:
// the subject's ref, "@", the type, and "/" and the provider's key when the same type can
// happen again to that thing. The id comes from the provider's data only, so two machines
// that hear the same happening make the same id.
//
// The app's own events have the provider "agents" and, for the topic, the folder's project
// (agent.*, workflow.*, request.*, branch.*, folder.*, file.*) or the machine (machine.*,
// mac.*, person.*, lease.*, server.*, system.*, cost.allowance_*). The app is their
// provider, and only the machine that raises one has it, so their key is the event's
// position on that machine.
//
// An MCP server's event says its subject (a ref) and its key in events/poll. One that
// says no subject gets the provider server:<name>, no topic, and its eventId as the key.

const eventSpecVersion = "1.0"

// serverEnvelope is what a server said of one polled event: its subject's ref and its key.
type serverEnvelope struct {
	server, eventID string
	subject         *wire.Ref
	key             string
	// bus is the envelope of an event the bus delivered (#4729): it keeps it as it came.
	bus *wire.BusEvent
	// busData is its data, opened from the copy sealed to this machine (#4825), if any.
	busData json.RawMessage
}

// envelope gives an event its envelope: from what its server said for a server's
// event, from its name, scope and details for the app's own.
func (d *Daemon) envelope(e *wire.Event, server *serverEnvelope) {
	if server != nil && server.bus != nil {
		b := server.bus
		setEnvelope(e, b.ID, b.Provider, b.Topic, b.Subject, b.Time, b.Producer, server.busData)
		return
	}
	provider, topic, key := "agents", "", strconv.FormatInt(e.Position, 10)
	var subject *wire.Ref
	switch {
	case server != nil && server.subject != nil:
		s := *server.subject
		provider, topic, key, subject = s.Provider, s.Topic, server.key, &s
	case server != nil:
		provider, key = "server:"+server.server, server.eventID
	case e.Name == ciSlowedName:
		// The same id on every machine that finds the change (#5200), so the bus keeps one.
		if s, k, ok := ciSlowedEnvelope(*e); ok {
			topic, key, subject = s.Topic, k, &s
			break
		}
		s := d.appSubject(*e)
		topic, subject = s.Topic, &s
	default:
		s := d.appSubject(*e)
		topic, subject = s.Topic, &s
		if e.Scope.Mac != nil {
			topic = d.envelopeMachine()
		}
	}
	id := provider
	if subject != nil {
		id = subject.String()
	}
	id += "@" + e.Name
	if key != "" {
		id += "/" + key
	}
	setEnvelope(e, id, provider, topic, subject, eventTime(*e), "agents:machine:#"+d.envelopeMachine(), eventData(*e))
}

func setEnvelope(e *wire.Event, id, provider, topic string, subject *wire.Ref, at, producer string, data json.RawMessage) {
	spec, typ, source := eventSpecVersion, e.Name, provider+":"+topic
	e.Specversion, e.ID, e.Type, e.Provider, e.Topic, e.Subject = &spec, &id, &typ, &provider, &topic, subject
	e.Source, e.Time, e.Producer, e.Data = &source, &at, &producer, data
}

// envelopeOld gives an event read from a log written before #4728 its envelope, as its
// name and details say it. A server's event there has no subject: its server did not say.
func (d *Daemon) envelopeOld(e *wire.Event) {
	if e.ID != nil {
		return
	}
	var server *serverEnvelope
	if id := e.Details["mcp_event_id"]; id != "" {
		server = &serverEnvelope{server: e.Details["server"], eventID: id}
	}
	d.envelope(e, server)
}

// appSubject is the ref of what an app's own event happened to. Its topic is the folder's
// project for an event in a folder; envelope puts the machine as the event's topic for one
// on the Mac.
func (d *Daemon) appSubject(e wire.Event) wire.Ref {
	noun, _, _ := strings.Cut(e.Name, ".")
	if e.Scope.Mac != nil {
		machine := d.envelopeMachine()
		switch {
		case noun == "lease" && e.Details["resource"] != "":
			return wire.Ref{Provider: "agents", Type: "lease", Topic: machine, ID: e.Details["resource"]}
		case noun == "server" && e.Details["server"] != "":
			return wire.Ref{Provider: "agents", Type: "server", Topic: machine, ID: e.Details["server"]}
		}
		return wire.Ref{Provider: "agents", Type: "machine", ID: machine}
	}
	folder := ""
	if e.Scope.Folder != nil {
		folder = store.FolderPath(e.Scope.Folder.Value)
	}
	project := refTopic(d.envelopeProject(folder))
	of := func(typ, id string) (wire.Ref, bool) {
		r := wire.Ref{Provider: "agents", Type: typ, Topic: project, ID: id}
		return r, id != "" && r.Check() == nil
	}
	var r wire.Ref
	ok := false
	switch noun {
	case "agent", "cost":
		r, ok = of("session", e.Details["agent"])
	case "workflow":
		r, ok = of("workflow", e.Details["workflow"])
	case "request":
		r, ok = of("request", e.Details["request"])
	case "branch":
		r, ok = of("branch", e.Details["branch"])
	}
	if !ok {
		if r, ok = of("folder", folder); !ok {
			r = wire.Ref{Provider: "agents", Type: "folder", Topic: project, ID: "-"}
		}
	}
	return r
}

// refTopic is text as a ref's topic: lower case, with no ":" or "#".
func refTopic(s string) string {
	return strings.NewReplacer(":", "-", "#", "-").Replace(strings.ToLower(s))
}

// eventTime is when the event happened, in RFC 3339: a server's own time when it said one.
func eventTime(e wire.Event) string {
	if s := e.Details["time"]; s != "" && e.Details["mcp_event_id"] != "" {
		if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
			return t.UTC().Format(time.RFC3339Nano)
		}
	}
	return e.At.Time().UTC().Format(time.RFC3339Nano)
}

// eventData is what the event carries: a server's event's data (none when it was cut, as
// it is then not whole JSON), or the app's own event's details.
func eventData(e wire.Event) json.RawMessage {
	if e.Details["mcp_event_id"] != "" {
		p := e.Details["payload"]
		if p == "" || e.Details["payload_cut"] == "true" || !json.Valid([]byte(p)) {
			return nil
		}
		return json.RawMessage(p)
	}
	b, err := json.Marshal(e.Details)
	if err != nil {
		return nil
	}
	return b
}

// envelopeMachine is this machine's name as a ref's id and an event's topic: the host's
// name before its first dot, lower case, with "-" for what a ref's topic cannot hold.
func (d *Daemon) envelopeMachine() string {
	machineNameOnce.Do(func() {
		name, _ := os.Hostname()
		name, _, _ = strings.Cut(name, ".")
		name = refTopic(strings.TrimSpace(name))
		if name == "" {
			name = "machine"
		}
		machineName = name
	})
	return machineName
}

var (
	machineNameOnce sync.Once
	machineName     string
)

// envelopeProject is the folder's project, read at most once a minute per folder.
func (d *Daemon) envelopeProject(folder string) string {
	if folder == "" {
		return ""
	}
	envelopeProjectsMu.Lock()
	defer envelopeProjectsMu.Unlock()
	if p, ok := envelopeProjects[folder]; ok && time.Since(p.at) < time.Minute {
		return p.id
	}
	if len(envelopeProjects) > 1000 {
		clear(envelopeProjects)
	}
	id := projectOfFolder(folder)
	envelopeProjects[folder] = cachedProject{id: id, at: time.Now()}
	return id
}

type cachedProject struct {
	id string
	at time.Time
}

var (
	envelopeProjectsMu sync.Mutex
	envelopeProjects   = map[string]cachedProject{}
)
