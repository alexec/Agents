package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The cost on a pull request when it merges (#2352): when the host hears pr.merged for a
// folder whose .agents/folder.json says prCostComment, it posts one comment on the PR with
// what the work cost (the PR's own total and the issues it fixes), and edits that comment
// when more is banked on them later. It never adds a second one.
//
//   - Our store is the master; the comment is a copy (Alex, 2026-10-22). The numbers are
//     this machine's, as lineage/cost's are.
//   - The person's own gh (GitHub) or glab (GitLab) posts it, in the folder, as the Time
//     page asks gh for merged PRs.
//   - The comment starts with prCommentMark, so a host that lost its record, or another
//     machine, finds the comment and edits it.
//   - The setting is read at each post and edit: turned off, the host stops editing.

const (
	prCommentMark = "<!-- agents-cost -->"
	// prCommentsKept bounds the file: the PRs merged longest ago go first.
	prCommentsKept = 500
	// prCommentKeep is how long after its merge a PR's comment is still edited.
	prCommentKeep = 30 * 24 * time.Hour
)

// prCommentAfter is how long the host waits after a change: the changes in it go in one edit.
var prCommentAfter = time.Minute

// prCommentRecord is one merged PR's comment.
type prCommentRecord struct {
	Folder string `json:"folder"`
	Forge  string `json:"forge"`
	Path   string `json:"path"`
	Number int    `json:"number"`
	// ID is the comment's (a GitHub issue comment, a GitLab note), once posted.
	ID       string    `json:"id,omitempty"`
	Body     string    `json:"body,omitempty"`
	MergedAt time.Time `json:"mergedAt"`
	// Parts is the nodes the body added up, by ref: a change to one edits the comment.
	Parts []string `json:"parts,omitempty"`
}

type prCommentFile struct {
	PRs map[string]*prCommentRecord `json:"prs"`
}

type prCommentBook struct {
	commentMu    sync.Mutex
	comments     *prCommentFile
	commentDirty map[string]bool
	commentTimer *time.Timer
	// commentRun keeps one post or edit at a time.
	commentRun sync.Mutex
}

func (d *Daemon) prCommentsPath() string {
	return filepath.Join(d.Store.Loc.Root, "lineage-comments.json")
}

func (d *Daemon) prCommentsLocked() *prCommentFile {
	if d.comments == nil {
		d.comments = &prCommentFile{}
		readStore(d.prCommentsPath(), d.comments, "the merged PRs' cost comments are not edited again")
		if d.comments.PRs == nil {
			d.comments.PRs = map[string]*prCommentRecord{}
		}
		d.commentDirty = map[string]bool{}
	}
	return d.comments
}

// prCostCommentOf is a folder's setting, from .agents/folder.json as last approved.
func (d *Daemon) prCostCommentOf(folder string) wire.PRCostComment {
	m, err := d.approvedConfig(folder)
	if err != nil {
		return wire.PRCostCommentOff
	}
	switch v, _ := m["prCostComment"].(string); wire.PRCostComment(v) {
	case wire.PRCostCommentTokens:
		return wire.PRCostCommentTokens
	case wire.PRCostCommentCost:
		return wire.PRCostCommentCost
	}
	return wire.PRCostCommentOff
}

// prMerged notes a merged PR of repo for its comment, when a folder of that repo says to.
// It runs on the linker's goroutine, after the merge's own links.
func (d *Daemon) prMerged(repo forgeRepo, n int, pr wire.LineageNode) {
	folder := ""
	for _, f := range d.folderPaths() {
		if d.folderRepo(f) == repo && d.prCostCommentOf(f) != wire.PRCostCommentOff {
			folder = f
			break
		}
	}
	if folder == "" {
		return
	}
	d.commentMu.Lock()
	defer d.commentMu.Unlock()
	f := d.prCommentsLocked()
	r, ok := f.PRs[pr.Ref]
	if !ok {
		r = &prCommentRecord{Forge: repo.forge, Path: repo.path, Number: n}
		f.PRs[pr.Ref] = r
	}
	r.Folder, r.MergedAt = folder, nowFunc()
	d.commentDirty[pr.Ref] = true
	d.prCommentSoonLocked()
}

// prCostChanged edits, soon, the comments that added up one of nodes.
func (d *Daemon) prCostChanged(nodes []wire.LineageNode) {
	d.commentMu.Lock()
	defer d.commentMu.Unlock()
	f := d.prCommentsLocked()
	if len(f.PRs) == 0 {
		return
	}
	changed := map[string]bool{}
	for _, n := range nodes {
		changed[n.Ref] = true
	}
	for ref, r := range f.PRs {
		for _, p := range r.Parts {
			if changed[p] {
				d.commentDirty[ref] = true
				d.prCommentSoonLocked()
				break
			}
		}
	}
}

func (d *Daemon) prCommentSoonLocked() {
	if d.commentTimer == nil {
		d.commentTimer = time.AfterFunc(prCommentAfter, func() { safe.Go("pr cost comments", d.flushPRComments) })
	}
}

// flushPRComments posts or edits each comment that changed.
func (d *Daemon) flushPRComments() {
	d.commentRun.Lock()
	defer d.commentRun.Unlock()
	d.commentMu.Lock()
	d.commentTimer = nil
	f := d.prCommentsLocked()
	type job struct {
		ref string
		r   prCommentRecord
	}
	var jobs []job
	for ref := range d.commentDirty {
		if r, ok := f.PRs[ref]; ok {
			jobs = append(jobs, job{ref, *r})
		}
	}
	d.commentDirty = map[string]bool{}
	d.commentMu.Unlock()
	sort.Slice(jobs, func(i, j int) bool { return jobs[i].ref < jobs[j].ref })
	// The links once for every PR, not once each: a merge storm dirties many (#2976).
	if len(jobs) > 0 {
		d.workMu.Lock()
		d.refreshCostLinksLocked()
		d.workMu.Unlock()
	}

	now := nowFunc()
	for _, j := range jobs {
		r := j.r
		mode := d.prCostCommentOf(r.Folder)
		if mode == wire.PRCostCommentOff || now.Sub(r.MergedAt) > prCommentKeep {
			continue
		}
		pr := forgeRepo{r.Forge, r.Path}.pr(r.Number)
		body, parts := d.prCostBody(pr, mode)
		if body == r.Body {
			continue
		}
		id, err := prCommenter(d.ctx, r, body)
		if err != nil {
			log.Printf("lineage: the cost comment on %s was not posted: %v", pr.Ref, err)
			continue
		}
		d.commentMu.Lock()
		if cur, ok := f.PRs[j.ref]; ok {
			cur.ID, cur.Body, cur.Parts = id, body, parts
		}
		d.commentMu.Unlock()
	}
	d.saveComments()
}

// saveComments writes the file, the PRs merged longest ago dropped past the bounds.
func (d *Daemon) saveComments() {
	d.commentMu.Lock()
	defer d.commentMu.Unlock()
	f := d.prCommentsLocked()
	oldest := nowFunc().Add(-prCommentKeep)
	refs := make([]string, 0, len(f.PRs))
	for ref, r := range f.PRs {
		if r.MergedAt.Before(oldest) {
			delete(f.PRs, ref)
			continue
		}
		refs = append(refs, ref)
	}
	if over := len(refs) - prCommentsKept; over > 0 {
		sort.Slice(refs, func(i, j int) bool { return f.PRs[refs[i]].MergedAt.Before(f.PRs[refs[j]].MergedAt) })
		for _, ref := range refs[:over] {
			delete(f.PRs, ref)
		}
	}
	if err := writeStore(d.prCommentsPath(), f); err != nil {
		log.Printf("lineage-comments.json: could not save: %v", err)
	}
}

// prCostBody is the comment on pr: its own total and the issues it fixes, and the refs it
// added up. The caller refreshes the ledger's links first.
func (d *Daemon) prCostBody(pr wire.LineageNode, mode wire.PRCostComment) (string, []string) {
	d.workMu.Lock()
	f := d.costLedgerLocked()
	c := f.Nodes[costKey(pr)]
	total, failed := blankLineageCost(), int64(0)
	lineage.AddCost(&total, c.Banked)
	if c.FailedChecks != nil {
		failed = *c.FailedChecks
	}
	parts := []wire.LineageNode{pr}
	for _, ref := range c.Fixes {
		issue := wire.LineageNode{Kind: lineage.KindIssue, Ref: ref}
		parts = append(parts, issue)
		lineage.AddCost(&total, f.Nodes[costKey(issue)].Banked)
	}
	d.workMu.Unlock()

	refs := make([]string, len(parts))
	for i, p := range parts {
		refs[i] = p.Ref
	}
	return prCostText(total, d.sessionsOn(parts), failed, mode, pr, parts[1:]), refs
}

func blankLineageCost() wire.LineageCost { return wire.LineageCost{Cost: map[string]float64{}} }

// sessionsOn counts the sessions that worked on nodes, and the helpers they started.
func (d *Daemon) sessionsOn(nodes []wire.LineageNode) int {
	seen := map[wire.LineageNode]bool{}
	var next []wire.LineageNode
	for _, n := range nodes {
		for _, l := range d.lineage().Links(n).Links {
			if l.To == n && l.From.Kind == lineage.KindSession && !seen[l.From] {
				seen[l.From] = true
				next = append(next, l.From)
			}
		}
	}
	for range lineage.MostDepth {
		var helpers []wire.LineageNode
		for _, s := range next {
			for _, l := range d.lineage().Links(s).Links {
				if l.From == s && l.Rel == lineage.RelStarted && l.To.Kind == lineage.KindSession && !seen[l.To] {
					seen[l.To] = true
					helpers = append(helpers, l.To)
				}
			}
		}
		if len(helpers) == 0 {
			break
		}
		next = helpers
	}
	return len(seen)
}

// prCostText is the comment's Markdown. GitHub and GitLab draw the same table.
func prCostText(c wire.LineageCost, sessions int, failed int64, mode wire.PRCostComment, pr wire.LineageNode, issues []wire.LineageNode) string {
	var b strings.Builder
	b.WriteString(prCommentMark + "\n**What this cost**\n\n| | |\n| --- | --- |\n")
	if mode == wire.PRCostCommentCost {
		fmt.Fprintf(&b, "| Cost | %s |\n", amountsWords(c.Cost))
	}
	fmt.Fprintf(&b, "| Tokens | %s in, %s out |\n", tokenWords(c.InputTokens), tokenWords(c.OutputTokens))
	fmt.Fprintf(&b, "| Sessions | %d |\n", sessions)
	fmt.Fprintf(&b, "| Agent time | %s |\n", durationWords(c.WorkingSeconds))
	fmt.Fprintf(&b, "| Wait time | %s |\n", durationWords(c.WaitingSeconds))
	fmt.Fprintf(&b, "| Failed CI rounds | %d |\n", failed)
	if len(issues) > 0 {
		names := make([]string, len(issues))
		for i, n := range issues {
			names[i] = shortRef(n.Ref, pr.Ref)
		}
		fmt.Fprintf(&b, "\nWith the work on %s.\n", strings.Join(names, ", "))
	}
	b.WriteString("\nCounted by Agents from its own record. This comment is a copy of it, and is edited when more cost comes in.\n")
	return b.String()
}

// shortRef is an issue as the PR's page names it: #7 in the PR's own repo, owner/repo#7 in another.
func shortRef(ref, pr string) string {
	repo, _, _ := strings.Cut(ref, "#")
	prRepo := pr
	if i := strings.LastIndexAny(pr, "#!"); i > 0 {
		prRepo = pr[:i]
	}
	if repo == prRepo {
		return ref[len(repo):]
	}
	_, id, _ := strings.Cut(ref, ":")
	return id
}

// amountsWords is "$1.25", or "1.25 EUR", one amount for each currency.
func amountsWords(cost map[string]float64) string {
	if len(cost) == 0 {
		return costWords(0, "USD")
	}
	keys := make([]string, 0, len(cost))
	for k := range cost {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	words := make([]string, len(keys))
	for i, k := range keys {
		words[i] = costWords(cost[k], k)
	}
	return strings.Join(words, " + ")
}

// tokenWords is 950, 12.3k or 1.2M.
func tokenWords(n int64) string {
	switch {
	case n >= 1_000_000:
		return strconv.FormatFloat(float64(n)/1_000_000, 'f', 1, 64) + "M"
	case n >= 1_000:
		return strconv.FormatFloat(float64(n)/1_000, 'f', 1, 64) + "k"
	}
	return strconv.FormatInt(n, 10)
}

// durationWords is 45s, 12m or 1h 5m.
func durationWords(seconds float64) string {
	s := int64(math.Round(seconds))
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm", s/60)
	}
	return fmt.Sprintf("%dh %dm", s/3600, s%3600/60)
}

// prCommenter posts the comment, or edits the one r.ID names or the one the PR already has,
// and says its id. Tests replace it.
var prCommenter = func(ctx context.Context, r prCommentRecord, body string) (string, error) {
	switch r.Forge {
	case "github":
		return githubCostComment(ctx, r, body)
	case "gitlab":
		return gitlabCostComment(ctx, r, body)
	}
	return "", fmt.Errorf("no comments on %s", r.Forge)
}

// forgeCLI is the person's gh or glab on the search path, or "".
func forgeCLI(name string) string {
	for _, dir := range searchPaths() {
		p := filepath.Join(dir, name)
		if info, err := os.Stat(p); err == nil && info.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

// runForgeCLI runs gh or glab in folder, with stdin, and says what it wrote.
func runForgeCLI(ctx context.Context, exe, folder string, stdin []byte, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, exe, args...)
	cmd.Dir = folder
	cmd.Env = append(os.Environ(), "GH_PROMPT_DISABLED=1", "GH_NO_UPDATE_NOTIFIER=1", "NO_COLOR=1", "GLAB_NO_PROMPT=1")
	if stdin != nil {
		cmd.Stdin = bytes.NewReader(stdin)
	}
	var out, errs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errs
	if err := cmd.Run(); err != nil {
		if line, _, _ := strings.Cut(strings.TrimSpace(errs.String()), "\n"); line != "" {
			return nil, errors.New(line)
		}
		return nil, err
	}
	return out.Bytes(), nil
}

type forgeComment struct {
	ID   json.Number `json:"id"`
	Body string      `json:"body"`
}

// markedComment is the id of the first of comments that starts with prCommentMark.
func markedComment(comments []forgeComment) string {
	for _, c := range comments {
		if strings.HasPrefix(c.Body, prCommentMark) {
			return c.ID.String()
		}
	}
	return ""
}

func githubCostComment(ctx context.Context, r prCommentRecord, body string) (string, error) {
	gh := forgeCLI("gh")
	if gh == "" {
		return "", errors.New("gh is not installed")
	}
	repo := "repos/" + r.Path
	in, _ := json.Marshal(map[string]string{"body": body})
	id := r.ID
	if id == "" {
		// One JSON array a page: --jq makes each comment a line.
		out, err := runForgeCLI(ctx, gh, r.Folder, nil, "api", "--paginate", fmt.Sprintf("%s/issues/%d/comments", repo, r.Number),
			"--jq", ".[] | {id, body}")
		if err != nil {
			return "", err
		}
		var found []forgeComment
		dec := json.NewDecoder(bytes.NewReader(out))
		dec.UseNumber()
		for dec.More() {
			var c forgeComment
			if dec.Decode(&c) != nil {
				break
			}
			found = append(found, c)
		}
		id = markedComment(found)
	}
	args := []string{"api", "-X", "POST", fmt.Sprintf("%s/issues/%d/comments", repo, r.Number)}
	if id != "" {
		args = []string{"api", "-X", "PATCH", fmt.Sprintf("%s/issues/comments/%s", repo, id)}
	}
	out, err := runForgeCLI(ctx, gh, r.Folder, in, append(args, "--input", "-")...)
	if err != nil && id != "" && r.ID != "" && strings.Contains(err.Error(), "Not Found") {
		// The comment was deleted: post it again.
		r.ID = ""
		return githubCostComment(ctx, r, body)
	}
	if err != nil {
		return "", err
	}
	return commentID(out)
}

func gitlabCostComment(ctx context.Context, r prCommentRecord, body string) (string, error) {
	glab := forgeCLI("glab")
	if glab == "" {
		return "", errors.New("glab is not installed")
	}
	notes := fmt.Sprintf("projects/%s/merge_requests/%d/notes", url.PathEscape(r.Path), r.Number)
	in, _ := json.Marshal(map[string]string{"body": body})
	id := r.ID
	if id == "" {
		out, err := runForgeCLI(ctx, glab, r.Folder, nil, "api", notes+"?per_page=100&sort=asc")
		if err != nil {
			return "", err
		}
		var found []forgeComment
		dec := json.NewDecoder(bytes.NewReader(out))
		dec.UseNumber()
		if dec.Decode(&found) == nil {
			id = markedComment(found)
		}
	}
	args := []string{"api", "-X", "POST", notes}
	if id != "" {
		args = []string{"api", "-X", "PUT", notes + "/" + id}
	}
	out, err := runForgeCLI(ctx, glab, r.Folder, in, append(args, "-H", "Content-Type: application/json", "--input", "-")...)
	if err != nil && id != "" && r.ID != "" && strings.Contains(err.Error(), "404") {
		r.ID = ""
		return gitlabCostComment(ctx, r, body)
	}
	if err != nil {
		return "", err
	}
	return commentID(out)
}

func commentID(out []byte) (string, error) {
	var c forgeComment
	dec := json.NewDecoder(bytes.NewReader(out))
	dec.UseNumber()
	if err := dec.Decode(&c); err != nil || c.ID == "" {
		return "", fmt.Errorf("the forge did not say the comment's id: %v", err)
	}
	return c.ID.String(), nil
}
