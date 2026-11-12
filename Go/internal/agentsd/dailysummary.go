package agentsd

import (
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The daily summary (#3192): once a day the Daily summary workflow's agent asks this host,
// with write_daily_summary, for what happened since the last one in every folder here, writes a
// short page from it, and saves it, which keeps the last few under ~/.agents/summaries,
// shows it and sends one notice.

const (
	dailySummaryID = "daily-summary"
	// summariesKept is how many summaries stay on disk: older ones are deleted.
	summariesKept = 3
	// summaryLines is the most lines one part of the facts lists: the rest is a count.
	summaryLines = 40
	// summaryReach is the furthest back the facts go, when there is no summary yet or the
	// last one is old.
	summaryReach = 7 * 24 * time.Hour
	// summaryBytes is the most a saved summary may be.
	summaryBytes = 64 << 10
	// personalWorkflowFolder names the person's own workflows in a claim, the same on every
	// machine whatever its home folder is called.
	personalWorkflowFolder = "~"
)

// oneMachineWorkflows are the person's own workflows that run on one of their machines,
// claimed per schedule, and only in their home folder: never copied into a project (#3192).
var oneMachineWorkflows = map[string]bool{dailySummaryID: true, dailyChecksID: true}

func summariesDir(home string) string { return filepath.Join(home, ".agents", "summaries") }

// summaryFiles is the saved summaries, newest first.
func summaryFiles(home string) []string {
	entries, _ := os.ReadDir(summariesDir(home))
	var out []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasSuffix(e.Name(), ".md") {
			out = append(out, filepath.Join(summariesDir(home), e.Name()))
		}
	}
	// The names are yyyy-MM-dd-HHmm, so the newest sorts last.
	sort.Sort(sort.Reverse(sort.StringSlice(out)))
	return out
}

// inPersonalHome is whether a session works in the person's home folder: tools/list offers
// such a one write_daily_summary, as a run's workflow is marked on it only after it starts.
func (d *Daemon) inPersonalHome(id wire.UUID) bool {
	a := d.Store.Agent(id)
	home := d.personalHome()
	return a != nil && home != "" && filepath.Clean(store.FolderPath(a.Cwd)) == filepath.Clean(home)
}

// writesDailySummary is whether an agent may call write_daily_summary: the Daily summary
// workflow's, in the person's home folder. It reads every folder here, which no other
// session's tools do.
func (d *Daemon) writesDailySummary(id wire.UUID) bool {
	a := d.Store.Agent(id)
	return d.inPersonalHome(id) && a.StartedByWorkflow != nil && *a.StartedByWorkflow == dailySummaryID
}

// dailySummary is write_daily_summary: collect, the facts; save, the page.
func (d *Daemon) dailySummary(id wire.UUID, args map[string]json.RawMessage) (string, error) {
	if !d.writesDailySummary(id) {
		return "", &Error{Code: wire.FailureNotAllowed, Message: "Only the Daily summary workflow's session, in your home folder, can use write_daily_summary."}
	}
	switch argString(args, "action") {
	case "collect":
		return d.summaryFacts(id, time.Now()), nil
	case "save":
		return d.saveSummary(id, argString(args, "markdown"), strings.TrimSpace(argString(args, "headline")), time.Now())
	}
	return "", Invalid("Send `action`: collect, for the facts, or save, with `markdown`, for the page.")
}

// summarySince is when the facts start: the last summary's time, at most a week back.
func summarySince(home string, at time.Time) time.Time {
	since := at.Add(-24 * time.Hour)
	if files := summaryFiles(home); len(files) > 0 {
		if st, err := os.Stat(files[0]); err == nil {
			since = st.ModTime()
		}
	}
	if since.Before(at.Add(-summaryReach)) {
		since = at.Add(-summaryReach)
	}
	return since
}

// summaryList is the lines of one part, at most summaryLines, and a count of the rest.
type summaryList struct {
	title, none string
	lines       []string
}

func (l summaryList) write(b *strings.Builder) {
	fmt.Fprintf(b, "\n## %s\n\n", l.title)
	if len(l.lines) == 0 {
		b.WriteString(l.none + "\n")
		return
	}
	for i, line := range l.lines {
		if i == summaryLines {
			fmt.Fprintf(b, "- and %d more\n", len(l.lines)-summaryLines)
			break
		}
		b.WriteString("- " + line + "\n")
	}
}

func sessionLink(id wire.UUID) string { return "agents://agent/" + string(id) }

func agentTitle(a *wire.Agent) string {
	if a.Title != nil && strings.TrimSpace(*a.Title) != "" {
		return strings.TrimSpace(*a.Title)
	}
	return "Untitled session"
}

func summaryClock(t time.Time) string { return t.Local().Format("Mon 15:04") }

// failedEnds are how a session can end that someone should hear about.
var failedEnds = map[wire.EndedReason]string{
	wire.EndedReasonProcessDied:     "its runtime stopped",
	wire.EndedReasonDaemonGone:      "the host stopped",
	wire.EndedReasonCostLimit:       "it reached its cost limit",
	wire.EndedReasonRefusal:         "the model refused",
	wire.EndedReasonMaxTokens:       "it ran out of tokens",
	wire.EndedReasonMaxTurnRequests: "it reached its turn limit",
	wire.EndedReasonSignInRefused:   "its sign-in was refused",
}

// quietRefusals are a workflow's refusals that are not a failure: it ran already, waits,
// or is off.
var quietRefusals = map[string]bool{"runInFlight": true, "queued": true, "disabled": true, "archived": true, "coolingDown": true, "outsideHours": true}

// refusalName is a refusal's case, as the wire names it.
func refusalName(r wire.WorkflowRefusal) string {
	var cases map[string]json.RawMessage
	b, _ := json.Marshal(r)
	_ = json.Unmarshal(b, &cases)
	for name := range cases {
		return name
	}
	return "refused"
}

// summaryFacts is what happened since the last summary in every folder here and on the
// person's other machines (#3354), as Markdown the agent writes the page from.
func (d *Daemon) summaryFacts(me wire.UUID, at time.Time) string {
	since := summarySince(d.personalHome(), at)
	host, _ := os.Hostname()
	here := d.machineSummaryFacts(me, since)
	landed := summaryList{title: "Landed", none: "Nothing landed.", lines: here.Landed}
	failed := summaryList{title: "Failed or stopped", none: "Nothing failed or stopped.", lines: here.Failed}
	waiting := summaryList{title: "Waits on you (oldest first)", none: "Nothing waits on you.", lines: here.Waiting}
	suggested := summaryList{title: "Suggested next (not taken)", none: "No suggestions wait.", lines: here.Suggested}
	checked := summaryList{title: "Found by the checks", none: "The checks found nothing.", lines: here.Checked}
	elsewhere, unreached := d.otherMachinesFacts(me, since)
	folders := here.Folders
	for _, m := range elsewhere {
		folders += m.Facts.Folders
		on := func(l *summaryList, lines []string) {
			for _, line := range lines {
				if key := forgeKey(line); key != "" {
					// The same item on GitHub from a checkout on each machine is one line, with
					// the sessions of both under it.
					_, under, _ := strings.Cut(line, "\n")
					if i := slices.IndexFunc(l.lines, func(have string) bool { return forgeKey(have) == key }); i >= 0 {
						if under != "" {
							l.lines[i] += "\n" + under
						}
						continue
					}
					l.lines = append(l.lines, line)
					continue
				}
				l.lines = append(l.lines, "On "+m.MachineName+": "+line)
			}
		}
		on(&landed, m.Facts.Landed)
		on(&failed, m.Facts.Failed)
		on(&waiting, m.Facts.Waiting)
		on(&suggested, m.Facts.Suggested)
		on(&checked, m.Facts.Checked)
	}
	var b strings.Builder
	machines := host
	if len(elsewhere) > 0 {
		names := []string{host}
		for _, m := range elsewhere {
			names = append(names, m.MachineName)
		}
		machines = strings.Join(names, ", ")
	}
	fmt.Fprintf(&b, "# Facts for the daily summary\n\nFor you: %s\n\nSince %s, on %s (%d folders). Each session link opens it in the app.\n",
		personLine(waiting.lines, landed.lines), since.Local().Format("Mon 2 Jan 15:04"), machines, folders)
	if len(unreached) > 0 {
		b.WriteString("\nNot in these facts: " + strings.Join(unreached, "; ") + ". Say so on the page.\n")
	}
	for _, l := range []summaryList{landed, failed, waiting, suggested, checked} {
		l.write(&b)
	}
	b.WriteString("\nWrite the page from these facts, then call write_daily_summary with action save.\n")
	return b.String()
}

// machineSummaryFacts is this machine's lines for a summary since a time: for its own
// summary, and for one another of the person's machines writes (agents/summaryFacts). me,
// the summary's own session, is left out; so are the summary's and the checks' sessions.
func (d *Daemon) machineSummaryFacts(me wire.UUID, since time.Time) wire.SummaryFacts {
	return d.machineSummaryFactsWith(me, since, findGH())
}

// workflowRuns is the sessions one workflow in one folder started that ended well: one line.
type workflowRuns struct {
	name, folder string
	runs         int
	last         *wire.Agent
}

// machineSummaryFactsWith is machineSummaryFacts with this gh, "" for none.
func (d *Daemon) machineSummaryFactsWith(me wire.UUID, since time.Time, gh string) wire.SummaryFacts {
	home := d.personalHome()
	from := wire.DateOf(since)
	out := wire.SummaryFacts{Folders: int64(len(d.folderPaths())), Landed: []string{}, Failed: []string{},
		Waiting: []string{}, Suggested: []string{}, Checked: checkSuggestions(home, since)}
	if out.Checked == nil {
		out.Checked = []string{}
	}
	workflows := d.workflowSummaries("")
	names := map[string]string{}
	for _, w := range workflows {
		names[filepath.Clean(store.FolderPath(w.Workflow.Folder))+"\x00"+w.Workflow.WorkflowID] = w.Workflow.Name
	}
	active := map[string]bool{}
	var recent, done []*wire.Agent
	agents := d.Store.Agents()
	sort.Slice(agents, func(i, j int) bool { return agents[i].LastActivityAt < agents[j].LastActivityAt })
	for i := range agents {
		a := &agents[i]
		if a.ID == me || bySummaryWorkflow(a) {
			continue
		}
		folder := folderPath(a)
		where := fmt.Sprintf("%q in %s", agentTitle(a), filepath.Base(folder))
		if a.LastActivityAt >= from {
			active[folder] = true
			recent = append(recent, a)
		}
		switch {
		case a.LastActivityAt < from:
		case a.EndedReason != nil && failedEnds[*a.EndedReason] != "":
			out.Failed = append(out.Failed, fmt.Sprintf("Session %s stopped at %s: %s. %s", where,
				summaryClock(a.LastActivityAt.Time()), failedEnds[*a.EndedReason], sessionLink(a.ID)))
		case a.State == wire.AgentStateFinished || a.ArchivedAt != nil && *a.ArchivedAt >= from:
			done = append(done, a)
		}
		if a.State != wire.AgentStateArchived && len(a.SuggestedPrompts) > 0 {
			s := a.SuggestedPrompts[0]
			out.Suggested = append(out.Suggested, fmt.Sprintf("%q, suggested by %s: %s. %s", s.Label, where,
				prefix(strings.Join(strings.Fields(s.Prompt), " "), 200), sessionLink(a.ID)))
		}
	}
	used := map[wire.UUID]bool{}
	if gh != "" {
		var worked []string
		for f := range active {
			worked = append(worked, filepath.Clean(f))
		}
		var outcomes []string
		outcomes, used = d.forgeOutcomes(gh, d.summaryRepos(gh, worked), since, recent)
		out.Landed = append(out.Landed, outcomes...)
	}
	// A workflow's runs are one line, not one a run (#3720); a session with no outcome is a
	// line of its own, at most otherSessionLines of them.
	var routine []*workflowRuns
	byWorkflow := map[string]*workflowRuns{}
	var others []string
	for _, a := range done {
		if used[a.ID] {
			continue
		}
		folder := filepath.Clean(folderPath(a))
		if a.StartedByWorkflow != nil {
			key := filepath.Clean(store.FolderPath(a.Cwd)) + "\x00" + *a.StartedByWorkflow
			w := byWorkflow[key]
			if w == nil {
				name := names[key]
				if name == "" {
					name = *a.StartedByWorkflow
				}
				w = &workflowRuns{name: name, folder: filepath.Base(folder)}
				byWorkflow[key] = w
				routine = append(routine, w)
			}
			w.runs++
			w.last = a
			continue
		}
		others = append(others, fmt.Sprintf("Session %q in %s done at %s. %s", agentTitle(a), filepath.Base(folder),
			summaryClock(a.LastActivityAt.Time()), sessionLink(a.ID)))
	}
	for _, w := range routine {
		times := "once"
		if w.runs > 1 {
			times = fmt.Sprintf("%d times", w.runs)
		}
		out.Landed = append(out.Landed, fmt.Sprintf("Workflow %q in %s ran %s, the last at %s. %s", w.name, w.folder, times,
			summaryClock(w.last.LastActivityAt.Time()), sessionLink(w.last.ID)))
	}
	if len(others) > otherSessionLines {
		others = append(others[:otherSessionLines], fmt.Sprintf("and %d other sessions done", len(others)-otherSessionLines))
	}
	out.Landed = append(out.Landed, others...)
	for _, w := range workflows {
		o := w.LastOutcome
		if w.Workflow.WorkflowID == dailySummaryID || w.Workflow.WorkflowID == dailyChecksID || o == nil || o.Refused == nil || o.Refused.At < from {
			continue
		}
		if why := refusalName(o.Refused.Value); !quietRefusals[why] {
			out.Failed = append(out.Failed, fmt.Sprintf("Workflow %q in %s did not run at %s: %s.", w.Workflow.Name,
				filepath.Base(store.FolderPath(w.Workflow.Folder)), summaryClock(o.Refused.At.Time()), why))
		}
	}
	needs := d.attentionPending().Needs
	sort.SliceStable(needs, func(i, j int) bool { return needs[i].RaisedAt < needs[j].RaisedAt })
	for _, n := range needs {
		line := fmt.Sprintf("%s in %s: %s, since %s.", n.Kind, n.Headline.H1, strings.TrimSpace(n.Headline.H2+" — "+n.Headline.H3), summaryClock(n.RaisedAt.Time()))
		if n.AgentID != nil {
			line += " " + sessionLink(*n.AgentID)
		}
		out.Waiting = append(out.Waiting, line)
	}
	if gh != "" {
		out.Waiting = append(out.Waiting, d.forgeWaits(gh, d.summaryRepos(gh, d.folderPaths()))...)
	}
	return out
}

// sentSummaryFacts is agents/summaryFacts' answer: each list cut to summaryLines, with a
// count of the rest, so one busy machine's answer stays small.
func sentSummaryFacts(f wire.SummaryFacts) wire.SummaryFacts {
	cut := func(lines []string) []string {
		if len(lines) <= summaryLines {
			return lines
		}
		return append(lines[:summaryLines:summaryLines], fmt.Sprintf("and %d more", len(lines)-summaryLines))
	}
	f.Landed, f.Failed, f.Waiting, f.Suggested, f.Checked = cut(f.Landed), cut(f.Failed), cut(f.Waiting), cut(f.Suggested), cut(f.Checked)
	return f
}

// otherMachinesFacts is the facts of each of the person's other machines, through the
// control plane (machines/summaryFacts, #3354), and the words for each one that is off or
// did not answer. None off a control plane, or from one too old to ask.
func (d *Daemon) otherMachinesFacts(me wire.UUID, since time.Time) ([]wire.MachineSummaryFacts, []string) {
	if d.askControl.Load() == nil {
		return nil, nil
	}
	out, err := d.askWorkspaces(me, wire.CallMachinesSummaryFacts.Name, wire.SummaryFactsRequest{Since: wire.DateOf(since)})
	if err != nil {
		log.Printf("daily summary: the other machines' facts were not asked: %v", err)
		return nil, []string{"the other machines, as the control plane did not answer"}
	}
	var got wire.MachinesSummaryFacts
	if json.Unmarshal(out, &got) != nil {
		return nil, []string{"the other machines, as the control plane's answer could not be read"}
	}
	var facts []wire.MachineSummaryFacts
	var unreached []string
	for _, m := range got.Machines {
		switch {
		case m.Facts != nil:
			facts = append(facts, m)
		case m.Unreached != nil:
			unreached = append(unreached, m.MachineName+", "+*m.Unreached)
		default:
			unreached = append(unreached, m.MachineName)
		}
	}
	return facts, unreached
}

// summaryTitle is a page's first heading, such as "Daily summary, Mon 2 Nov"; "" when it has none.
func summaryTitle(markdown string) string {
	for line := range strings.Lines(markdown) {
		if h, ok := strings.CutPrefix(strings.TrimSpace(line), "# "); ok {
			return prefix(strings.TrimSpace(h), 120)
		}
	}
	return ""
}

// newestSummary makes this run's session the one daily summary in For Review (#3352): it
// takes the page's title, so its row says which day, and the earlier runs' sessions in the
// home folder are marked read, so an older page that nobody opened leaves the group.
func (d *Daemon) newestSummary(id wire.UUID, markdown string) {
	if title := summaryTitle(markdown); title != "" {
		d.change(id, func(a *wire.Agent) { a.Title = &title })
	}
	home := filepath.Clean(d.personalHome())
	for _, a := range d.Store.Agents() {
		if a.ID != id && a.StartedByWorkflow != nil && *a.StartedByWorkflow == dailySummaryID &&
			filepath.Clean(store.FolderPath(a.Cwd)) == home && a.FileToSee != nil {
			d.markRead(a.ID)
		}
	}
}

// saveSummary writes the page, keeps the newest few, shows it and sends one notice.
func (d *Daemon) saveSummary(id wire.UUID, markdown, headline string, at time.Time) (string, error) {
	if strings.TrimSpace(markdown) == "" {
		return "", Invalid("Nothing was saved: send the page as `markdown`.")
	}
	if len(markdown) > summaryBytes {
		return "", Invalid("Nothing was saved: the page is over %d KB. Keep it short.", summaryBytes>>10)
	}
	home := d.personalHome()
	dir := summariesDir(home)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", &Error{Message: "The summary was not saved: " + err.Error()}
	}
	path := filepath.Join(dir, at.Local().Format("2006-01-02-1504")+".md")
	if err := store.WriteAtomically(path, []byte(markdown), 0o600); err != nil {
		return "", &Error{Message: "The summary was not saved: " + err.Error()}
	}
	if kept := summaryFiles(home); len(kept) > summariesKept {
		for _, old := range kept[summariesKept:] {
			_ = os.Remove(old)
		}
	}
	said := []string{"Saved at " + path + "."}
	d.newestSummary(id, markdown)
	d.markSummarySaved(home, path, id)
	if _, err := d.showFile(id, map[string]json.RawMessage{"path": jsonString(path)}); err != nil {
		said = append(said, "Not shown: "+err.Error())
	}
	if headline == "" {
		headline = "Your daily summary is ready"
	}
	if reply, err := d.notify(id, map[string]json.RawMessage{"title": jsonString("Daily summary"), "body": jsonString(headline)}); err != nil {
		said = append(said, "No notice: "+err.Error())
	} else {
		said = append(said, reply)
	}
	return strings.Join(said, " "), nil
}
