package daemon

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/robfig/cron/v3"
	"gopkg.in/yaml.v3"
)

// Workflows (WorkflowFile.swift, DaemonCore+Workflows.swift): <project>/.agents/workflows/<id>.md,
// YAML front matter and a prompt. A schedule is Swift's half-hour slots (`at`, `between`,
// `days`), run here by robfig/cron; `cron:` is a key only this host reads (an unknown field
// to the Swift host), for a test that cannot wait half an hour.

type schedule struct {
	Minutes     []int    `json:"minutes"`
	Hours       [2]int   `json:"hours"`
	StartMinute int      `json:"startMinute"`
	EndMinute   int      `json:"endMinute"`
	Days        []string `json:"days"`
}

type workflow struct {
	ID       string
	Folder   string // a path
	Name     string
	Prompt   string
	Runtime  string
	Mode     string
	Labels   []string
	Enabled  bool
	Archived bool
	Unknown  map[string]any
	Triggers []map[string]any
	Sched    []schedule
	Cron     string
	Problem  string
	Digest   string

	running     bool
	lastOutcome map[string]any
	lastFiredAt *Date
	lastFiredBy map[string]any
	entries     []cron.EntryID
}

type workflows struct {
	mu    sync.Mutex
	byKey map[string]*workflow // folder + "/" + id
	cron  *cron.Cron
	off   map[string]bool // switched off by hand, kept in the root
	root  string
}

var allDays = []string{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}

func parseWorkflow(folder, id string, b []byte) *workflow {
	w := &workflow{ID: id, Folder: folder, Name: defaultName(id), Mode: "new", Enabled: true, Unknown: map[string]any{}, Triggers: []map[string]any{}}
	sum := sha256.Sum256(b)
	w.Digest = hex.EncodeToString(sum[:])
	text := string(b)
	if !strings.HasPrefix(text, "---\n") {
		w.Problem = "There is no metadata at the top"
		return w
	}
	end := strings.Index(text[4:], "\n---")
	if end < 0 {
		w.Problem = "The metadata does not end"
		return w
	}
	front := text[4 : 4+end]
	body := strings.TrimLeft(text[4+end+4:], "\n")
	w.Prompt = body
	if strings.TrimSpace(body) == "" {
		w.Problem = "There is no prompt under the metadata"
	}
	var m map[string]any
	if err := yaml.Unmarshal([]byte(front), &m); err != nil {
		w.Problem = "unreadable: " + err.Error()
		return w
	}
	for k, v := range m {
		switch k {
		case "name":
			w.Name = fmt.Sprint(v)
		case "runtime":
			w.Runtime = fmt.Sprint(v)
		case "agent":
			w.Mode = fmt.Sprint(v)
		case "enabled":
			w.Enabled = v != false
		case "archived":
			w.Archived = v == true
		case "labels":
			if l, ok := v.([]any); ok {
				for _, x := range l {
					w.Labels = append(w.Labels, fmt.Sprint(x))
				}
			}
		case "on":
			w.parseTriggers(v)
		case "cron":
			w.Cron = fmt.Sprint(v)
			w.Unknown[k] = v
		default:
			w.Unknown[k] = v
		}
	}
	return w
}

func defaultName(id string) string {
	s := strings.ReplaceAll(id, "-", " ")
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}

func (w *workflow) parseTriggers(v any) {
	list, ok := v.([]any)
	if !ok {
		list = []any{v}
	}
	for _, t := range list {
		switch x := t.(type) {
		case string:
			if x != "manual" {
				w.Triggers = append(w.Triggers, map[string]any{"unrecognised": map[string]any{"name": x, "keys": map[string]any{}}})
			}
		case map[string]any:
			for name, body := range x {
				if name != "schedule" {
					w.Triggers = append(w.Triggers, map[string]any{"unrecognised": map[string]any{"name": name, "keys": map[string]any{}}})
					continue
				}
				s, err := parseSchedule(body)
				if err != nil {
					w.Problem = "unreadable: " + err.Error()
					continue
				}
				w.Sched = append(w.Sched, s)
				w.Triggers = append(w.Triggers, map[string]any{"schedule": map[string]any{"_0": s}})
			}
		}
	}
}

func parseSchedule(v any) (schedule, error) {
	s := schedule{Hours: [2]int{0, 23}, StartMinute: 0, EndMinute: 30, Days: allDays}
	m, _ := v.(map[string]any)
	at := m["at"]
	ats, ok := at.([]any)
	if !ok && at != nil {
		ats = []any{at}
	}
	if len(ats) == 0 {
		return s, fmt.Errorf("a schedule needs at: \":00\" or \":30\"")
	}
	for _, a := range ats {
		switch fmt.Sprint(a) {
		case ":00":
			s.Minutes = append(s.Minutes, 0)
		case ":30":
			s.Minutes = append(s.Minutes, 30)
		default:
			return s, fmt.Errorf("at is \":00\" or \":30\", not %v", a)
		}
	}
	if b, ok := m["between"].(string); ok {
		var h1, m1, h2, m2 int
		if _, err := fmt.Sscanf(b, "%d:%d-%d:%d", &h1, &m1, &h2, &m2); err != nil || h1 > h2 {
			return s, fmt.Errorf("between is \"HH:MM-HH:MM\", not %q", b)
		}
		s.Hours, s.StartMinute, s.EndMinute = [2]int{h1, h2}, m1, m2
	}
	if d, ok := m["days"].([]any); ok {
		s.Days = nil
		for _, x := range d {
			s.Days = append(s.Days, strings.ToLower(fmt.Sprint(x))[:3])
		}
	}
	return s, nil
}

// specs are the cron lines for a schedule; matches checks the half-hours at either end.
func (s schedule) specs() []string {
	var out []string
	for _, m := range s.Minutes {
		out = append(out, fmt.Sprintf("%d %d-%d * * %s", m, s.Hours[0], s.Hours[1], strings.ToUpper(strings.Join(s.Days, ","))))
	}
	return out
}

func (s schedule) matches(t time.Time) bool {
	h, m := t.Hour(), t.Minute()
	if h == s.Hours[0] && m < s.StartMinute || h == s.Hours[1] && m > s.EndMinute {
		return false
	}
	return true
}

func (w *workflow) summary(total int, next *Date) map[string]any {
	wf := map[string]any{"workflowID": w.ID, "folder": "file://" + w.Folder, "name": w.Name, "triggers": w.Triggers,
		"mode": w.Mode, "prompt": w.Prompt, "unknownFields": w.Unknown,
		"settings": map[string]any{"options": map[string]any{}, "labels": orEmpty(w.Labels)}}
	if w.Runtime != "" {
		wf["settings"].(map[string]any)["runtimeID"] = w.Runtime
	}
	if !w.Enabled {
		wf["enabled"] = false
	}
	if w.Archived {
		wf["archived"] = true
	}
	if w.Problem != "" {
		wf["problem"] = map[string]any{"unreadable": map[string]any{"_0": w.Problem}}
	}
	s := map[string]any{"workflow": wf, "isArchived": w.Archived, "isEnabled": w.Enabled, "isRunning": w.running,
		"holdsAFire": false, "queued": 0, "totalLimit": total, "nextFireAtByTrigger": []any{}}
	if next != nil {
		s["nextFireAt"] = *next
	}
	// A refusal (switched off) has an outcome but no firing.
	if w.lastOutcome != nil {
		s["lastOutcome"] = w.lastOutcome
	}
	if w.lastFiredAt != nil {
		s["lastFiredAt"] = *w.lastFiredAt
		s["lastFiredBy"] = w.lastFiredBy
	}
	return s
}

func orEmpty(l []string) []string {
	if l == nil {
		return []string{}
	}
	return l
}

func (d *Daemon) startWorkflows() {
	d.wf = &workflows{byKey: map[string]*workflow{}, cron: cron.New(), off: map[string]bool{}, root: d.Root}
	if b, err := os.ReadFile(filepath.Join(d.Root, "workflows-off.json")); err == nil {
		json.Unmarshal(b, &d.wf.off)
	}
	d.wf.cron.Start()
	d.rescanWorkflows()
	go func() {
		for range time.Tick(15 * time.Second) {
			d.rescanWorkflows()
		}
	}()
}

// rescanWorkflows reads every project's workflows; a new or changed file is told to every client.
func (d *Daemon) rescanWorkflows() {
	seen := map[string]bool{}
	for _, p := range d.store.Projects() {
		folder := folderPath(p.Folder)
		dir := filepath.Join(folder, ".agents", "workflows")
		files, _ := os.ReadDir(dir)
		for _, f := range files {
			if f.IsDir() || !strings.HasSuffix(f.Name(), ".md") || strings.HasPrefix(f.Name(), ".") {
				continue
			}
			id := strings.TrimSuffix(f.Name(), ".md")
			key := folder + "/" + id
			seen[key] = true
			b, err := os.ReadFile(filepath.Join(dir, f.Name()))
			if err != nil {
				continue
			}
			d.wf.mu.Lock()
			old := d.wf.byKey[key]
			if old != nil && old.Digest == fmt.Sprintf("%x", sha256.Sum256(b)) {
				d.wf.mu.Unlock()
				continue
			}
			w := parseWorkflow(folder, id, b)
			if d.wf.off[key] {
				w.Enabled = false
			}
			if old != nil {
				w.running, w.lastOutcome, w.lastFiredAt, w.lastFiredBy = old.running, old.lastOutcome, old.lastFiredAt, old.lastFiredBy
				for _, e := range old.entries {
					d.wf.cron.Remove(e)
				}
			}
			d.wf.byKey[key] = w
			d.schedule(w)
			d.wf.mu.Unlock()
			log.Printf("workflows: %s in %s (%d triggers)", id, folder, len(w.Triggers))
			d.announceWorkflow(w)
		}
	}
	d.wf.mu.Lock()
	var gone []*workflow
	for k, w := range d.wf.byKey {
		if !seen[k] {
			gone = append(gone, w)
			for _, e := range w.entries {
				d.wf.cron.Remove(e)
			}
			delete(d.wf.byKey, k)
		}
	}
	d.wf.mu.Unlock()
	for _, w := range gone {
		d.Broadcast("workflow/removed", map[string]any{"folder": "file://" + w.Folder, "workflowID": w.ID})
	}
}

// schedule puts a workflow's triggers on the clock (the lock is held).
func (d *Daemon) schedule(w *workflow) {
	add := func(spec string, s *schedule) {
		id, err := d.wf.cron.AddFunc(spec, func() {
			if s != nil && !s.matches(time.Now()) {
				return
			}
			trigger := map[string]any{"unrecognised": map[string]any{"name": "cron", "keys": map[string]any{"cron": spec}}}
			if s != nil {
				trigger = map[string]any{"schedule": map[string]any{"_0": *s}}
			}
			d.fire(w.Folder, w.ID, map[string]any{"trigger": map[string]any{"_0": trigger}})
		})
		if err != nil {
			log.Printf("workflows: %s: %q: %v", w.ID, spec, err)
			return
		}
		w.entries = append(w.entries, id)
	}
	for i := range w.Sched {
		for _, spec := range w.Sched[i].specs() {
			add(spec, &w.Sched[i])
		}
	}
	if w.Cron != "" {
		add(w.Cron, nil)
	}
}

func (d *Daemon) nextFire(w *workflow) *Date {
	var next time.Time
	for _, id := range w.entries {
		e := d.wf.cron.Entry(id)
		if !e.Next.IsZero() && (next.IsZero() || e.Next.Before(next)) {
			next = e.Next
		}
	}
	if next.IsZero() || !w.Enabled || w.Archived {
		return nil
	}
	t := FromTime(next)
	return &t
}

func (d *Daemon) workflowSummary(w *workflow) map[string]any {
	return w.summary(10, d.nextFire(w))
}

func (d *Daemon) announceWorkflow(w *workflow) {
	d.wf.mu.Lock()
	s := d.workflowSummary(w)
	d.wf.mu.Unlock()
	d.Broadcast("workflow/changed", s)
}

// fire is one run: an agent started in the project folder with the body as its prompt.
func (d *Daemon) fire(folder, id string, by map[string]any) (map[string]any, error) {
	d.wf.mu.Lock()
	w := d.wf.byKey[folder+"/"+id]
	if w == nil {
		d.wf.mu.Unlock()
		return nil, &RPCError{Code: -32602, Message: "There is no workflow " + id + " here."}
	}
	_, byHand := by["byHand"]
	switch {
	case w.Archived:
		d.wf.mu.Unlock()
		return nil, &RPCError{Code: -32000, Message: "That workflow is archived."}
	case !w.Enabled && !byHand:
		w.lastOutcome = map[string]any{"refused": map[string]any{"_0": map[string]any{"disabled": map[string]any{}}, "at": Now(), "repeats": 1}}
		d.wf.mu.Unlock()
		d.announceWorkflow(w)
		return nil, nil
	case w.Problem != "":
		d.wf.mu.Unlock()
		return nil, &RPCError{Code: -32000, Message: w.Problem}
	case w.running:
		d.wf.mu.Unlock()
		return nil, &RPCError{Code: -32000, Message: "That workflow is running already."}
	}
	w.running = true
	runtime := w.Runtime
	if runtime == "" {
		runtime = "claude"
	}
	prompt, name, labels := w.Prompt, w.Name, w.Labels
	d.wf.mu.Unlock()
	if err := d.needsSignIn(runtime); err != nil {
		d.wf.mu.Lock()
		w.running = false
		d.wf.mu.Unlock()
		return nil, err
	}
	agentID, err := d.startAs(runtime, folderURL(folder), prompt, func(a *Agent) {
		a.Title, a.StartedByWorkflow, a.StartedByRun = name, id, NewUUID()
		if len(labels) > 0 {
			l := []map[string]any{}
			for _, x := range labels {
				l = append(l, map[string]any{"value": x, "owner": "agent", "addedAt": Now()})
			}
			a.Labels, _ = json.Marshal(l)
		}
	})
	now := Now()
	d.wf.mu.Lock()
	if err != nil {
		w.running = false
		d.wf.mu.Unlock()
		return nil, err
	}
	w.lastOutcome = map[string]any{"ran": map[string]any{"agentID": agentID, "at": now}}
	w.lastFiredAt, w.lastFiredBy = &now, by
	s := d.workflowSummary(w)
	d.wf.mu.Unlock()
	log.Printf("workflows: %s ran as %s", id, agentID)
	d.Broadcast("workflow/changed", s)
	return s, nil
}

// workflowAgentEnded is called when an agent's turn ends: its workflow is no longer running.
func (d *Daemon) workflowAgentEnded(a *Agent) {
	if a.StartedByWorkflow == "" || d.wf == nil {
		return
	}
	d.wf.mu.Lock()
	w := d.wf.byKey[folderPath(a.Cwd)+"/"+a.StartedByWorkflow]
	if w == nil || !w.running {
		d.wf.mu.Unlock()
		return
	}
	w.running = false
	d.wf.mu.Unlock()
	d.announceWorkflow(w)
}

func (d *Daemon) allWorkflows(folder string) []map[string]any {
	d.wf.mu.Lock()
	defer d.wf.mu.Unlock()
	out := []map[string]any{}
	var ws []*workflow
	for _, w := range d.wf.byKey {
		if folder == "" || w.Folder == folderPath(folder) {
			ws = append(ws, w)
		}
	}
	sort.Slice(ws, func(i, j int) bool { return ws[i].Name < ws[j].Name })
	for _, w := range ws {
		out = append(out, d.workflowSummary(w))
	}
	return out
}

func (d *Daemon) registerWorkflows() {
	type req struct {
		Folder     string `json:"folder"`
		WorkflowID string `json:"workflowID"`
		Enabled    *bool  `json:"enabled"`
		Archived   *bool  `json:"archived"`
	}
	d.Handle("workflows/list", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[req](p)
		return d.allWorkflows(r.Folder), nil
	})
	d.Handle("workflows/run", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[req](p)
		return d.fire(folderPath(r.Folder), r.WorkflowID, map[string]any{"byHand": map[string]any{}})
	})
	d.Handle("workflows/enable", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) {
		r, _ := decode[req](p)
		key := folderPath(r.Folder) + "/" + r.WorkflowID
		d.wf.mu.Lock()
		w := d.wf.byKey[key]
		if w == nil || r.Enabled == nil {
			d.wf.mu.Unlock()
			return nil, &RPCError{Code: -32602, Message: "There is no workflow " + r.WorkflowID + " here."}
		}
		w.Enabled = *r.Enabled
		if w.Enabled {
			delete(d.wf.off, key)
		} else {
			d.wf.off[key] = true
		}
		b, _ := json.Marshal(d.wf.off)
		os.WriteFile(filepath.Join(d.Root, "workflows-off.json"), b, 0o600)
		s := d.workflowSummary(w)
		d.wf.mu.Unlock()
		d.Broadcast("workflow/changed", s)
		return s, nil
	})
	d.Handle("workflows/limit", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) { return empty(), nil })
	d.Handle("workflows/setLimit", func(ctx context.Context, c *Client, p json.RawMessage) (any, error) { return empty(), nil })
}

// tellWorkflows sends one client every workflow, as the window never asks a server for
// them (it calls workflows/list on the Mac only) and learns them from workflow/changed.
func (d *Daemon) tellWorkflows(c *Client) {
	if d.wf == nil {
		return
	}
	for _, s := range d.allWorkflows("") {
		c.Notify("workflow/changed", s)
	}
}

var _ = bytes.NewReader
var _ = context.Background
