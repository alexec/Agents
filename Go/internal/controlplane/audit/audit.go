// Package audit is who did what (#996, spec 736 US8, T3): the control plane writes an
// entry for each action a client takes through it, with the actor it knows the client by,
// never one the client names. Entries are the control plane's events, under
// <prefix>/v1/events/<day>/by/<person>/, kept for auditDays (90 by default) and swept by
// day. The person in the key lets a member's list read only their own entries (#2051).
//
// Until people (#994) are built, a control plane has one person, the local owner, and
// every client is theirs: every actor is the local owner and the client it used.
package audit

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"path"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

const (
	// DefaultDays is how long entries are kept when control.json says nothing (FR-040).
	DefaultDays = 90
	// MostDays bounds what an admin may set: ten years.
	MostDays = 3650
	// Grace is how long the sweep still keeps the days before a shorter time (#2067).
	Grace = 24 * time.Hour
	// Prefix is where entries live: the control plane's events.
	Prefix    = "v1/events/"
	dayLayout = "2006-01-02"
	// byPerson is the folder under a day that holds each person's entries.
	byPerson = "by/"
	// Kind is an entry's kind, beside the control plane's own events (clientPaired, …).
	Kind = "audit"

	defaultLimit = 200
	mostLimit    = 1000
	// mostExported bounds an export, so that one answer stays a size a client can hold.
	mostExported = 50_000
	mostTarget   = 120
	// LocalOwnerName is the one person's name until people have names of their own (#994).
	LocalOwnerName = "Local owner"
)

// hostActions are the calls passed to a host that the audit keeps (spec 736 US8 #1): start,
// stop or delete an agent; answer a card; change a setting; approve a workflow, a plugin
// or an MCP server. Reads, prompts and presence are not kept.
var hostActions = map[string]string{
	"agents/start":             "Started an agent",
	"agents/stop":              "Stopped an agent",
	"agents/stopBackground":    "Stopped an agent's background work",
	"agents/delete":            "Deleted an agent",
	"agents/archive":           "Archived an agent",
	"agents/unarchive":         "Unarchived an agent",
	"agents/fork":              "Forked an agent",
	"agents/branchFrom":        "Branched an agent",
	"agents/continueInFolder":  "Continued an agent in a folder",
	"sessions/delete":          "Deleted a session",
	"approvals/answer":         "Answered an approval",
	"permissions/answer":       "Answered a permission card",
	"elicitations/answer":      "Answered a question card",
	"agents/answerSandbox":     "Answered a sandbox card",
	"agents/setSandbox":        "Changed an agent's sandbox",
	"agents/setCeiling":        "Changed an agent's cost ceiling",
	"preferences/set":          "Changed a setting",
	"cost/setLimits":           "Changed the cost limits",
	"wake/set":                 "Changed the wake settings",
	"folders/setDiskSpace":     "Changed a folder's disk space",
	"folders/setHelperLimits":  "Changed a folder's helper limits",
	"runtimes/setProvider":     "Changed a runtime's provider",
	"runtimes/disableProvider": "Turned off a runtime's provider",
	"runtimes/install":         "Installed a runtime",
	"runtimes/logout":          "Signed a runtime out",
	"workflows/approve":        "Approved a workflow",
	"workflows/deny":           "Denied a workflow",
	"workflows/enable":         "Turned a workflow on or off",
	"workflows/run":            "Ran a workflow",
	"workflows/archive":        "Archived a workflow",
	"workflows/delete":         "Deleted a workflow",
	"plugins/approve":          "Approved a plugin",
	"mcp/approve":              "Approved an MCP server",
	"mcp/add":                  "Added an MCP server",
	"mcp/add-by-hand":          "Added an MCP server",
	"mcp/remove":               "Removed an MCP server",
	"mcp/set-secret":           "Set an MCP server's secret",
	"skills/add":               "Added a skill",
	"skills/remove":            "Removed a skill",
	"marketplaces/add":         "Added a marketplace",
	"marketplaces/remove":      "Removed a marketplace",
	"marketplaces/set-enabled": "Turned a marketplace on or off",
	"folders/add":              "Added a folder",
	"folders/delete":           "Deleted a folder",
	"folders/archive":          "Archived a folder",
	"worktrees/remove":         "Removed a worktree",
	"resources/declare":        "Declared a resource",
	"resources/remove":         "Removed a resource",
	"connections/disconnect":   "Disconnected an account",
	"credentials/lend":         "Lent a sign-in",
	"daemon/quit":              "Quit a host",
}

// controlActions are the control plane's own methods that the audit keeps.
var controlActions = map[string]string{
	"clients/forget":             "Forgot a client",
	"clients/forgetSelf":         "Forgot a client",
	"devices/forget":             "Forgot a client",
	"hosts/remove":            "Removed a machine",
	"clients/startPairing":       "Made a pairing code",
	"devices/startPairing":       "Made a pairing code",
	"hosts/startEnroll":       "Made a machine code",
	"hosts/install":           "Installed a machine over ssh",
	"hosts/update":            "Updated a machine",
	"hosts/setRelay":          "Changed a machine's relay",
	"hosts/lendSignIn":        "Lent a sign-in to a machine",
	"hosts/lendGit":           "Lent git access to a machine",
	"hosts/detect":            "Added the machines it found",
	"control/setFolderDetection": "Changed folder detection",
	"control/setAuditDays":       "Changed how long the audit is kept",
	"audit/setSinks":             "Changed where the audit is sent",
	"control/rotate":             "Rotated the control key",
	"policy/set":                 "Changed the organisation's policy",
	"policy/stopAll":             "Turned the kill switch on or off",
	"policy/raise":               "Raised a person's budget for today",
	"orgRoutes/set":              "Added or changed an org route",
	"orgRoutes/replaceKey":       "Replaced an org route's key",
	"orgRoutes/check":            "Checked an org route",
	"orgRoutes/remove":           "Removed an org route",
	"providers/add":              "Added a machine provider",
	"providers/create":           "Added a machine provider",
	"providers/update":           "Changed a machine provider",
	"providers/remove":           "Removed a machine provider",
	"hosts/start":             "Started a workspace",
	"hosts/stop":              "Stopped a workspace",
	"hosts/deleteMachine":     "Deleted a workspace",
	"hosts/link":              "Linked a machine to a workspace",
	"hosts/unlink":            "Unlinked a machine from its workspace",

	// Org sign-in (#1002, FR-025): each writes its own entry, with what changed and no secret.
	"signIn/orgProviders/set":    "Added or changed an org sign-in provider",
	"signIn/orgProviders/check":  "Checked an org sign-in provider",
	"signIn/orgProviders/remove": "Removed an org sign-in provider",
	"signIn/domains/claim":       "Claimed a domain",
	"signIn/domains/check":       "Checked a domain",
	"signIn/domains/set":         "Changed a domain's sign-in",
	"signIn/domains/remove":      "Removed a domain's claim",
	"signIn/domains/lost":        "Lost a domain's proof",
	"signIn/ticket":              "Signed in with an org provider",
	"signIn/refusedByRequire":    "Refused a sign-in the organisation does not allow",

	// SCIM and suspension (#1002, slice 2a, FR-025): each writes its own entry. A SCIM
	// write's actor is the provider and its token's id, never its value.
	"scim/set":           "Turned SCIM on or off",
	"scim/tokens/make":   "Made a SCIM token",
	"scim/tokens/revoke": "Revoked a SCIM token",
	"groups/setRole":     "Changed the role a group gives",
	"scim/user/create":   "Added a person by SCIM",
	"scim/user/change":   "Changed a person by SCIM",
	"scim/user/delete":   "Deleted a person by SCIM",
	"scim/group/create":  "Added a group by SCIM",
	"scim/group/change":  "Changed a group by SCIM",
	"scim/group/delete":  "Deleted a group by SCIM",
	"person/suspended":   "Suspended a person",
	"person/unsuspended": "Ended a person's suspension",

	// Catalogue governance (#2019, M5): each writes its own entry, naming the item.
	"governance/asked":    "Asked for an MCP server or skill",
	"governance/approved": "Approved an MCP server or skill",
	"governance/refused":  "Refused an MCP server or skill",
	"governance/revoked":  "Took back an approval of an MCP server or skill",
	// The read API (#2019): each writes its own entry, naming the token, never its value.
	"readApi/made":    "Made a read API token",
	"readApi/revoked": "Revoked a read API token",
}

// Action is what a call is in words, and whether the audit keeps it at all. toHost is a
// call passed to a host; otherwise it is the control plane's own.
func Action(method string, toHost bool) (string, bool) {
	if toHost {
		a, ok := hostActions[method]
		return a, ok
	}
	a, ok := controlActions[method]
	return a, ok
}

// HostMethods are the calls passed to a host that the audit keeps, sorted.
func HostMethods() []string {
	out := make([]string, 0, len(hostActions))
	for m := range hostActions {
		out = append(out, m)
	}
	sort.Strings(out)
	return out
}

// targetKeys are where a call names what it acts on, most telling first.
var targetKeys = []string{"agentID", "id", "workflowID", "key", "server", "name", "host", "provider",
	"permissionID", "requestID", "cwd", "folder", "path"}

// Target is what a call acts on, as its params name it: an agent, a workflow, a server,
// a folder. Never a prompt or a secret's value.
func Target(params json.RawMessage) *string {
	var o map[string]json.RawMessage
	if json.Unmarshal(params, &o) != nil {
		return nil
	}
	for _, k := range targetKeys {
		var s string
		if json.Unmarshal(o[k], &s) == nil && strings.TrimSpace(s) != "" {
			s = strings.TrimPrefix(strings.TrimSpace(s), "file://")
			if len(s) > mostTarget {
				s = s[:mostTarget] + "…"
			}
			return &s
		}
	}
	return nil
}

// Days is how long entries are kept: what control.json says, or the default.
func Days(settings *records.Settings) int {
	if settings != nil && settings.AuditDays != nil && *settings.AuditDays > 0 {
		return *settings.AuditDays
	}
	return DefaultDays
}

// SweepDays is how many days the sweep keeps: Days, or for a day after it was made
// shorter, the days before (#2067).
func SweepDays(settings *records.Settings, now time.Time) int {
	days := Days(settings)
	if settings != nil && settings.AuditDaysBefore != nil && settings.AuditShortened != nil &&
		now.Before(settings.AuditShortened.Add(Grace)) && *settings.AuditDaysBefore > days {
		return *settings.AuditDaysBefore
	}
	return days
}

// SetDays is control/setAuditDays on the settings at now: a shorter time keeps what the
// sweep keeps now for Grace, and a time as long as that ends the grace (#2067).
func SetDays(s *records.Settings, days int, now time.Time) {
	keep := SweepDays(s, now)
	s.AuditDays = &days
	if days < keep {
		stamp := records.At(now)
		s.AuditDaysBefore, s.AuditShortened = &keep, &stamp
	} else {
		s.AuditDaysBefore, s.AuditShortened = nil, nil
	}
}

// stored is an entry as the store keeps it, beside the control plane's own events.
type stored struct {
	Kind   string           `json:"kind"`
	Action string           `json:"action,omitempty"`
	Method string           `json:"method,omitempty"`
	Host   *string          `json:"host,omitempty"`
	Target *string          `json:"target,omitempty"`
	At     records.Stamp    `json:"at"`
	By     string           `json:"by,omitempty"`
	Actor  *wire.AuditActor `json:"actor,omitempty"`
	// The chain this entry is in (#1001): the copy that wrote it, its place in that copy's
	// entries, and the SHA-256 of the stored bytes of the one before (none for the first).
	Chain string `json:"chain,omitempty"`
	Seq   int64  `json:"seq,omitempty"`
	Prev  string `json:"prev,omitempty"`
}

// Log writes and reads the entries.
type Log struct {
	Store store.Store
	Now   func() time.Time
	// Chain links what this copy writes (#1001); nil writes entries in no chain.
	Chain *Chain
	// Out hears each entry kept, for the sinks (#1001); nil sends nowhere.
	Out func(key string, data []byte)
}

func (l *Log) now() time.Time {
	if l.Now != nil {
		return l.Now()
	}
	return time.Now()
}

// Key is where an entry made at t by user goes: by day, then by person, then by the
// millisecond, so a person's keys for a day sort by time.
func Key(t time.Time, user string) string {
	t = t.UTC()
	return fmt.Sprintf("%s%013d-%s.json", dayPrefix(t.Format(dayLayout), user), t.UnixMilli(), strings.ToLower(records.NewUUID()[:8]))
}

// dayPrefix is the folder of a day's entries, or of one person's entries that day. The
// name is base64, so that no name makes a path of its own ("..", "/").
func dayPrefix(day, user string) string {
	if user == "" {
		return Prefix + day + "/"
	}
	return Prefix + day + "/" + byPerson + base64.RawURLEncoding.EncodeToString([]byte(user)) + "/"
}

// Write keeps one action. The store's create-only write means two copies never write
// over each other.
func (l *Log) Write(ctx context.Context, actor wire.AuditActor, method, action string, host string, target *string) error {
	at := l.now()
	e, key := entry(actor, method, action, host, target, at)
	var data []byte
	var err error
	if l.Chain != nil {
		data, err = l.Chain.write(ctx, l.Store, &e, key, at)
	} else if data, err = records.Encode(e); err == nil {
		_, err = l.Store.Put(ctx, key, data, store.Absent)
	}
	if err == nil && l.Out != nil {
		l.Out(key, data)
	}
	return err
}

// entry is what Write and a Writer keep, and where.
func entry(actor wire.AuditActor, method, action string, host string, target *string, at time.Time) (stored, string) {
	e := stored{Kind: Kind, Action: action, Method: method, Target: target, At: records.At(at), Actor: &actor}
	if actor.Client != nil {
		e.By = string(*actor.Client)
	}
	if host != "" {
		e.Host = &host
	}
	return e, Key(at, actor.User)
}

// decode reads one stored event as an entry. The control plane's own events between
// copies (clientPaired, hostRemoved, …) are not entries: the call that made each is.
func decode(key string, data []byte, owner func(by string) wire.AuditActor) (wire.AuditEntry, bool) {
	var s stored
	if json.Unmarshal(data, &s) != nil || s.At.IsZero() {
		return wire.AuditEntry{}, false
	}
	e := wire.AuditEntry{ID: strings.TrimSuffix(strings.TrimPrefix(key, Prefix), ".json"), At: wire.DateOf(s.At.Time),
		Action: s.Action, Method: s.Method, Target: s.Target}
	if s.Host != nil {
		h := wire.MachineRef(*s.Host)
		e.Host = &h
	}
	if s.Kind != Kind {
		return wire.AuditEntry{}, false
	}
	if s.Actor != nil {
		e.Actor = *s.Actor
	} else {
		e.Actor = owner(s.By)
	}
	return e, true
}

// Query is a list or an export asked for: the range, and whose entries. Only is set for
// a caller who sees only their own.
type Query struct {
	Since, Until time.Time
	User         string
	Limit        int
	Oldest       bool
}

// NewQuery is a wire query bounded: at most days back, at most mostLimit entries.
func NewQuery(q wire.AuditQuery, days int, now time.Time, export bool) Query {
	out := Query{Since: now.Add(-time.Duration(days) * 24 * time.Hour), Until: now, Limit: defaultLimit}
	if q.Since != nil && q.Since.Time().After(out.Since) {
		out.Since = q.Since.Time()
	}
	if q.Until != nil && q.Until.Time().Before(out.Until) {
		out.Until = q.Until.Time()
	}
	if q.User != nil {
		out.User = *q.User
	}
	if q.Limit != nil && *q.Limit > 0 {
		out.Limit = int(*q.Limit)
	}
	out.Limit = min(out.Limit, mostLimit)
	if export {
		out.Limit, out.Oldest = mostExported, true
	}
	return out
}

// List is the entries in the query's range, newest first (or oldest first for an
// export), and whether more were left out. It reads a day's keys at a time, from the
// newest day, and stops once it has enough. A query for one person lists and reads only
// that person's folder of each day, never the team's entries (#2051).
func (l *Log) List(ctx context.Context, q Query, owner func(by string) wire.AuditActor) ([]wire.AuditEntry, bool, error) {
	var days []string
	for d := q.Until.UTC(); !d.Before(q.Since.UTC().Truncate(24 * time.Hour)); d = d.Add(-24 * time.Hour) {
		days = append(days, d.Format(dayLayout))
	}
	if q.Oldest {
		for i, j := 0, len(days)-1; i < j; i, j = i+1, j-1 {
			days[i], days[j] = days[j], days[i]
		}
	}
	out := []wire.AuditEntry{}
	for _, day := range days {
		keys, err := l.Store.List(ctx, dayPrefix(day, q.User))
		if err != nil {
			return nil, false, err
		}
		// A day's keys are in folders by person: the file's name is the time.
		sort.Slice(keys, func(i, j int) bool {
			a, b := path.Base(keys[i].Key), path.Base(keys[j].Key)
			if q.Oldest {
				return a < b
			}
			return a > b
		})
		for _, k := range keys {
			object, err := l.Store.Get(ctx, k.Key)
			if err != nil {
				return nil, false, err
			}
			if object == nil {
				continue
			}
			e, ok := decode(k.Key, object.Data, owner)
			if !ok {
				continue
			}
			at := e.At.Time()
			if at.Before(q.Since) || at.After(q.Until) || q.User != "" && e.Actor.User != q.User {
				continue
			}
			if len(out) == q.Limit {
				return out, true, nil
			}
			out = append(out, e)
		}
	}
	return out, false, nil
}

// Lines is entries as JSON lines (FR-041's export).
func Lines(entries []wire.AuditEntry) string {
	var b bytes.Buffer
	for _, e := range entries {
		line, err := json.Marshal(e)
		if err != nil {
			continue
		}
		b.Write(line)
		b.WriteByte('\n')
	}
	return b.String()
}

// Expired says whether an event's key is older than days before now: what the sweep
// deletes.
func Expired(key string, days int, now time.Time) bool {
	return KeyDay(key) < Cutoff(days, now)
}

// KeyDay is the day in an event's key.
func KeyDay(key string) string {
	day, _, _ := strings.Cut(strings.TrimPrefix(key, Prefix), "/")
	return day
}

// Cutoff is the first day kept: every day before it has expired.
func Cutoff(days int, now time.Time) string {
	return now.Add(-time.Duration(days) * 24 * time.Hour).UTC().Format(dayLayout)
}

// DayFolder is the folder of a day's entries, every person's.
func DayFolder(day string) string { return dayPrefix(day, "") }

// NextDay is the day after day, or "" for one that is not a day.
func NextDay(day string) string {
	t, err := time.Parse(dayLayout, day)
	if err != nil {
		return ""
	}
	return t.AddDate(0, 0, 1).Format(dayLayout)
}
