package agentsd

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"regexp"
	goruntime "runtime"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/diskjson"
	"github.com/alexec/agents/Go/internal/agentsd/redact"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Assessing a runtime (DaemonCore+Assessments, #47): starting the agent that does the
// steps, keeping the record it is scored from, and scoring it. The record is the daemon's
// own: every call an agent makes to the app's tools, as answered, in app-tools.jsonl beside
// its transcript; the transcript, the event log, the helpers and the lease book are the
// rest. The agent's report is read only for whether it is there and names the steps.

const (
	assessLabel       = "assess-runtime"
	assessHelperLabel = "assess-runtime-helper"
	assessPingEvent   = "lease.granted"
	assessNeverEvent  = "branch.moved"
	assessNeverBranch = "assess-never"
	assessLongWait    = 1440
	appToolAnswerMost = 2000
)

func (d *Daemon) registerAssess() {
	On(d, wire.CallRuntimesAssess, func(ctx context.Context, c *Client, r wire.AssessRuntimeRequest) (wire.AssessRuntimeResult, error) {
		return d.assessRuntime(r)
	})
	On(d, wire.CallRuntimesAssessment, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.RuntimeAssessmentScore, error) {
		return d.assessment(r.AgentID)
	})
}

// MARK: The record

// appToolCall is one call an agent made to the app's tools, as answered (AppToolCall).
type appToolCall struct {
	At        wire.Date                  `json:"at"`
	Method    string                     `json:"method"`
	Ok        bool                       `json:"ok"`
	Arguments map[string]json.RawMessage `json:"arguments,omitempty"`
	Answer    *string                    `json:"answer,omitempty"`
	AgentID   *wire.UUID                 `json:"agentID,omitempty"`
	Seconds   *float64                   `json:"seconds,omitempty"`
}

// appToolMethods is the method each app tool is (#2172), as app-tools.jsonl, the audit and
// Events name it: `<the tool's noun, plural>/<its verb>`, in camelCase, one a tool. A tool
// with two ways (list_sessions with started_by, wait_for_agents) is still one
// method, told apart by its arguments. ask_question is a question (#2298), so `questions/ask`.
var appToolMethods = map[string]string{
	"start_session":       "sessions/start",
	"stop_session":        "sessions/stop",
	"archive_session":     "sessions/archive",
	"list_sessions":       "sessions/list",
	"read_session":        "sessions/read",
	"message_session":     "sessions/message",
	"cancel_message":      "sessions/cancelMessage",
	"set_session_labels":  "sessions/setLabels",
	"move_worktree":       "worktrees/move",
	"show_file":           "files/show",
	"ask_question":        "questions/ask",
	"ask_secret":          "secrets/ask",
	"suggest_next_prompt": "prompts/suggest",
	"notify":              "people/notify",
	"hang_up":             "calls/hangUp",
	"manage_workflows":    "workflows/manage",
	"lease_resource":      "resources/lease",
	"release_resource":    "resources/release",
	"list_resources":      "resources/list",
	"wait_for_event":      "events/wait",
	"wait_for_agents":     "agents/wait",
	"check_again":         "waits/checkAgain",
	"cancel_wait":         "events/cancel",
	"list_machines":       "machines/list",
	"start_machine":       "machines/start",
	"stop_machine":        "machines/stop",
	"make_machine":        "machines/make",
	"delete_machine":      "machines/delete",
}

// appToolMethod is the method a tool is, or the tool's own name for one not in the table.
func appToolMethod(tool string) string {
	if m, ok := appToolMethods[tool]; ok {
		return m
	}
	return tool
}

var uuidIn = regexp.MustCompile(`[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}`)

// keepAppToolCall keeps one call, as answered: a line a call, the token never in it.
func (d *Daemon) keepAppToolCall(agent wire.UUID, tool string, args map[string]json.RawMessage, note string, err error, began time.Time) {
	call := appToolCall{At: wire.DateOf(began), Method: appToolMethod(tool), Ok: err == nil, Arguments: map[string]json.RawMessage{}}
	for k, v := range args {
		if k != "token" {
			call.Arguments[k] = v
		}
	}
	answer := note
	if err != nil {
		answer = err.Error()
		if e, ok := err.(*Error); ok {
			answer = e.Message
		}
	}
	if r := []rune(answer); len(r) > appToolAnswerMost {
		answer = string(r[:appToolAnswerMost])
	}
	call.Answer = &answer
	if tool == "start_session" && err == nil {
		if id := uuidIn.FindString(note); id != "" {
			u := wire.UUID(strings.ToUpper(id))
			call.AgentID = &u
		}
	}
	seconds := time.Since(began).Seconds()
	call.Seconds = &seconds
	b, mErr := diskjson.Marshal(call)
	if mErr != nil {
		return
	}
	path := d.appToolsPath(agent)
	os.MkdirAll(filepath.Dir(path), 0o755)
	f, oErr := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if oErr != nil {
		log.Printf("could not keep a record of an app tool call: %v", oErr)
		return
	}
	b, _ = redact.Bytes(b) // a call's arguments or answer can hold a token (#1001)
	f.Write(append(b, '\n'))
	f.Close()
}

func (d *Daemon) appToolsPath(agent wire.UUID) string {
	return filepath.Join(d.Store.Loc.Root, "agents", string(agent), "app-tools.jsonl")
}

func (d *Daemon) appToolCalls(agent wire.UUID) []appToolCall {
	b, err := os.ReadFile(d.appToolsPath(agent))
	if err != nil {
		return nil
	}
	var out []appToolCall
	for _, line := range strings.Split(string(b), "\n") {
		var c appToolCall
		if line != "" && diskjson.Unmarshal([]byte(line), &c) == nil {
			out = append(out, c)
		}
	}
	return out
}

// MARK: Starting one

// assessStart is what the daemon knew when it started one, kept as <agentID>.start.json.
type assessStart struct {
	AgentID        wire.UUID `json:"agentID"`
	RuntimeID      string    `json:"runtimeID"`
	RuntimeVersion *string   `json:"runtimeVersion,omitempty"`
	Host           string    `json:"host"`
	ReportPath     string    `json:"reportPath"`
	ScopePath      string    `json:"scopePath"`
	ShortID        string    `json:"shortID"`
}

func (d *Daemon) assessmentsPath() string { return filepath.Join(d.Store.Loc.Root, "assessments") }

// assessmentsKept is how many runtime assessments the daemon keeps (#2292).
const assessmentsKept = 50

// dropOldAssessments deletes all but the newest assessmentsKept assessments, each its
// <agentID>.start.json, its <agentID>.json score and its scope-<id>.txt (#2292). The
// reports are in the folders, and stay.
func (d *Daemon) dropOldAssessments() {
	dir := d.assessmentsPath()
	starts, _ := filepath.Glob(filepath.Join(dir, "*.start.json"))
	if len(starts) <= assessmentsKept {
		return
	}
	at := map[string]time.Time{}
	for _, p := range starts {
		if fi, err := os.Stat(p); err == nil {
			at[p] = fi.ModTime()
		}
	}
	sort.SliceStable(starts, func(i, j int) bool {
		if !at[starts[i]].Equal(at[starts[j]]) {
			return at[starts[i]].After(at[starts[j]])
		}
		return starts[i] > starts[j]
	})
	for _, p := range starts[assessmentsKept:] {
		var start assessStart
		if b, err := os.ReadFile(p); err == nil && diskjson.Unmarshal(b, &start) == nil &&
			start.ScopePath != "" && filepath.Dir(start.ScopePath) == dir {
			os.Remove(start.ScopePath)
		}
		os.Remove(strings.TrimSuffix(p, ".start.json") + ".json")
		os.Remove(p)
	}
}

// escalationTools is each runtime's own question tool the app carries (ToolPolicyCatalog).
var escalationTools = map[string]string{"claude": "AskUserQuestion", "cursor": "AskQuestion", "codex": "request_user_input",
	"antigravity": "ask_question"}

var cheapWords = []string{"haiku", "nano", "flash-lite", "lite", "mini", "flash", "small"}

// assessModel is the model asked for, the runtime's own default for "default", or else
// the cheapest it offers by the first of cheapWords any of its models carries.
func assessModel(asked *string, options []wire.ConfigOption) *string {
	if asked != nil && strings.TrimSpace(*asked) != "" {
		if strings.TrimSpace(*asked) == "default" {
			return nil
		}
		v := strings.TrimSpace(*asked)
		return &v
	}
	var model *wire.ConfigOption
	for i := range options {
		if options[i].Type == "select" && options[i].Category != nil && *options[i].Category == "model" {
			model = &options[i]
			break
		}
	}
	if model == nil {
		for i := range options {
			if options[i].Type == "select" && options[i].ID == "model" {
				model = &options[i]
				break
			}
		}
	}
	if model == nil {
		return nil
	}
	type choice struct{ value, words string }
	var choices []choice
	var walk func(raw json.RawMessage)
	walk = func(raw json.RawMessage) {
		var list []json.RawMessage
		if json.Unmarshal(raw, &list) != nil {
			return
		}
		for _, item := range list {
			var c struct {
				Value   json.RawMessage `json:"value"`
				Name    string          `json:"name"`
				Options json.RawMessage `json:"options"`
			}
			json.Unmarshal(item, &c)
			var v string
			if json.Unmarshal(c.Value, &v) == nil {
				choices = append(choices, choice{v, strings.ToLower(v + " " + c.Name)})
			}
			if len(c.Options) > 0 {
				walk(c.Options)
			}
		}
	}
	walk(json.RawMessage(model.Options))
	for _, w := range cheapWords {
		for _, c := range choices {
			if strings.Contains(c.words, w) {
				v := c.value
				return &v
			}
		}
	}
	return nil
}

// freshReportPath is .agents/reviews/runtimes/<runtime>-<date>.md, or the first -2, -3 …
// not taken: a second assessment the same day opens its report empty, as the first did.
func freshReportPath(folder, runtimeID string, at time.Time) string {
	stem := runtimeID + "-" + at.Format("2006-01-02")
	dir := filepath.Join(folder, ".agents", "reviews", "runtimes")
	path := filepath.Join(dir, stem+".md")
	for n := 2; ; n++ {
		if _, err := os.Stat(path); err != nil {
			return path
		}
		path = filepath.Join(dir, fmt.Sprintf("%s-%d.md", stem, n))
	}
}

func (d *Daemon) assessmentHost() string {
	name, _ := os.Hostname()
	if goruntime.GOOS == "darwin" {
		return "this Mac (" + name + ")"
	}
	return "the server " + name
}

func (d *Daemon) assessRuntime(r wire.AssessRuntimeRequest) (wire.AssessRuntimeResult, error) {
	rt := runtimeByID(r.RuntimeID)
	if rt == nil {
		return wire.AssessRuntimeResult{}, Invalid("There is no runtime called %s.", r.RuntimeID)
	}
	folder := filepath.Clean(store.FolderPath(r.Folder))
	// What the runtime offers here, from a draft of the session the agent then starts on.
	draft, err := d.options(wire.OptionsRequest{RuntimeID: rt.ID, Cwd: store.FolderURL(folder), McpServers: []wire.MCPServer{}})
	if err != nil {
		return wire.AssessRuntimeResult{}, err
	}
	model := assessModel(r.Model, draft.Options)
	today := nowFunc()
	report := freshReportPath(folder, rt.ID, today)
	// show_file takes a Markdown file that is not there yet only in a folder that is.
	os.MkdirAll(filepath.Dir(report), 0o755)
	day := strings.TrimPrefix(strings.TrimSuffix(filepath.Base(freshReportPathFirst(folder, rt.ID, today)), ".md"), rt.ID+"-")
	shortID := strings.ToLower(string(store.NewUUID())[:8])
	scope := filepath.Join(d.assessmentsPath(), "scope-"+shortID+".txt")
	host := d.assessmentHost()
	var version *string
	brief := assessBrief(rt.ID, rt.Name, model, version, host, report, scope, escalationTools[rt.ID], shortID, day)
	start := wire.StartRequest{RuntimeID: rt.ID, Cwd: store.FolderURL(folder), Prompt: brief, DraftID: &draft.DraftID,
		Labels: []string{assessLabel}, Attachments: []wire.Attachment{}, AdditionalDirectories: []wire.URL{}, McpServers: []wire.MCPServer{}}
	if model != nil {
		raw, _ := json.Marshal(*model)
		start.StartOptions = wire.StartOptions{Values: map[string]wire.JSONValue{"model": raw}}
	}
	id, err := d.start(start)
	if err != nil {
		return wire.AssessRuntimeResult{}, err
	}
	kept := assessStart{AgentID: id, RuntimeID: rt.ID, RuntimeVersion: version, Host: host, ReportPath: report, ScopePath: scope,
		ShortID: shortID}
	os.MkdirAll(d.assessmentsPath(), 0o755)
	if err := writeStore(filepath.Join(d.assessmentsPath(), string(id)+".start.json"), kept); err != nil {
		log.Printf("could not keep a runtime assessment's start: %v", err)
	}
	d.dropOldAssessments()
	return wire.AssessRuntimeResult{AgentID: id, Model: model, ReportPath: report}, nil
}

func freshReportPathFirst(folder, runtimeID string, at time.Time) string {
	return filepath.Join(folder, ".agents", "reviews", "runtimes", runtimeID+"-"+at.Format("2006-01-02")+".md")
}

// MARK: Scoring

// scoreAssessmentIfDue scores an assessing agent after its last turn (not one that ended
// waiting) and puts the table in its conversation.
func (d *Daemon) scoreAssessmentIfDue(id wire.UUID) {
	a := d.Store.Agent(id)
	if a == nil || a.StartedByAgent != nil {
		return
	}
	labelled := false
	for _, l := range a.Labels {
		if strings.EqualFold(strings.TrimSpace(l.Value), assessLabel) {
			labelled = true
		}
	}
	if !labelled || a.Report != nil && a.Report.Outcome == wire.WorkOutcomeWaiting {
		return
	}
	// A turn that ends on a wait still open (wait_for_event, "your place is kept") is not
	// the last: the event or the time limit starts it again (#1432).
	if a.EventWait != nil && (a.EventWait.Ending == nil || len(a.QueuedPrompts) > 0) {
		return
	}
	// A write after the turn, which Shutdown waits for: the score lands in the root.
	d.goAfterTurn("assessment", func() {
		if score, err := d.assessment(id); err == nil {
			d.record(id, runtimeNote(assessNote(score)))
		}
	})
}

// assessment scores an assessing agent now, from the record, and keeps the score.
func (d *Daemon) assessment(id wire.UUID) (wire.RuntimeAssessmentScore, error) {
	a := d.Store.Agent(id)
	if a == nil {
		return wire.RuntimeAssessmentScore{}, &Error{Code: CodeNoSuchAgent, Message: "There is no agent " + string(id) + "."}
	}
	rec := assessRecord{agent: *a, calls: d.appToolCalls(id), escalation: escalationTools[a.RuntimeID]}
	rec.transcript, _, _ = d.Store.Transcript(id, 0)
	d.eventMu.Lock()
	for _, e := range d.eventList {
		if e.At >= a.CreatedAt {
			rec.events = append(rec.events, copyEvent(e))
		}
	}
	d.eventMu.Unlock()
	helperIDs := map[wire.UUID]bool{}
	for _, c := range rec.calls {
		if c.AgentID != nil {
			helperIDs[*c.AgentID] = true
		}
	}
	for _, h := range d.Store.Agents() {
		if h.StartedByAgent != nil && *h.StartedByAgent == id || helperIDs[h.ID] {
			rec.helpers = append(rec.helpers, h)
		}
	}
	d.leaseMu.Lock()
	if d.book != nil {
		for name, e := range d.book.Entries {
			for _, l := range e.Leases {
				if l.Holder == id {
					rec.held = append(rec.held, string(name))
				}
			}
		}
	}
	d.leaseMu.Unlock()
	rec.reportPath = shownReport(rec.calls)
	if rec.reportPath != "" {
		if b, err := os.ReadFile(rec.reportPath); err == nil {
			text := string(b)
			rec.reportText = &text
		}
	}
	var start assessStart
	if b, err := os.ReadFile(filepath.Join(d.assessmentsPath(), string(id)+".start.json")); err == nil && diskjson.Unmarshal(b, &start) == nil {
		rec.start = &start
		_, err := os.Stat(filepath.Join(folderPath(a), ".agents", "workflows", "assess-"+start.ShortID+".md"))
		rec.workflowLeft = err == nil
		_, err = os.Stat(start.ScopePath)
		rec.scopeWritten = err == nil
	}
	score := rec.score(nowFunc())
	os.MkdirAll(d.assessmentsPath(), 0o755)
	if err := writeStore(filepath.Join(d.assessmentsPath(), string(id)+".json"), score); err != nil {
		log.Printf("could not keep a runtime assessment's score: %v", err)
	}
	return score, nil
}

// shownReport is the report path an agent showed: a Markdown file under
// .agents/reviews/runtimes/.
func shownReport(calls []appToolCall) string {
	for _, c := range calls {
		if c.Method != "files/show" || !c.Ok {
			continue
		}
		if p := callPath(c); strings.Contains(p, ".agents/reviews/runtimes/") && strings.HasSuffix(p, ".md") {
			return p
		}
	}
	return ""
}

// callPath is a show_file call's path: the tool's own path, or the Swift record's file.path.
func callPath(c appToolCall) string {
	if p := argString(c.Arguments, "path"); p != "" {
		return p
	}
	var file struct {
		Path string `json:"path"`
	}
	json.Unmarshal(c.Arguments["file"], &file)
	return file.Path
}

// assessNote is the note the daemon adds to the assessing agent's conversation.
func assessNote(s wire.RuntimeAssessmentScore) string {
	var about []string
	if s.RuntimeVersion != nil {
		about = append(about, *s.RuntimeVersion)
	}
	if s.Model != nil {
		about = append(about, "model "+*s.Model)
	}
	if s.Host != nil {
		about = append(about, "on "+*s.Host)
	}
	what := s.RuntimeID
	if len(about) > 0 {
		what += " (" + strings.Join(about, ", ") + ")"
	}
	passing := 0
	var failedIDs, offered []string
	lines := []string{"| Step | Area | Result | From the app's record |", "| --- | --- | --- | --- |"}
	for _, c := range s.Checks {
		words := "passed"
		switch c.Verdict {
		case wire.RuntimeAssessmentVerdictPassed:
			passing++
		case wire.RuntimeAssessmentVerdictFailed:
			failedIDs = append(failedIDs, c.ID)
			words = "**failed**"
		default:
			offered = append(offered, c.ID)
			words = "not offered"
		}
		evidence := strings.ReplaceAll(strings.ReplaceAll(c.Evidence, "|", `\|`), "\n", " ")
		lines = append(lines, "| `"+c.ID+"` | "+c.Area+" | "+words+" | "+evidence+" |")
	}
	summary := fmt.Sprintf("%d of %d passed", passing, len(s.Checks))
	if len(failedIDs) > 0 {
		summary += "; failed: " + strings.Join(failedIDs, ", ")
	}
	if len(offered) > 0 {
		summary += "; not offered: " + strings.Join(offered, ", ")
	}
	return "The app scored this assessment of " + what + " from its own record: " + summary + ".\n\n" + strings.Join(lines, "\n")
}
