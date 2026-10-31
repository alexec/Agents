package agentsd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// manage_workflows, and the words a workflow is listed in, as DaemonCore+AppTools and
// Workflow.summary say them on the Swift host. An agent works on its own folder's
// workflows; what it writes starts off, and waits for the person's OK.

func clock12(hour, minute int64) string {
	suffix := "am"
	if hour >= 12 {
		suffix = "pm"
	}
	twelve := hour % 12
	if twelve == 0 {
		twelve = 12
	}
	if minute == 0 {
		return fmt.Sprintf("%d%s", twelve, suffix)
	}
	return fmt.Sprintf("%d:%02d%s", twelve, minute, suffix)
}

// scheduleSummary is WorkflowSchedule.summary.
func scheduleSummary(s wire.WorkflowSchedule) string {
	has := map[int64]bool{}
	for _, m := range s.Minutes {
		has[m] = true
	}
	when := "on the hour"
	if has[0] && has[30] {
		when = "on the hour and half hour"
	} else if has[30] {
		when = "on the half hour"
	}
	days := map[wire.Weekday]bool{}
	for _, d := range s.Days {
		days[d] = true
	}
	all := []wire.Weekday{"sun", "mon", "tue", "wed", "thu", "fri", "sat"}
	dayPart := ""
	switch {
	case len(days) == 7:
		dayPart = "Every day"
	case len(days) == 5 && !days["sun"] && !days["sat"]:
		dayPart = "Every weekday"
	default:
		var names []string
		for _, d := range all {
			if days[d] {
				names = append(names, strings.ToUpper(string(d)[:1])+string(d)[1:])
			}
		}
		dayPart = strings.Join(names, ", ")
	}
	if s.Hours == [2]int64{0, 23} {
		return dayPart + " " + when
	}
	if s.Hours[0] == s.Hours[1] && len(s.Minutes) == 1 {
		return dayPart + " at " + clock12(s.Hours[0], s.Minutes[0])
	}
	end := int64(0)
	if s.EndMinute == 30 && has[30] {
		end = 30
	}
	return dayPart + " " + when + " between " + clock12(s.Hours[0], s.StartMinute) + " and " + clock12(s.Hours[1], end)
}

// patternSummary is EventPattern.summary.
func patternSummary(p waitPattern) string {
	meaning := p.name
	if subject, ok := strings.CutSuffix(p.name, ".*"); ok && isSubject(subject) {
		meaning = "Anything about " + subject + "s"
	} else if k := kindNamed(p.name); k != nil {
		meaning = strings.TrimSuffix(k.Meaning, ".")
	}
	if len(p.filters) == 0 {
		return meaning
	}
	var keys []string
	for k := range p.filters {
		keys = append(keys, k)
	}
	sortStrings(keys)
	var narrowed []string
	for _, k := range keys {
		narrowed = append(narrowed, k+" "+strings.Join(p.filters[k], " or "))
	}
	return meaning + " (" + strings.Join(narrowed, ", ") + ")"
}

func lowercasedFirst(t string) string {
	if t == "" || strings.HasPrefix(t, "A ") {
		return t
	}
	r := []rune(t)
	if r[0] >= 'A' && r[0] <= 'Z' {
		r[0] += 'a' - 'A'
	}
	return string(r)
}

// triggerSummary is WorkflowTrigger.summary.
func triggerSummary(t wire.WorkflowTrigger) string {
	if t.Schedule != nil {
		return scheduleSummary(t.Schedule.Value)
	}
	if p, ok := triggerPattern(t); ok {
		return "When " + lowercasedFirst(patternSummary(p))
	}
	if mt, ok := serverTrigger(t); ok {
		return mt.summary()
	}
	name := triggerName(t)
	guess := ""
	if g := closestEvent(name); g != "" {
		guess = ". Did you mean " + g + "?"
	}
	return "Waits for \"" + name + "\", which this version does not know about yet" + guess
}

func cooldownWords(seconds float64) string {
	left := int(seconds / 60)
	var parts []string
	for _, u := range []struct {
		unit    string
		minutes int
	}{{"day", 1440}, {"hour", 60}, {"minute", 1}} {
		if left >= u.minutes {
			n := left / u.minutes
			s := ""
			if n != 1 {
				s = "s"
			}
			parts = append(parts, fmt.Sprintf("%d %s%s", n, u.unit, s))
			left %= u.minutes
		}
	}
	return strings.Join(parts, " ")
}

func settingsSummary(s wire.WorkflowSettings) string {
	var clauses []string
	if s.PermissionMode != nil {
		clauses = append(clauses, "in "+*s.PermissionMode+" mode")
	}
	if s.RuntimeID != nil && *s.RuntimeID != defaultRuntimeID {
		clauses = append(clauses, "on "+runtimeName(*s.RuntimeID))
	}
	if s.Model != nil {
		clauses = append(clauses, "using "+*s.Model)
	}
	if s.Effort != nil {
		clauses = append(clauses, "at "+*s.Effort+" effort")
	}
	var ids []string
	for id := range s.Options {
		ids = append(ids, id)
	}
	sortStrings(ids)
	for _, id := range ids {
		switch strings.ToLower(s.Options[id]) {
		case "true", "yes", "on":
			clauses = append(clauses, "with "+id)
		case "false", "no", "off":
			clauses = append(clauses, "without "+id)
		default:
			clauses = append(clauses, "with "+id+" "+s.Options[id])
		}
	}
	return strings.Join(clauses, ", ")
}

func problemMessage(p wire.WorkflowProblem) string {
	switch {
	case p.Unreadable != nil:
		return p.Unreadable.Value
	case p.TriggerNotSupported != nil:
		guess := ""
		if g := closestEvent(p.TriggerNotSupported.Value); g != "" {
			guess = ". Did you mean " + g + "?"
		}
		return "Waits for \"" + p.TriggerNotSupported.Value + "\", which this version does not know about yet" + guess
	case p.UnsupportedMode != nil:
		return "Runs \"" + p.UnsupportedMode.Value + "\", which this version does not know about yet"
	}
	return ""
}

// workflowSummaryWords is Workflow.summary.
func workflowSummaryWords(w wire.Workflow) string {
	if w.Problem != nil {
		return problemMessage(*w.Problem)
	}
	var supported []wire.WorkflowTrigger
	for _, t := range w.Triggers {
		if triggerSupported(t) {
			supported = append(supported, t)
		}
	}
	if len(supported) == 0 && len(w.Triggers) > 0 {
		return triggerSummary(w.Triggers[0])
	}
	part := "By hand, with Run now"
	if len(w.Triggers) > 0 {
		var each []string
		for _, t := range supported {
			each = append(each, triggerSummary(t))
		}
		part = strings.Join(each, ", and ")
	}
	mode := map[wire.WorkflowMode]string{wire.WorkflowModeNew: "in a new agent", wire.WorkflowModeStanding: "in its own standing agent",
		wire.WorkflowModeTriggering: "in the agent that triggered it"}[w.Mode]
	base := part + ", " + mode
	if w.Cooldown != nil {
		base += ", at most once every " + cooldownWords(*w.Cooldown)
	}
	if s := settingsSummary(w.Settings); w.Mode != wire.WorkflowModeTriggering && s != "" {
		base += ", " + s
	}
	return base
}

// outcomeSummary is WorkflowOutcome.summary.
func outcomeWords(o wire.WorkflowOutcome) string {
	if o.Ran != nil {
		return "Ran"
	}
	r, n := o.Refused.Value, o.Refused.Repeats
	m := refusalWords(r)
	switch {
	case r.CoolingDown != nil && n > 1:
		return fmt.Sprintf("Waiting — %d triggers held into one run, as %s", n, m)
	case r.CoolingDown != nil:
		return "Waiting — " + m
	case r.Queued != nil && n > 1:
		return fmt.Sprintf("Queued — %d triggers, each to run in turn, as %s", n, m)
	case r.Queued != nil:
		return "Queued — " + m
	case r.MissedWhileClosed != nil && n > 1:
		return fmt.Sprintf("Missed %d times — %s", n, m)
	case r.MissedWhileClosed != nil:
		return "Missed — " + m
	case n > 1:
		return fmt.Sprintf("Did not run %d times — %s", n, m)
	}
	return "Did not run — " + m
}

func neverHereWorkflow(w wire.Workflow) string {
	var names []string
	for _, t := range w.Triggers {
		if p, ok := triggerPattern(t); ok && isMacOnly(p.name) {
			names = append(names, p.name)
		}
	}
	if len(names) == 0 {
		return ""
	}
	return neverHereWords(names)
}

func notInFolder(id string) error {
	if id == "" {
		id = "that"
	}
	return &Error{Code: wire.FailureNotInWorkflowFolder, Message: "Workflows can only be read and written inside this folder's .agents/workflows, and " +
		id + " is not a name in it."}
}

// manageWorkflows is manage_workflows.
func (d *Daemon) manageWorkflows(caller wire.UUID, args map[string]json.RawMessage) (string, error) {
	a := d.Store.Agent(caller)
	if a == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nothing was changed."}
	}
	folder := folderPath(a)
	id := argString(args, "id")
	switch action := argString(args, "action"); action {
	case "list":
		list := d.workflowSummaries(folder)
		if len(list) == 0 {
			return "This folder has no workflows yet. They live in .agents/workflows, one Markdown file each.", nil
		}
		lines := []string{fmt.Sprintf("%d workflows:", len(list))}
		if len(list) == 1 {
			lines[0] = "1 workflow:"
		}
		for _, s := range list {
			line := "- " + s.Workflow.WorkflowID + ": " + workflowSummaryWords(s.Workflow)
			if s.IsArchived {
				line += " [archived]"
			}
			switch {
			case s.OffReason != nil && *s.OffReason == wire.WorkflowOffReasonFile:
				line += " [turned off: its file says enabled: false]"
			case s.OffReason != nil && *s.OffReason == wire.WorkflowOffReasonWrittenByAgent:
				line += " [turned off: written by an agent, waiting for the person]"
			case s.OffReason != nil && *s.OffReason == wire.WorkflowOffReasonAgent:
				line += " [turned off by an agent]"
			case !s.IsEnabled:
				line += " [turned off]"
			}
			if s.OverLimit != nil {
				line += " [over the limit, so it will not run]"
			}
			if n := neverHereWorkflow(s.Workflow); n != "" {
				line += " [" + n + "]"
			}
			if s.LastOutcome != nil {
				line += " — " + outcomeWords(*s.LastOutcome)
			}
			lines = append(lines, line)
		}
		return strings.Join(lines, "\n"), nil
	case "read":
		d.workflowMu.Lock()
		d.scanLocked()
		f := d.fileLocked(folder, id)
		if f == nil {
			path, ok := workflowPath(folder, id)
			d.workflowMu.Unlock()
			if !ok {
				return "", notInFolder(id)
			}
			if _, _, why := readWorkflowFile(path); why != "" {
				return "", &Error{Code: wire.FailureWorkflowUnreadable, Message: id + ".md could not be read."}
			}
			return "", noSuchWorkflow(id)
		}
		if f.scope == "user" {
			d.workflowMu.Unlock()
			return "", &Error{Code: wire.FailureNotAllowed, Message: "This workflow belongs to your workflows. Open it in Settings ▸ Agent Configuration ▸ Workflows."}
		}
		if f.wf.Problem != nil && f.wf.Problem.Unreadable != nil {
			d.workflowMu.Unlock()
			return "", &Error{Code: wire.FailureWorkflowUnreadable, Message: id + ".md could not be read."}
		}
		text := f.text
		d.workflowMu.Unlock()
		return text, nil
	case "write":
		d.workflowMu.Lock()
		d.scanLocked()
		existing := d.fileLocked(folder, id)
		d.workflowMu.Unlock()
		if existing != nil && existing.scope == "user" {
			return "", &Error{Code: wire.FailureNotAllowed, Message: "This workflow belongs to your workflows. Edit it in Settings ▸ Agent Configuration ▸ Workflows."}
		}
		return d.writeWorkflow(folder, id, argString(args, "content"))
	case "remove":
		d.workflowMu.Lock()
		d.scanLocked()
		existing := d.fileLocked(folder, id)
		d.workflowMu.Unlock()
		if existing != nil && existing.scope == "user" {
			return "", &Error{Code: wire.FailureNotAllowed, Message: "This workflow belongs to your workflows. Remove it in Settings ▸ Agent Configuration ▸ Workflows."}
		}
		path, ok := workflowPath(folder, id)
		if !ok {
			return "", notInFolder(id)
		}
		if _, err := os.Stat(path); err != nil {
			return "", noSuchWorkflow(id)
		}
		if err := d.deleteWorkflow(wire.WorkflowRequest{Folder: store.FolderURL(folder), WorkflowID: id}); err != nil {
			return "", err
		}
		return id + " is gone. It will not run again.", nil
	case "enable", "disable":
		if _, ok := workflowPath(folder, id); !ok {
			return "", notInFolder(id)
		}
		s, err := d.oneWorkflow(folder, id)
		if err != nil {
			return "", err
		}
		on := action == "enable"
		if on && s.IsEnabled {
			return id + " is already on.", nil
		}
		if !on && !s.IsEnabled {
			return id + " is already turned off.", nil
		}
		if on && s.OffReason != nil {
			switch *s.OffReason {
			case wire.WorkflowOffReasonFile:
				return "", &Error{Code: wire.FailureWorkflowTurnedOffByPerson, Message: "Nothing was changed: " + id + "'s file says `enabled: false`, so it stays off until the person turns it on from the folder page. Ask them to if it should run."}
			case wire.WorkflowOffReasonWrittenByAgent:
				return "", &Error{Code: wire.FailureWorkflowTurnedOffByPerson, Message: "Nothing was changed: " + id + " was written by an agent, so it starts off until the person turns it on from its page. Ask them to if it should run."}
			case wire.WorkflowOffReasonPerson:
				return "", &Error{Code: wire.FailureWorkflowTurnedOffByPerson, Message: "Nothing was changed: " + id + " was turned off by the person, so only they can turn it back on, from the folder page. Ask them to if it should run again."}
			}
		}
		got, err := d.enableWorkflow(wire.WorkflowEnableRequest{Folder: store.FolderURL(folder), WorkflowID: id, Enabled: on}, "agent")
		if err != nil {
			return "", err
		}
		if !on {
			return "Turned off " + id + ". None of its triggers will run it until it is turned back on; it stays on the folder page, marked off, " +
				"where Run now still runs it. Tell them you turned it off and why.", nil
		}
		note := "Turned " + id + " back on. Its triggers run it again."
		if got.AwaitingApproval != nil {
			note += " It is still waiting for their OK, so it will not run until they approve it."
		}
		return note, nil
	case "run":
		return d.runWorkflowForAgent(a, folder, id)
	}
	return "", Invalid("Nothing was done: `action` has to be one of list, read, write, remove, enable, disable or run.")
}

// runWorkflowForAgent is manage_workflows' run (#1524): Run now, as the person's, but never
// one that is turned off, and at the caller's chain depth, so runs cannot loop.
func (d *Daemon) runWorkflowForAgent(a *wire.Agent, folder, id string) (string, error) {
	if _, ok := workflowPath(folder, id); !ok {
		return "", notInFolder(id)
	}
	d.workflowMu.Lock()
	d.scanLocked()
	d.workflowMu.Unlock()
	s, err := d.oneWorkflow(folder, id)
	if err != nil {
		return "", err
	}
	if s.IsArchived {
		return "", &Error{Code: wire.FailureWorkflowTurnedOffByPerson, Message: "Nothing was run: " + id + " is archived. Ask the person to bring it back from the folder page if it should run."}
	}
	if s.AwaitingApproval != nil {
		return "", &Error{Code: wire.FailureWorkflowTurnedOffByPerson, Message: "Nothing was run: " + id + " is waiting for the person's OK on the folder page. Ask them to approve it if it should run."}
	}
	if !s.IsEnabled {
		return "", &Error{Code: wire.FailureWorkflowTurnedOffByPerson, Message: "Nothing was run: " + id + " is turned off, so only the person runs it, with Run now on its page. Ask them to if it should run."}
	}
	if s.Workflow.Mode == wire.WorkflowModeTriggering {
		return "", Invalid("Nothing was run: %s runs in the agent that triggered it, and nothing did. Only its triggers run it.", id)
	}
	var depth int64
	if a.ChainDepth != nil {
		depth = *a.ChainDepth
	}
	d.fire(fireRequest{folder: folder, id: id, byHand: true, byAgent: &a.ID, trigger: byHandTrigger(), depth: depth})
	after, err := d.oneWorkflow(folder, id)
	if err != nil {
		return "", err
	}
	o := after.LastOutcome
	switch {
	case o == nil:
		return "", &Error{Code: wire.FailureNoSuchWorkflow, Message: "Nothing was run: " + id + " does not run on this computer."}
	case o.Ran != nil:
		return "Ran " + id + ": it started agent " + string(o.Ran.AgentID) + ". Use wait_for_agents with that id to wait for it to finish, or read_session to see it.", nil
	}
	return "", &Error{Code: wire.FailureNotAllowed, Message: "Nothing was run: " + id + " did not run, as " + refusalWords(o.Refused.Value) + "."}
}

// writeWorkflow is manage_workflows' write: the whole file, checked, and a new one off.
func (d *Daemon) writeWorkflow(folder, id, content string) (string, error) {
	path, ok := workflowPath(folder, id)
	if !ok {
		return "", notInFolder(id)
	}
	if content == "" {
		return "", Invalid("Nothing was written: `content` has to be the whole file.")
	}
	parsed := parseWorkflow(content, id, folder)
	if p := parsed.Problem; p != nil && p.Unreadable != nil {
		return "", &Error{Code: wire.FailureWorkflowUnreadable, Message: "That front matter could not be read: " + p.Unreadable.Value + ". Nothing was written."}
	}
	for _, t := range parsed.Triggers {
		if t.Schedule == nil && !triggerSupported(t) && !isServerEventName(triggerName(t)) {
			name := triggerName(t)
			guess := "."
			if g := closestEvent(name); g != "" {
				guess = ". Did you mean " + g + "?"
			}
			return "", &Error{Code: wire.FailureWorkflowUnreadable, Message: "\"" + name + "\" is not a trigger" + guess + " Under on: go schedule and event names. Nothing was written."}
		}
	}
	d.workflowMu.Lock()
	d.scanLocked()
	existing := d.fileLocked(folder, id)
	archived := existing != nil && isArchived(existing.wf)
	text := content
	var err error
	off := existing == nil || isOff(existing.wf)
	if isOff(parsed) != off {
		if off {
			text, err = setFrontMatter("enabled", strPtr("false"), text)
		} else {
			text, err = setFrontMatter("enabled", nil, text)
		}
	}
	if err == nil && existing != nil && isArchived(parsed) != archived {
		if archived {
			text, err = setFrontMatter("archived", strPtr("true"), text)
		} else {
			text, err = setFrontMatter("archived", nil, text)
		}
	}
	if err != nil {
		d.workflowMu.Unlock()
		return "", &Error{Code: wire.FailureWorkflowUnreadable, Message: "Nothing was written: " + err.Error() + "."}
	}
	os.MkdirAll(workflowsFolder(folder), 0o755)
	if _, ok := workflowPath(folder, id); !ok {
		d.workflowMu.Unlock()
		return "", notInFolder(id)
	}
	digest := sha256Hex(text)
	st := d.stateLocked(folder, id, true)
	if existing == nil {
		st.OffBy, st.OffDigest, st.HeldFire = strPtr("writtenByAgent"), &digest, nil
	} else if st.OffDigest != nil && *st.OffDigest == existing.digest {
		st.OffDigest = &digest
	}
	d.saveRecordsLocked(false)
	if err := store.WriteAtomically(path, []byte(text), 0o644); err != nil {
		d.workflowMu.Unlock()
		return "", &Error{Code: wire.FailureCouldNotSave, Message: "Nothing was written: " + err.Error()}
	}
	d.scanLocked()
	f := d.fileLocked(folder, id)
	awaiting, _ := d.approvalOf(folder, id, f)
	d.workflowMu.Unlock()
	d.tellWorkflow(folder, id)
	verb := "Changed"
	if existing == nil {
		verb = "Created"
	}
	warning := ""
	if n := neverHereWorkflow(parsed); n != "" {
		warning = " " + n
	}
	summary := workflowSummaryWords(parsed)
	switch {
	case archived:
		return verb + " " + id + ". " + summary + ". It is archived, though, so it will not run until they bring it back from the folder page. Tell them it is there." + warning, nil
	case awaiting != nil:
		startsOff := ""
		if existing == nil {
			startsOff = " It starts turned off (the app wrote `enabled: false` into it): once they have approved it, they turn it on from its page when they are ready, and you cannot."
		}
		return verb + " " + id + ". " + summary + ". It will not run until they approve it on the folder page, so tell them it is waiting for their OK and what it does." +
			startsOff + warning, nil
	case existing == nil:
		return "Created " + id + ". " + summary + ". It is turned off (the app wrote `enabled: false` into it), so none of its triggers run it until they turn it on " +
			"from the folder page, where they can also run it, or archive it if it is not what they wanted. Tell them it is there and what it does." + warning, nil
	}
	return verb + " " + id + ". " + summary + ". It is live now; it shows on the folder page, where they can run it, or archive it if it is not what they wanted." + warning, nil
}

func sortStrings(s []string) { sort.Strings(s) }

func sha256Hex(text string) string {
	sum := sha256.Sum256([]byte(text))
	return hex.EncodeToString(sum[:])
}
