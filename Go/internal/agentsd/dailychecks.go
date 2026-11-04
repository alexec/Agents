package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The read-only checks (#3355): between daily summaries, the Daily checks workflow's agent asks
// this host, with check_folders, what looks wrong in the folders that had no work since the last
// check: failing CI on the default branch, pull requests that went stale or are in conflict,
// issues assigned to the person that no session has, and a missed scheduled workflow. It keeps
// each finding that needs the person as a suggestion, with a prompt that starts a session on
// it; the next summary lists them, and an urgent one sends a notice. It reads and never acts.

const (
	dailyChecksID = "daily-checks"
	// suggestionsKept is the most suggestions the checks keep: the oldest go first.
	suggestionsKept = 50
	// checksGap is how far back the first check looks.
	checksGap = 4 * time.Hour
	// staleAfter is how long an open pull request can go unchanged before it is stale.
	staleAfter = 7 * 24 * time.Hour
	// checkFolders is the most quiet folders one check reads with gh.
	checkFolders = 30
	// checkLines is the most findings of one kind a folder lists: the rest is a count.
	checkLines = 10
)

// checksMu keeps one read-change-write of the checks' file at a time.
var checksMu sync.Mutex

// checkSuggestion is one finding the checks keep for the person.
type checkSuggestion struct {
	Folder string    `json:"folder"`
	Title  string    `json:"title"`
	Prompt string    `json:"prompt"`
	Link   string    `json:"link,omitempty"`
	Urgent bool      `json:"urgent,omitempty"`
	At     time.Time `json:"at"`
}

// checksRecord is ~/.agents/checks/suggestions.json: when the last check started, and what it
// and the ones before it found.
type checksRecord struct {
	CheckedAt   time.Time         `json:"checkedAt,omitzero"`
	Suggestions []checkSuggestion `json:"suggestions"`
}

func checksPath(home string) string {
	return filepath.Join(home, ".agents", "checks", "suggestions.json")
}

func readChecks(home string) checksRecord {
	var r checksRecord
	if b, err := os.ReadFile(checksPath(home)); err == nil {
		_ = json.Unmarshal(b, &r)
	}
	return r
}

func writeChecks(home string, r checksRecord) error {
	if err := os.MkdirAll(filepath.Dir(checksPath(home)), 0o700); err != nil {
		return err
	}
	b, err := json.MarshalIndent(r, "", "  ")
	if err != nil {
		return err
	}
	return store.WriteAtomically(checksPath(home), b, 0o600)
}

// bySummaryWorkflow is whether a session is a daily summary's or a check's own: neither is work.
func bySummaryWorkflow(a *wire.Agent) bool {
	return a.StartedByWorkflow != nil && (*a.StartedByWorkflow == dailySummaryID || *a.StartedByWorkflow == dailyChecksID)
}

// runsDailyChecks is whether an agent may call check_folders: the Daily checks workflow's, in
// the person's home folder.
func (d *Daemon) runsDailyChecks(id wire.UUID) bool {
	a := d.Store.Agent(id)
	return d.inPersonalHome(id) && a.StartedByWorkflow != nil && *a.StartedByWorkflow == dailyChecksID
}

// dailyChecks is check_folders: collect, the findings in the quiet folders; suggest, keep one.
func (d *Daemon) dailyChecks(id wire.UUID, args map[string]json.RawMessage) (string, error) {
	if !d.runsDailyChecks(id) {
		return "", &Error{Code: wire.FailureNotAllowed, Message: "Only the Daily checks workflow's session, in your home folder, can use check_folders."}
	}
	switch argString(args, "action") {
	case "collect":
		return d.checkFacts(time.Now()), nil
	case "suggest":
		return d.keepSuggestion(id, args, time.Now())
	}
	return "", Invalid("Send `action`: collect, for what looks wrong, or suggest, with `folder`, `title` and `prompt`, to keep one finding.")
}

// quietFolders is the folders here, but the home folder, that no session worked in since.
func (d *Daemon) quietFolders(since time.Time) []string {
	from := wire.DateOf(since)
	busy := map[string]bool{filepath.Clean(d.personalHome()): true}
	for _, a := range d.Store.Agents() {
		if !bySummaryWorkflow(&a) && a.LastActivityAt >= from {
			busy[filepath.Clean(folderPath(&a))] = true
		}
	}
	var out []string
	for _, f := range d.folderPaths() {
		if busy[filepath.Clean(f)] {
			continue
		}
		if st, err := os.Stat(f); err == nil && st.IsDir() {
			out = append(out, f)
		}
	}
	sort.Strings(out)
	return out
}

// checkFacts is what looks wrong in each folder that had no work since the last check, as
// Markdown the agent decides from. It starts a new check: the next one looks from here.
func (d *Daemon) checkFacts(at time.Time) string {
	home := d.personalHome()
	checksMu.Lock()
	r := readChecks(home)
	since := r.CheckedAt
	if since.IsZero() || since.Before(at.Add(-summaryReach)) {
		since = at.Add(-checksGap)
	}
	r.CheckedAt = at
	_ = writeChecks(home, r)
	checksMu.Unlock()

	quiet := d.quietFolders(since)
	missed := map[string][]string{}
	for _, w := range d.workflowSummaries("") {
		o := w.LastOutcome
		if o != nil && o.Refused != nil && o.Refused.Value.MissedWhileClosed != nil && o.Refused.At >= wire.DateOf(since) {
			f := filepath.Clean(store.FolderPath(w.Workflow.Folder))
			missed[f] = append(missed[f], fmt.Sprintf("Workflow %q missed its run at %s: the machine slept or the app was closed.",
				w.Workflow.Name, summaryClock(o.Refused.At.Time())))
		}
	}
	gh := findGH()
	var b strings.Builder
	fmt.Fprintf(&b, "# Facts for the daily checks\n\nSince %s, %d of %d folders had no work.\n",
		since.Local().Format("Mon 2 Jan 15:04"), len(quiet), len(d.folderPaths()))
	if gh == "" {
		b.WriteString("This machine has no gh, so CI, pull requests and issues are not read.\n")
	}
	found := 0
	for i, f := range quiet {
		lines := missed[filepath.Clean(f)]
		if gh != "" && i < checkFolders && pushesToForge(f) {
			lines = append(lines, d.forgeChecks(gh, f, at)...)
		}
		if len(lines) == 0 {
			continue
		}
		found++
		fmt.Fprintf(&b, "\n## %s (%s)\n\n", filepath.Base(f), f)
		for _, line := range lines {
			b.WriteString("- " + line + "\n")
		}
	}
	if len(quiet) > checkFolders && gh != "" {
		fmt.Fprintf(&b, "\nOnly the first %d quiet folders were read with gh.\n", checkFolders)
	}
	if found == 0 {
		b.WriteString("\nNothing looks wrong. End without a suggestion.\n")
		return b.String()
	}
	b.WriteString("\nFor each finding that needs the person, call check_folders with action suggest. Do not act on any of them.\n")
	return b.String()
}

// ghRun is one default-branch workflow run, as gh run list gives it.
type ghRun struct {
	WorkflowName string    `json:"workflowName"`
	Conclusion   string    `json:"conclusion"`
	URL          string    `json:"url"`
	CreatedAt    time.Time `json:"createdAt"`
}

// failedConclusions are the ends of a run that mean the default branch is broken.
var failedConclusions = map[string]bool{"failure": true, "timed_out": true, "startup_failure": true}

// forgeChecks is what gh says is wrong in one folder: a workflow whose newest run on the
// default branch failed, a pull request in conflict or unchanged for a week, and an issue
// assigned to the person that no session in the folder is labelled with.
func (d *Daemon) forgeChecks(gh, folder string, at time.Time) []string {
	var repo struct {
		DefaultBranchRef struct {
			Name string `json:"name"`
		} `json:"defaultBranchRef"`
	}
	if err := ghJSON(d.ctx, gh, folder, &repo, "repo", "view", "--json", "defaultBranchRef"); err != nil {
		return []string{"gh could not read this folder's repository: " + err.Error()}
	}
	var out []string
	add := func(kind []string) {
		for i, line := range kind {
			if i == checkLines {
				out = append(out, fmt.Sprintf("and %d more like that", len(kind)-checkLines))
				break
			}
			out = append(out, line)
		}
	}
	if branch := repo.DefaultBranchRef.Name; branch != "" {
		var runs []ghRun
		if err := ghJSON(d.ctx, gh, folder, &runs, "run", "list", "--branch", branch, "--limit", "30",
			"--json", "workflowName,conclusion,url,createdAt"); err == nil {
			seen := map[string]bool{}
			var failing []string
			for _, run := range runs { // newest first
				if run.Conclusion == "" || seen[run.WorkflowName] {
					continue
				}
				seen[run.WorkflowName] = true
				if failedConclusions[run.Conclusion] {
					failing = append(failing, fmt.Sprintf("CI on %s fails: the newest %q run, at %s, ended %s. %s",
						branch, run.WorkflowName, summaryClock(run.CreatedAt), run.Conclusion, run.URL))
				}
			}
			add(failing)
		}
	}
	var pulls []struct {
		Number    int       `json:"number"`
		Title     string    `json:"title"`
		URL       string    `json:"url"`
		UpdatedAt time.Time `json:"updatedAt"`
		Mergeable string    `json:"mergeable"`
		IsDraft   bool      `json:"isDraft"`
	}
	if err := ghJSON(d.ctx, gh, folder, &pulls, "pr", "list", "--state", "open", "--limit", "100",
		"--json", "number,title,url,updatedAt,mergeable,isDraft"); err == nil {
		var stuck []string
		for _, p := range pulls {
			switch {
			case p.Mergeable == "CONFLICTING":
				stuck = append(stuck, fmt.Sprintf("Pull request #%d %q is in conflict. %s", p.Number, p.Title, p.URL))
			case !p.IsDraft && at.Sub(p.UpdatedAt) > staleAfter:
				stuck = append(stuck, fmt.Sprintf("Pull request #%d %q has not changed for %d days. %s",
					p.Number, p.Title, int(at.Sub(p.UpdatedAt).Hours()/24), p.URL))
			}
		}
		add(stuck)
	}
	var issues []struct {
		Number int    `json:"number"`
		Title  string `json:"title"`
		URL    string `json:"url"`
	}
	if err := ghJSON(d.ctx, gh, folder, &issues, "issue", "list", "--state", "open", "--assignee", "@me",
		"--limit", "100", "--json", "number,title,url"); err == nil {
		taken := d.issueLabels(folder)
		var waiting []string
		for _, i := range issues {
			if !taken[fmt.Sprintf("#%d", i.Number)] {
				waiting = append(waiting, fmt.Sprintf("Issue #%d %q is assigned to you, and no session has it. %s", i.Number, i.Title, i.URL))
			}
		}
		add(waiting)
	}
	return out
}

// issueLabels is every label of the sessions in a folder that are not archived, such as "#12".
func (d *Daemon) issueLabels(folder string) map[string]bool {
	out := map[string]bool{}
	for _, a := range d.Store.Agents() {
		if a.State == wire.AgentStateArchived || filepath.Clean(folderPath(&a)) != filepath.Clean(folder) {
			continue
		}
		for _, l := range a.Labels {
			out[l.Value] = true
		}
	}
	return out
}

// ghJSON runs one read-only gh command in a folder and reads its JSON into out.
func ghJSON(ctx context.Context, gh, folder string, out any, args ...string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, gh, args...)
	cmd.Dir = folder
	cmd.Env = append(os.Environ(), "GH_PROMPT_DISABLED=1", "GH_NO_UPDATE_NOTIFIER=1", "NO_COLOR=1")
	var stdout, errs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &errs
	if err := cmd.Run(); err != nil {
		if line, _, _ := strings.Cut(strings.TrimSpace(errs.String()), "\n"); line != "" {
			return errors.New(line)
		}
		return err
	}
	return json.Unmarshal(stdout.Bytes(), out)
}

// keepSuggestion is check_folders' suggest: it keeps one finding, the newest in place of one
// with the same folder and title, and sends a notice when it is urgent.
func (d *Daemon) keepSuggestion(id wire.UUID, args map[string]json.RawMessage, at time.Time) (string, error) {
	s := checkSuggestion{
		Folder: strings.TrimSpace(argString(args, "folder")),
		Title:  prefix(strings.Join(strings.Fields(argString(args, "title")), " "), 120),
		Prompt: prefix(strings.TrimSpace(argString(args, "prompt")), 2000),
		Link:   strings.TrimSpace(argString(args, "link")),
		Urgent: argBool(args, "urgent"),
		At:     at,
	}
	if s.Title == "" || s.Prompt == "" {
		return "", Invalid("Nothing was kept: send a `title` that says what is wrong and a `prompt` that starts a session on it.")
	}
	known := false
	for _, f := range d.folderPaths() {
		if filepath.Clean(f) == filepath.Clean(s.Folder) {
			s.Folder, known = f, true
		}
	}
	if !known {
		return "", Invalid("Nothing was kept: %q is not a folder on this machine. Send the folder's path as the facts give it.", s.Folder)
	}
	home := d.personalHome()
	checksMu.Lock()
	r := readChecks(home)
	kept := []checkSuggestion{}
	for _, old := range r.Suggestions {
		if (old.Folder != s.Folder || old.Title != s.Title) && at.Sub(old.At) < summaryReach {
			kept = append(kept, old)
		}
	}
	kept = append(kept, s)
	if len(kept) > suggestionsKept {
		kept = kept[len(kept)-suggestionsKept:]
	}
	r.Suggestions = kept
	err := writeChecks(home, r)
	checksMu.Unlock()
	if err != nil {
		return "", &Error{Message: "The suggestion was not kept: " + err.Error()}
	}
	said := "Kept: the next daily summary lists it."
	if s.Urgent {
		if reply, err := d.notify(id, map[string]json.RawMessage{"title": jsonString("Daily checks"),
			"body": jsonString(s.Title + " (" + filepath.Base(s.Folder) + ")")}); err != nil {
			said += " No notice: " + err.Error()
		} else {
			said += " " + reply
		}
	}
	return said, nil
}

// checkSuggestions is what the checks found since, oldest first, for the summary's facts.
func checkSuggestions(home string, since time.Time) []string {
	checksMu.Lock()
	r := readChecks(home)
	checksMu.Unlock()
	var out []string
	for _, s := range r.Suggestions {
		if s.At.Before(since) {
			continue
		}
		line := fmt.Sprintf("%q in %s, at %s. Start a session there with: %s", s.Title, filepath.Base(s.Folder),
			summaryClock(s.At), prefix(strings.Join(strings.Fields(s.Prompt), " "), 200))
		if s.Urgent {
			line = "Urgent: " + line
		}
		if s.Link != "" {
			line += " " + s.Link
		}
		out = append(out, line)
	}
	return out
}
