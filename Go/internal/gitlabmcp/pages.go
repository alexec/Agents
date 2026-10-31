package gitlabmcp

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// What the views read and do on GitLab (#1631), in the github server's shapes
// (Go/internal/githubmcp/pages.go), so a page is drawn the same way: the open merge requests
// and issues, one merge request's page and its diff, a failed job's log, and a person's
// retry, approve and merge. As the person, with the same token as the events.

// MARK: The board

// pipelineState is a pipeline's status in the github server's words: passing, failing,
// running, skipped or none.
func pipelineState(status string) string {
	switch status {
	case "success":
		return "passing"
	case "failed":
		return "failing"
	case "created", "waiting_for_resource", "preparing", "pending", "running", "scheduled", "manual":
		return "running"
	case "canceled", "skipped":
		return "skipped"
	}
	return "none"
}

// viewer is the person whose token it is, by username.
func (g *RealGitLab) viewer(ctx context.Context) (string, error) {
	var u user
	if err := g.get(ctx, "user", true, &u); err != nil {
		return "", err
	}
	return u.Username, nil
}

// autoMerge says whether it merges once its pipeline succeeds.
func (m mergeRequest) autoMerge() bool { return m.MergeWhenPipelineSucceeds }

// review is changes_requested, review_required or "": GitLab's merge status says whether a
// reviewer asked for changes or approvals are missing.
func (m mergeRequest) review() string {
	switch {
	case m.changesRequested():
		return "changes_requested"
	case m.DetailedMergeStatus == "not_approved":
		return "review_required"
	}
	return ""
}

// changesRequested says a reviewer asked for changes, which blocks the merge.
func (m mergeRequest) changesRequested() bool { return m.DetailedMergeStatus == "requested_changes" }

// Board is the open merge requests, newest created first, each with its head commit's
// pipeline and its section for who is signed in (#2952).
func (g *RealGitLab) Board(ctx context.Context, project string) (map[string]any, error) {
	var mrs []mergeRequest
	if err := g.get(ctx, fmt.Sprintf("projects/%s/merge_requests?state=opened&order_by=created_at&sort=desc&per_page=100", pid(project)), false, &mrs); err != nil {
		return nil, err
	}
	// One listing of the newest pipelines, not one call a merge request: each one's is its
	// head commit's newest.
	var pipelines []pipelineJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines?order_by=id&sort=desc&per_page=100", pid(project)), false, &pipelines); err != nil {
		return nil, err
	}
	bySHA := map[string]pipelineJSON{}
	for _, p := range pipelines {
		if _, ok := bySHA[p.SHA]; !ok {
			bySHA[p.SHA] = p
		}
	}
	viewer, err := g.viewer(ctx)
	if err != nil {
		return nil, err
	}
	authors := make([]user, len(mrs))
	for i, m := range mrs {
		authors[i] = m.Author
	}
	team := g.developers(ctx, project, authors)
	out := make([]any, len(mrs))
	needsYou := 0
	for i, m := range mrs {
		j := m.mr().json()
		j["base"], j["author"], j["updatedAt"], j["draft"], j["autoMerge"], j["checks"] =
			m.TargetBranch, m.Author.Username, m.UpdatedAt, m.draft(), m.autoMerge(), "none"
		if p, ok := bySHA[m.SHA]; ok {
			j["checks"], j["pipelineId"] = pipelineState(p.Status), p.ID
			if p.Status == "failed" {
				j["failedPipelineId"] = p.ID
			}
		}
		if c := m.conflicts(); c != nil {
			j["conflicts"] = *c
		}
		if r := m.review(); r != "" {
			j["review"] = r
		}
		if isBot(m.Author.Username, m.Author.Bot) {
			j["authorBot"] = true
		}
		j["section"] = mrSection(m, j["checks"].(string), viewer, team[m.Author.ID])
		if j["section"] == sectionNeedsYou {
			needsYou++
		}
		out[i] = j
	}
	// count and attention, the Needs you count, are the sidebar row's (#2033).
	return map[string]any{"project": project, "viewer": viewer, "mergeRequests": out, "count": len(out), "attention": needsYou}, nil
}

// MARK: Issues

// OpenIssues are the open issues, newest created first, at most 100, with label's only when it
// is set, each with its section for who is signed in (#2952).
func (g *RealGitLab) OpenIssues(ctx context.Context, project, label string) (map[string]any, error) {
	path := fmt.Sprintf("projects/%s/issues?state=opened&order_by=created_at&sort=desc&per_page=100", pid(project))
	if label != "" {
		path += "&labels=" + url.QueryEscape(label)
	}
	var list []issueJSON
	if err := g.get(ctx, path, false, &list); err != nil {
		return nil, err
	}
	// Without the viewer the list still shows, as Team and Others only.
	viewer, _ := g.viewer(ctx)
	authors := make([]user, len(list))
	for i, is := range list {
		authors[i] = is.Author
	}
	team := g.developers(ctx, project, authors)
	out := make([]any, len(list))
	needsYou := 0
	for i, is := range list {
		j := is.issue().json()
		j["comments"], j["updatedAt"] = is.UserNotesCount, is.UpdatedAt
		if isBot(is.Author.Username, is.Author.Bot) {
			j["authorBot"] = true
		}
		j["section"] = issueSection(is, viewer, team[is.Author.ID])
		if j["section"] == sectionNeedsYou {
			needsYou++
		}
		out[i] = j
	}
	return map[string]any{"project": project, "viewer": viewer, "issues": out, "count": len(out), "attention": needsYou}, nil
}

// MARK: A merge request's page

type discussionJSON struct {
	ID    string     `json:"id"`
	Notes []noteJSON `json:"notes"`
}

// discussions is every discussion on a merge request, a page of 100 at a time, maxPages at most.
func (g *RealGitLab) discussions(ctx context.Context, project string, number int) ([]discussionJSON, error) {
	var all []discussionJSON
	for page := 1; page <= maxPages; page++ {
		var list []discussionJSON
		path := fmt.Sprintf("projects/%s/merge_requests/%d/discussions?per_page=100&page=%d", pid(project), number, page)
		if err := g.get(ctx, path, false, &list); err != nil {
			return nil, err
		}
		all = append(all, list...)
		if len(list) < 100 {
			break
		}
	}
	return all, nil
}

func (n noteJSON) json(base string) map[string]any {
	j := map[string]any{"author": n.Author.Username, "bot": isBot(n.Author.Username, n.Author.Bot), "body": n.Body, "at": n.CreatedAt,
		"url": fmt.Sprintf("%s#note_%d", base, n.ID), "id": n.ID}
	return j
}

// MRPage is one merge request as its page draws it: the github server's pull request page,
// with GitLab's pipeline as its checks and its discussions on lines as its threads.
func (g *RealGitLab) MRPage(ctx context.Context, project string, number int) (map[string]any, error) {
	var m mergeRequest
	if err := g.get(ctx, fmt.Sprintf("projects/%s/merge_requests/%d", pid(project), number), false, &m); err != nil {
		return nil, err
	}
	viewer, err := g.viewer(ctx)
	if err != nil {
		return nil, err
	}
	diff, err := g.parsedDiffs(ctx, project, number, m.SHA)
	if err != nil {
		return nil, err
	}
	additions, deletions := 0, 0
	files := make([]any, len(diff))
	for i, f := range diff {
		additions, deletions = additions+f.additions, deletions+f.deletions
		files[i] = map[string]any{"path": f.NewPath, "additions": f.additions, "deletions": f.deletions, "change": f.change()}
	}
	var discussions []discussionJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/merge_requests/%d/discussions?per_page=100", pid(project), number), false, &discussions); err != nil {
		return nil, err
	}
	conversation, threads := []any{}, []any{}
	for _, d := range discussions {
		if len(d.Notes) == 0 || d.Notes[0].System {
			continue
		}
		first := d.Notes[0]
		comments := make([]any, 0, len(d.Notes))
		for _, n := range d.Notes {
			if !n.System {
				comments = append(comments, n.json(m.WebURL))
			}
		}
		if first.Type != "DiffNote" {
			conversation = append(conversation, comments...)
			continue
		}
		j := map[string]any{"path": "", "resolved": first.Resolved, "outdated": false, "comments": comments}
		if p := first.Position; p != nil {
			j["path"], j["line"] = p.NewPath, p.NewLine
			if p.NewLine == 0 {
				j["path"], j["line"] = p.OldPath, p.OldLine
			}
		}
		threads = append(threads, j)
	}
	sort.SliceStable(conversation, func(i, j int) bool {
		return before(conversation[i].(map[string]any)["at"].(string), conversation[j].(map[string]any)["at"].(string))
	})
	runs := []any{}
	checks, pipelineID := "none", 0
	if p := m.HeadPipeline; p != nil {
		checks, pipelineID = pipelineState(p.Status), p.ID
		var jobs []jobJSON
		if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d/jobs?per_page=100", pid(project), p.ID), false, &jobs); err != nil {
			return nil, err
		}
		for _, job := range jobs {
			state := pipelineState(job.Status)
			if job.Status == "failed" && job.AllowFailure {
				state = "skipped"
			}
			runs = append(runs, map[string]any{"name": job.Stage + ": " + job.Name, "job": job.Name, "state": state, "url": job.WebURL,
				"pipelineId": p.ID})
		}
	}
	state := m.State
	switch state {
	case "merged", "closed":
	default:
		state = "open"
	}
	page := map[string]any{
		"project": project, "number": m.IID, "title": m.Title, "url": m.WebURL, "branch": m.SourceBranch, "base": m.TargetBranch,
		"author": m.Author.Username, "state": state, "draft": m.draft(), "body": m.Description, "createdAt": m.CreatedAt,
		"additions": additions, "deletions": deletions, "checks": checks, "autoMerge": m.autoMerge(), "squash": m.Squash,
		"checkRuns": runs, "files": files, "filesTotal": len(files), "comments": conversation, "threads": threads, "viewer": viewer,
		"fromFork": m.SourceProjectID != m.TargetProjectID, "headSha": m.SHA,
	}
	if pipelineID != 0 {
		page["pipelineId"] = pipelineID
		if checks == "failing" {
			page["failedPipelineId"] = pipelineID
		}
	}
	if c := m.conflicts(); c != nil {
		page["conflicts"] = *c
	}
	if r := m.review(); r != "" {
		page["review"] = r
	}
	return page, nil
}

// MARK: The diff

// diffLines is the most lines of hunks a diff gives, all files together; past it, a file is
// listed with no hunks and the diff says it was cut.
const diffLines = 5000

// DiffLine is one line of a hunk: context, added or removed.
type DiffLine struct {
	Kind string `json:"kind"`
	Text string `json:"text"`
}

// Hunk is one @@ block of a file's diff, as #1472's diff component takes it.
type Hunk struct {
	OldStart int        `json:"oldStart"`
	NewStart int        `json:"newStart"`
	Lines    []DiffLine `json:"lines"`
}

var hunkHead = regexp.MustCompile(`^@@ -([0-9]+)(?:,[0-9]+)? \+([0-9]+)(?:,[0-9]+)? @@`)

// hunks reads a file's diff, as GitLab gives it: from its first @@ on.
func hunks(diff string) []Hunk {
	out := []Hunk{}
	for _, line := range strings.Split(diff, "\n") {
		if m := hunkHead.FindStringSubmatch(line); m != nil {
			oldStart, _ := strconv.Atoi(m[1])
			newStart, _ := strconv.Atoi(m[2])
			out = append(out, Hunk{OldStart: oldStart, NewStart: newStart, Lines: []DiffLine{}})
			continue
		}
		if len(out) == 0 || strings.HasPrefix(line, `\`) { // "\ No newline at end of file"
			continue
		}
		h := &out[len(out)-1]
		switch {
		case strings.HasPrefix(line, "+"):
			h.Lines = append(h.Lines, DiffLine{"added", line[1:]})
		case strings.HasPrefix(line, "-"):
			h.Lines = append(h.Lines, DiffLine{"removed", line[1:]})
		case strings.HasPrefix(line, " "):
			h.Lines = append(h.Lines, DiffLine{"context", line[1:]})
		}
	}
	return out
}

type fileDiff struct {
	OldPath     string `json:"old_path"`
	NewPath     string `json:"new_path"`
	Diff        string `json:"diff"`
	NewFile     bool   `json:"new_file"`
	RenamedFile bool   `json:"renamed_file"`
	DeletedFile bool   `json:"deleted_file"`
	TooLarge    bool   `json:"too_large"`
	Collapsed   bool   `json:"collapsed"`
}

func (f fileDiff) change() string {
	switch {
	case f.NewFile:
		return "added"
	case f.DeletedFile:
		return "removed"
	case f.RenamedFile:
		return "renamed"
	}
	return "modified"
}

// parsedFile is a changed file with its hunks parsed once, and without the diff's text.
type parsedFile struct {
	fileDiff
	hunks                []Hunk
	lines                int
	empty                bool
	additions, deletions int
}

func parse(f fileDiff) parsedFile {
	p := parsedFile{hunks: hunks(f.Diff)}
	for _, h := range p.hunks {
		p.lines += len(h.Lines)
		for _, l := range h.Lines {
			switch l.Kind {
			case "added":
				p.additions++
			case "removed":
				p.deletions++
			}
		}
	}
	p.fileDiff, p.empty = f, f.Diff == ""
	p.Diff = ""
	return p
}

// keptDiff is a merge request's parsed diff at one head.
type keptDiff struct {
	at    time.Time
	files []parsedFile
}

const (
	// diffFor is how long a merge request's parsed diff is kept at one head (P20261020-3): its
	// page reads it again on Refresh, a retry, a comment and an approval, and Show Diff once more.
	diffFor = 5 * time.Minute
	// maxKeptDiffs bounds how many merge requests' diffs are kept.
	maxKeptDiffs = 10
)

// parsedDiffs are a merge request's changed files at head, parsed, kept for diffFor.
func (g *RealGitLab) parsedDiffs(ctx context.Context, project string, number int, head string) ([]parsedFile, error) {
	key := fmt.Sprintf("%s\x00%d\x00%s", project, number, head)
	g.mu.Lock()
	kept, ok := g.kept[key]
	g.mu.Unlock()
	if ok && head != "" && time.Since(kept.at) < diffFor {
		return kept.files, nil
	}
	all, err := g.diffs(ctx, project, number)
	if err != nil {
		return nil, err
	}
	files := make([]parsedFile, len(all))
	for i, f := range all {
		files[i] = parse(f)
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	for k, v := range g.kept {
		if time.Since(v.at) >= diffFor {
			delete(g.kept, k)
		}
	}
	if len(g.kept) >= maxKeptDiffs {
		g.kept = map[string]keptDiff{}
	}
	g.kept[key] = keptDiff{time.Now(), files}
	return files, nil
}

// diffs are a merge request's changed files, at most 1000.
func (g *RealGitLab) diffs(ctx context.Context, project string, number int) ([]fileDiff, error) {
	var all []fileDiff
	for page := 1; page <= maxPages; page++ {
		var list []fileDiff
		if err := g.get(ctx, query(fmt.Sprintf("projects/%s/merge_requests/%d/diffs", pid(project), number), page), false, &list); err != nil {
			return nil, err
		}
		all = append(all, list...)
		if len(list) < perPage {
			break
		}
	}
	return all, nil
}

// MRDiff is a merge request's files with their hunks, as agents/open-diff takes them.
func (g *RealGitLab) MRDiff(ctx context.Context, project string, number int) (map[string]any, error) {
	var m mergeRequest
	if err := g.get(ctx, fmt.Sprintf("projects/%s/merge_requests/%d", pid(project), number), false, &m); err != nil {
		return nil, err
	}
	all, err := g.parsedDiffs(ctx, project, number, m.SHA)
	if err != nil {
		return nil, err
	}
	files := make([]any, 0, len(all))
	left, cut := diffLines, false
	for _, f := range all {
		j := map[string]any{"path": f.NewPath, "change": f.change(), "additions": f.additions, "deletions": f.deletions}
		if f.RenamedFile && f.OldPath != f.NewPath {
			j["previousPath"] = f.OldPath
		}
		h, n := f.hunks, f.lines
		switch {
		case f.TooLarge || f.Collapsed || f.empty:
			j["hunks"], j["note"] = []Hunk{}, "No lines to show: a binary file, a rename, or too long for GitLab to give."
		case n > left:
			j["hunks"], j["note"], cut = []Hunk{}, "Not shown: the diff is too long. Open it on GitLab.", true
		default:
			j["hunks"] = h
			left -= n
		}
		files = append(files, j)
	}
	return map[string]any{"project": project, "number": number, "url": m.WebURL + "/diffs", "files": files, "cut": cut}, nil
}

// MARK: Logs and retries

// logLines is how much of each failed job's log is given: its end, where the failure is.
const logLines = 300

var (
	escapes  = regexp.MustCompile("\x1b\\[[0-9;?]*[ -/]*[@-~]|\x1b\\][^\x07\x1b]*(\x07|\x1b\\\\)")
	controls = regexp.MustCompile("[\x00-\x08\x0b-\x1f\x7f]")
	// sections are GitLab's collapsible-section marks in a job's log.
	sections = regexp.MustCompile(`section_(start|end):[0-9]+:[A-Za-z0-9_.-]+(\[[^\]]*\])?\r?`)
)

// plain is text without terminal escapes, GitLab's section marks or other control
// characters, tabs and newlines kept.
func plain(text string) string {
	return controls.ReplaceAllString(sections.ReplaceAllString(escapes.ReplaceAllString(text, ""), ""), "")
}

// tailSlack is how many lines before the last logLines are kept too, for those at the end
// that are nothing once cleaned (a section's end mark).
const tailSlack = 100

// maxLogLine is how much of one line of a log is kept: its start.
const maxLogLine = 16 << 10

// traceTail is the last n lines of a job's log as it is read, cleaned, without the trailing
// lines that are nothing once cleaned (P20261020-4): a log can be tens of MB, and only its end
// is given, so it is never held whole. The lines are kept in a ring whose slots are used again.
func traceTail(r io.Reader, n int) (string, error) {
	br := bufio.NewReaderSize(r, 64<<10)
	ring := make([][]byte, n+tailSlack)
	next, count := 0, 0
	var line []byte
	for {
		chunk, err := br.ReadSlice('\n')
		if len(line) < maxLogLine {
			line = append(line, chunk[:min(len(chunk), maxLogLine-len(line))]...)
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if len(chunk) > 0 && chunk[len(chunk)-1] == '\n' || (err == io.EOF && len(line) > 0) {
			if line[len(line)-1] == '\n' {
				line = line[:len(line)-1]
			}
			ring[next] = append(ring[next][:0], line...)
			next, count = (next+1)%len(ring), count+1
			line = line[:0]
		}
		if err == io.EOF {
			break
		}
		if err != nil {
			return "", &GitLabError{Kind: Failed, Message: "GitLab: " + err.Error()}
		}
	}
	kept := min(count, len(ring))
	lines := make([]string, 0, kept)
	for i := range kept {
		lines = append(lines, plain(string(ring[(next-kept+i+len(ring))%len(ring)])))
	}
	for len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	return strings.Join(lines, "\n"), nil
}

// FailedLog is the end of each failed job's log in a pipeline (not those allowed to fail), or of one job by name.
func (g *RealGitLab) FailedLog(ctx context.Context, project string, pipelineID int, job string) (string, error) {
	var jobs []jobJSON
	if err := g.get(ctx, fmt.Sprintf("projects/%s/pipelines/%d/jobs?scope[]=failed&per_page=100", pid(project), pipelineID), false, &jobs); err != nil {
		return "", err
	}
	var parts []string
	for _, j := range jobs {
		if j.Status != "failed" || (job != "" && j.Name != job) || (job == "" && j.AllowFailure) {
			continue
		}
		end, err := g.trace(ctx, project, j.ID)
		if err != nil {
			return "", err
		}
		parts = append(parts, fmt.Sprintf("== %s (%s), last %d lines ==\n%s", j.Name, j.WebURL, logLines, end))
	}
	if len(parts) == 0 {
		return fmt.Sprintf("No failed jobs in pipeline %d.", pipelineID), nil
	}
	return strings.Join(parts, "\n\n"), nil
}

// trace is the end of a job's log, read as it comes.
func (g *RealGitLab) trace(ctx context.Context, project string, job int) (string, error) {
	res, err := g.request(ctx, http.MethodGet, fmt.Sprintf("projects/%s/jobs/%d/trace", pid(project), job), nil, "")
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode < 200 || res.StatusCode >= 300 {
		_, err := answer(res)
		return "", err
	}
	return traceTail(res.Body, logLines)
}

// RetryPipeline runs a pipeline's failed and canceled jobs again.
func (g *RealGitLab) RetryPipeline(ctx context.Context, project string, pipelineID int) (map[string]any, error) {
	var p pipelineJSON
	if err := g.send(ctx, http.MethodPost, fmt.Sprintf("projects/%s/pipelines/%d/retry", pid(project), pipelineID), map[string]any{}, &p); err != nil {
		return nil, err
	}
	return map[string]any{"retried": true, "pipelineId": pipelineID, "status": p.Status, "url": p.WebURL}, nil
}

// Approve approves a merge request as the person, at sha: GitLab refuses when its head is
// another commit, and one's own where the project says so.
func (g *RealGitLab) Approve(ctx context.Context, project string, number int, sha string) (map[string]any, error) {
	var out map[string]any
	if err := g.send(ctx, http.MethodPost, fmt.Sprintf("projects/%s/merge_requests/%d/approve", pid(project), number), map[string]any{"sha": sha}, &out); err != nil {
		return nil, err
	}
	return map[string]any{"approved": true, "number": number}, nil
}
