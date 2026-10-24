package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	sdk "github.com/coder/acp-go-sdk"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// An agent's changes, as DaemonCore+Changes answers: the edits it reported (the diffs in
// its tool calls) beside what git sees since it started, one row per file.

const (
	listedChanges     = 500
	firstLineLimit    = 2_000_000
	wholeLimit        = 8 << 20
	untrackedLimit    = 1000
	untrackedOutLimit = 256 << 10
)

var diffFlags = []string{"--no-ext-diff", "--no-textconv", "--no-color", "--find-renames"}

// MARK: what the agent reported (ReportedChanges)

type reportedCall struct {
	order      int
	id         string
	diffs      []wire.ToolCallContent
	status     string
	entryIndex int64
	at         wire.Date
	replaceAll bool
}

type reportedChanges struct {
	calls        map[string]*reportedCall
	next         int
	reportsEdits bool
}

func changeKey(path string) string {
	if r, err := store.Resolve(path); err == nil {
		return r
	}
	return canonical(path)
}

// normalisedDiff is ReportedChanges.normalised: a unified diff of a new file, as some
// runtimes report one, read as the file it made.
func normalisedDiff(c wire.ToolCallContent) wire.ToolCallContent {
	nt := ""
	if c.NewText != nil {
		nt = *c.NewText
	}
	if c.OldText != nil && strings.HasPrefix(*c.OldText, "--") && strings.HasSuffix(*c.OldText, "/dev/null") &&
		!strings.Contains(*c.OldText, "\n") && strings.HasPrefix(nt, "++") {
		first, rest, found := strings.Cut(nt, "\n")
		if strings.HasPrefix(first, "++ b/") || strings.HasPrefix(first, "+++ b/") {
			if !found {
				rest = ""
			}
			c.NewText, c.OldText = &rest, nil
		}
	}
	if c.OldText != nil && *c.OldText == "" {
		c.OldText = nil
	}
	return c
}

func foldReported(entries []wire.TranscriptEntry) *reportedChanges {
	f := &reportedChanges{calls: map[string]*reportedCall{}}
	for i, e := range entries {
		var tc *wire.ToolCall
		if e.Kind.ToolCall != nil {
			tc = &e.Kind.ToolCall.Value
		} else if e.Kind.ToolCallUpdate != nil {
			tc = &e.Kind.ToolCallUpdate.Value
		}
		if tc == nil {
			continue
		}
		key := string(e.ID)
		if tc.ToolCallID != nil {
			key = *tc.ToolCallID
		}
		r := f.calls[key]
		if r == nil {
			r = &reportedCall{order: -1, id: key}
			f.calls[key] = r
		}
		if tc.Status != nil {
			r.status = *tc.Status
		}
		var in struct {
			ReplaceAll bool `json:"replace_all"`
		}
		if json.Unmarshal(tc.RawInput, &in) == nil && in.ReplaceAll {
			r.replaceAll = true
		}
		var diffs []wire.ToolCallContent
		for _, c := range tc.Content {
			if c.Type == "diff" && c.Path != nil {
				c = normalisedDiff(c)
				p := changeKey(*c.Path)
				c.Path = &p
				diffs = append(diffs, c)
			}
		}
		if len(diffs) > 0 {
			f.reportsEdits = true
			if r.order < 0 {
				r.order, f.next = f.next, f.next+1
			}
			r.diffs, r.entryIndex, r.at = diffs, int64(i), e.At
		}
	}
	return f
}

func (f *reportedChanges) ordered() []*reportedCall {
	var out []*reportedCall
	for _, c := range f.calls {
		if c.order >= 0 {
			out = append(out, c)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].order < out[j].order })
	return out
}

func (f *reportedChanges) edits() []wire.ReportedEdit {
	var out []wire.ReportedEdit
	for _, c := range f.ordered() {
		if c.status != "completed" {
			continue
		}
		for i, d := range c.diffs {
			nt := ""
			if d.NewText != nil {
				nt = *d.NewText
			}
			out = append(out, wire.ReportedEdit{Path: *d.Path, OldText: d.OldText, NewText: nt, ToolCallID: c.id,
				Index: int64(i), EntryIndex: c.entryIndex, ReplaceAll: c.replaceAll, At: c.at})
		}
	}
	return out
}

func (f *reportedChanges) inProgress() map[string]bool {
	out := map[string]bool{}
	for _, c := range f.ordered() {
		if c.status != "completed" && c.status != "failed" {
			for _, d := range c.diffs {
				out[*d.Path] = true
			}
		}
	}
	return out
}

type fileEdits struct {
	path  string
	edits []wire.ReportedEdit
}

func (f *reportedChanges) byFile() []fileEdits {
	var out []fileEdits
	at := map[string]int{}
	for _, e := range f.edits() {
		i, ok := at[e.Path]
		if !ok {
			i = len(out)
			at[e.Path] = i
			out = append(out, fileEdits{path: e.Path})
		}
		out[i].edits = append(out[i].edits, e)
	}
	return out
}

// lineCount is ReportedEdit.lineCount.
func lineCount(text string) int64 {
	if text == "" {
		return 0
	}
	n := int64(strings.Count(text, "\n"))
	if !strings.HasSuffix(text, "\n") {
		n++
	}
	return n
}

// MARK: helpers

func relativeTo(path, base string) (string, bool) {
	prefix := strings.TrimSuffix(base, "/") + "/"
	if !strings.HasPrefix(path, prefix) {
		return "", false
	}
	return strings.TrimPrefix(path, prefix), true
}

func currentText(path string) (string, bool) {
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() {
		return "", false
	}
	if fi.Size() > firstLineLimit {
		return "", true
	}
	b, _ := os.ReadFile(path)
	return string(b), true
}

func firstLineOf(edits []wire.ReportedEdit, text string) *int64 {
	if len(edits) == 1 && edits[0].OldText == nil {
		one := int64(1)
		return &one
	}
	lines := strings.Split(text, "\n")
	for _, e := range edits {
		for _, w := range strings.Split(e.NewText, "\n") {
			if strings.TrimSpace(w) == "" {
				continue
			}
			for i, l := range lines {
				if l == w {
					n := int64(i + 1)
					return &n
				}
			}
			break
		}
	}
	return nil
}

func reportedFiles(f *reportedChanges, a *wire.Agent) []wire.ChangedFile {
	running := f.inProgress()
	base := store.FolderPath(a.Cwd)
	if a.StartingPoint != nil {
		base = store.FolderPath(a.StartingPoint.Repository)
	}
	base = changeKey(base)
	var files []wire.ChangedFile
	listed := map[string]bool{}
	for _, fe := range f.byFile() {
		current, there := currentText(fe.path)
		state := wire.ChangeStateModified
		switch {
		case !there:
			state = wire.ChangeStateDeleted
		case fe.edits[0].OldText == nil:
			state = wire.ChangeStateAdded
		}
		var added, removed int64
		for _, e := range fe.edits {
			added += lineCount(e.NewText)
			if e.OldText != nil {
				removed += lineCount(*e.OldText)
			}
		}
		file := wire.ChangedFile{Path: fe.path, Source: wire.ChangeSourceReported, State: state, EditCount: int64(len(fe.edits)),
			Added: &added, Removed: &removed, InProgress: running[fe.path]}
		if rel, ok := relativeTo(fe.path, base); ok {
			file.RelativePath = &rel
		} else {
			file.OutsideFolder = true
		}
		if there {
			file.FirstLine = firstLineOf(fe.edits, current)
		}
		files = append(files, file)
		listed[fe.path] = true
	}
	var rest []string
	for p := range running {
		if !listed[p] {
			rest = append(rest, p)
		}
	}
	sort.Strings(rest)
	for _, p := range rest {
		state := wire.ChangeStateAdded
		if _, err := os.Stat(p); err == nil {
			state = wire.ChangeStateModified
		}
		file := wire.ChangedFile{Path: p, Source: wire.ChangeSourceReported, State: state, InProgress: true}
		if rel, ok := relativeTo(p, base); ok {
			file.RelativePath = &rel
		} else {
			file.OutsideFolder = true
		}
		files = append(files, file)
	}
	return files
}

// MARK: what git sees (GitChanges)

type gitContext struct{ root, since, scope string }

func (d *Daemon) gitContext(a *wire.Agent) (*gitContext, wire.GitView) {
	unavailable := func(u wire.ChangesUnavailable) wire.GitView { return wire.GitView{Unavailable: &u} }
	cwd := store.FolderPath(a.Cwd)
	if !isDir(cwd) {
		return nil, unavailable(wire.ChangesUnavailable{FolderGone: &struct{}{}})
	}
	var ctx gitContext
	var view wire.GitView
	if a.StartingPoint != nil && isDir(store.FolderPath(a.StartingPoint.Repository)) {
		ctx.root, ctx.since = store.FolderPath(a.StartingPoint.Repository), a.StartingPoint.Commit
		if d.ownsItsFolder(a) {
			view.Owned = &wire.GitViewOwned{Since: ctx.since}
		} else {
			view.Shared = &wire.GitViewShared{Since: ctx.since}
		}
	} else if top, err := git(cwd, "rev-parse", "--show-toplevel"); err == nil {
		ctx.root, ctx.since, view.SharedFromHead = top, "HEAD", &struct{}{}
	} else {
		if ge, ok := err.(*gitError); ok && ge.message == "Git is not installed on this Mac." {
			return nil, unavailable(wire.ChangesUnavailable{GitNotInstalled: &struct{}{}})
		}
		return nil, unavailable(wire.ChangesUnavailable{NotARepository: &struct{}{}})
	}
	ctx.root = changeKey(ctx.root)
	if rel, ok := relativeTo(changeKey(cwd), ctx.root); ok && rel != "" {
		ctx.scope = rel
	}
	return &ctx, view
}

func (d *Daemon) ownsItsFolder(a *wire.Agent) bool {
	if a.Worktree == nil {
		return false
	}
	root := changeKey(store.FolderPath(a.Worktree.Root))
	for _, o := range d.Store.Agents() {
		if o.ID != a.ID && o.State != wire.AgentStateArchived && inside(root, changeKey(store.FolderPath(o.Cwd))) {
			return false
		}
	}
	return true
}

type gitChange struct {
	path, status, oldPath string
	added, removed        *int64
}

func changesGit(root string, args ...string) ([]byte, error) {
	return gitRaw(root, nil, append([]string{"-c", "core.quotepath=off"}, args...)...)
}

func scoped(args []string, scope string) []string {
	args = append(args, "--")
	if scope != "" {
		args = append(args, scope)
	}
	return args
}

// changedSince is GitChanges.changed: the diff since the start, names and counts, and the
// untracked files.
func changedSince(c *gitContext) ([]gitChange, error) {
	numstat, err := changesGit(c.root, scoped(append(append([]string{"diff", "--numstat", "-z"}, diffFlags...), c.since), c.scope)...)
	if err != nil {
		return nil, err
	}
	names, err := changesGit(c.root, scoped(append(append([]string{"diff", "--name-status", "-z"}, diffFlags...), c.since), c.scope)...)
	if err != nil {
		return nil, err
	}
	others, err := changesGit(c.root, scoped([]string{"ls-files", "--others", "--exclude-standard", "-z"}, c.scope)...)
	if err != nil {
		return nil, err
	}
	counts := map[string][2]*int64{}
	fields := strings.Split(string(numstat), "\x00")
	for i := 0; i < len(fields); i++ {
		parts := strings.SplitN(fields[i], "\t", 3)
		if len(parts) != 3 {
			continue
		}
		path := parts[2]
		if path == "" && i+2 < len(fields) { // a rename: old, then new
			path = fields[i+2]
			i += 2
		}
		var a, r *int64
		if parts[0] != "-" {
			n, _ := strconv.ParseInt(parts[0], 10, 64)
			m, _ := strconv.ParseInt(parts[1], 10, 64)
			a, r = &n, &m
		}
		counts[path] = [2]*int64{a, r}
	}
	var out []gitChange
	nf := strings.Split(string(names), "\x00")
	for i := 0; i+1 < len(nf); i++ {
		status := nf[i]
		if status == "" {
			continue
		}
		c := gitChange{status: status[:1]}
		switch c.status {
		case "R":
			if i+2 >= len(nf) {
				continue
			}
			c.oldPath, c.path = nf[i+1], nf[i+2]
			i += 2
		case "C":
			if i+2 >= len(nf) {
				continue
			}
			c.status, c.path = "A", nf[i+2]
			i += 2
		default:
			c.path = nf[i+1]
			i++
		}
		n := counts[c.path]
		c.added, c.removed = n[0], n[1]
		out = append(out, c)
	}
	raw := others
	if len(raw) > untrackedOutLimit {
		raw = raw[:untrackedOutLimit]
		if i := bytes.LastIndexByte(raw, 0); i >= 0 {
			raw = raw[:i+1]
		}
	}
	n := 0
	for _, p := range strings.Split(string(raw), "\x00") {
		if p == "" || n >= untrackedLimit || p == ".agents/" || strings.HasPrefix(p, ".agents/") {
			continue
		}
		out = append(out, gitChange{path: p, status: "?"})
		n++
	}
	return out, nil
}

func untrackedCount(path string) (int64, bool) {
	fi, err := os.Stat(path)
	if err != nil || !fi.Mode().IsRegular() || fi.Size() > firstLineLimit {
		return 0, false
	}
	b, err := os.ReadFile(path)
	if err != nil || bytes.IndexByte(b[:min(len(b), 8000)], 0) >= 0 {
		return 0, false
	}
	return lineCount(string(b)), true
}

func mergeChanges(changed []gitChange, files []wire.ChangedFile, c *gitContext, a *wire.Agent) []wire.ChangedFile {
	index := map[string]int{}
	for i, f := range files {
		index[f.Path] = i
	}
	base := store.FolderPath(a.Cwd)
	if a.StartingPoint != nil {
		base = store.FolderPath(a.StartingPoint.Repository)
	}
	base = changeKey(base)
	var seen []wire.ChangedFile
	renamedAway := map[string]bool{}
	for _, ch := range changed {
		path := c.root + "/" + ch.path
		added, removed := ch.added, ch.removed
		binary := ch.added == nil && ch.status != "?" && ch.status != "D"
		if ch.status == "?" {
			if n, ok := untrackedCount(path); ok {
				zero := int64(0)
				added, removed = &n, &zero
			} else {
				binary = true
			}
		}
		state := wire.ChangeStateModified
		switch {
		case binary:
			state = wire.ChangeStateBinary
		case ch.status == "D":
			state = wire.ChangeStateDeleted
		case ch.status == "A":
			state = wire.ChangeStateAdded
		case ch.status == "?":
			state = wire.ChangeStateUntracked
		case ch.status == "R":
			state = wire.ChangeStateRenamed
		}
		if binary {
			added, removed = nil, nil
		}
		var oldPath *string
		if ch.oldPath != "" {
			p := c.root + "/" + ch.oldPath
			oldPath = &p
		}
		if at, ok := index[path]; ok && at >= 0 {
			files[at].Source, files[at].State, files[at].Added, files[at].Removed, files[at].OldPath =
				wire.ChangeSourceReportedAndSeen, state, added, removed, oldPath
		} else {
			f := wire.ChangedFile{Path: path, Source: wire.ChangeSourceSeen, State: state, Added: added, Removed: removed, OldPath: oldPath}
			rel, ok := relativeTo(path, base)
			if !ok {
				rel = ch.path
			}
			f.RelativePath = &rel
			seen = append(seen, f)
			index[path] = -1
		}
		if oldPath != nil {
			if at, ok := index[*oldPath]; ok && at >= 0 {
				renamedAway[*oldPath] = true
				merged := false
				for i := range files {
					if files[i].Path == path {
						files[i].EditCount += files[at].EditCount
						merged = true
					}
				}
				if !merged {
					for i := range seen {
						if seen[i].Path == path {
							seen[i].EditCount += files[at].EditCount
							seen[i].Source = wire.ChangeSourceReportedAndSeen
						}
					}
				}
			}
		}
	}
	var out []wire.ChangedFile
	for _, f := range files {
		if !renamedAway[f.Path] {
			out = append(out, f)
		}
	}
	sort.SliceStable(seen, func(i, j int) bool { return seen[i].Path < seen[j].Path })
	return append(out, seen...)
}

// replayAccounts is EditReplay.accounts: whether the reported edits, applied to the file as
// it started, make it as it is now.
func replayAccounts(edits []wire.ReportedEdit, start, now string) bool {
	text := start
	if len(edits) > 0 && edits[0].OldText == nil {
		text = ""
	}
	for _, e := range edits {
		switch {
		case e.OldText == nil || *e.OldText == "":
			text = e.NewText
		case *e.OldText == text:
			text = e.NewText
		case !strings.Contains(text, *e.OldText):
			return false
		case e.ReplaceAll:
			text = strings.ReplaceAll(text, *e.OldText, e.NewText)
		default:
			text = strings.Replace(text, *e.OldText, e.NewText, 1)
		}
	}
	return text == now || strings.TrimSuffix(text, "\n") == strings.TrimSuffix(now, "\n")
}

func markBeyondReported(files []wire.ChangedFile, f *reportedChanges, c *gitContext) {
	edits := map[string][]wire.ReportedEdit{}
	for _, fe := range f.byFile() {
		edits[fe.path] = fe.edits
	}
	var checked []int
	var request strings.Builder
	var rels []string
	for i, file := range files {
		if file.Source != wire.ChangeSourceReportedAndSeen || file.State == wire.ChangeStateBinary || file.State == wire.ChangeStateDeleted {
			continue
		}
		start := file.Path
		if file.OldPath != nil {
			start = *file.OldPath
		}
		rel, ok := relativeTo(start, c.root)
		if !ok {
			continue
		}
		checked = append(checked, i)
		rels = append(rels, rel)
		request.WriteString(c.since + ":" + rel + "\n")
	}
	if len(checked) == 0 {
		return
	}
	out, _ := gitRaw(c.root, []byte(request.String()), "-c", "core.quotepath=off", "cat-file", "--batch")
	starts := parseBatch(out, rels)
	for k, i := range checked {
		now, ok := currentText(files[i].Path)
		made := edits[files[i].Path]
		if !ok || made == nil {
			continue
		}
		files[i].BeyondReported = !replayAccounts(made, starts[rels[k]], now)
	}
}

func parseBatch(data []byte, paths []string) map[string]string {
	out := map[string]string{}
	cur := 0
	for _, p := range paths {
		nl := bytes.IndexByte(data[cur:], '\n')
		if nl < 0 {
			break
		}
		header := strings.Fields(string(data[cur : cur+nl]))
		cur += nl + 1
		if len(header) != 3 {
			continue
		}
		size, err := strconv.Atoi(header[2])
		if err != nil {
			continue
		}
		end := min(cur+size, len(data))
		if header[1] == "blob" {
			out[p] = string(data[cur:end])
		}
		cur = min(end+1, len(data))
	}
	return out
}

func (d *Daemon) changes(a *wire.Agent) (wire.ChangesList, *reportedChanges, *gitContext) {
	entries, _, _ := d.Store.Transcript(a.ID, 0)
	f := foldReported(entries)
	files := reportedFiles(f, a)
	c, view := d.gitContext(a)
	list := wire.ChangesList{Files: files, Git: view, ReportsEdits: f.reportsEdits}
	if c != nil {
		changed, err := changedSince(c)
		if err != nil {
			u := wire.ChangesUnavailable{Failed: &wire.ChangesUnavailableFailed{Message: err.Error()}}
			list.Git = wire.GitView{Unavailable: &u}
			c = nil
		} else {
			list.Files = mergeChanges(changed, files, c, a)
			markBeyondReported(list.Files, f, c)
		}
	}
	if list.Files == nil {
		list.Files = []wire.ChangedFile{}
	}
	return list, f, c
}

func allLines(text string, kind wire.DiffLineKind) []wire.DiffLine {
	lines := strings.Split(text, "\n")
	if lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	out := []wire.DiffLine{}
	for i, l := range lines {
		n := int64(i + 1)
		out = append(out, wire.DiffLine{Kind: kind, Text: l, NewLine: &n})
	}
	return out
}

// wholeDiff is GitChanges.whole: the file whole, as a diff since the start.
func wholeDiff(c *gitContext, rel, oldRel string) []wire.DiffLine {
	paths := []string{rel}
	if oldRel != "" {
		paths = []string{oldRel, rel}
	}
	args := append(append(append([]string{"diff", "-U999999"}, diffFlags...), c.since, "--"), paths...)
	out, err := changesGit(c.root, args...)
	if err != nil || len(out) >= gitOutputLimit || len(out) > wholeLimit {
		return nil
	}
	text := string(out)
	if strings.HasPrefix(text, "Binary files ") || strings.Contains(text, "\nBinary files ") {
		return nil
	}
	var lines []wire.DiffLine
	hunks, newLine := 0, int64(0)
	for _, l := range strings.Split(text, "\n") {
		if strings.HasPrefix(l, "@@") {
			hunks++
			for _, part := range strings.Fields(l) {
				if strings.HasPrefix(part, "+") {
					n, _ := strconv.ParseInt(strings.Split(part[1:], ",")[0], 10, 64)
					newLine = n
				}
			}
			continue
		}
		if hunks == 0 || l == "" {
			continue
		}
		body := l[1:]
		switch l[0] {
		case ' ', '+':
			n := newLine
			kind := wire.DiffLineKindContext
			if l[0] == '+' {
				kind = wire.DiffLineKindAdded
			}
			lines = append(lines, wire.DiffLine{Kind: kind, Text: body, NewLine: &n})
			newLine++
		case '-':
			lines = append(lines, wire.DiffLine{Kind: wire.DiffLineKindRemoved, Text: body})
		}
	}
	if hunks == 0 {
		b, err := os.ReadFile(filepath.Join(c.root, rel))
		if err != nil || len(b) > wholeLimit {
			return nil
		}
		return allLines(string(b), wire.DiffLineKindContext)
	}
	return lines
}

func (d *Daemon) registerChanges() {
	On(d, wire.CallAgentsFork, func(ctx context.Context, cl *Client, r wire.AgentRequest) (wire.UUID, error) {
		return d.fork(ctx, r.AgentID)
	})
	On(d, wire.CallAgentsBranchFrom, func(ctx context.Context, cl *Client, r wire.BranchFromRequest) (wire.UUID, error) {
		return d.branchFrom(r)
	})
	On(d, wire.CallChangesList, func(ctx context.Context, cl *Client, r wire.ChangesListRequest) (wire.ChangesList, error) {
		a := d.Store.Agent(r.AgentID)
		if a == nil {
			return wire.ChangesList{}, noSuchAgent()
		}
		list, _, _ := d.changes(a)
		if n := len(list.Files); n > listedChanges {
			more := int64(n - listedChanges)
			list.More = &more
			list.Files = list.Files[:listedChanges]
		}
		return list, nil
	})
	On(d, wire.CallChangesFile, func(ctx context.Context, cl *Client, r wire.ChangesFileRequest) (wire.ChangedFileDetail, error) {
		a := d.Store.Agent(r.AgentID)
		if a == nil {
			return wire.ChangedFileDetail{}, noSuchAgent()
		}
		list, f, c := d.changes(a)
		path := changeKey(r.Path)
		var file *wire.ChangedFile
		for i := range list.Files {
			if list.Files[i].Path == path {
				file = &list.Files[i]
			}
		}
		if file == nil {
			return wire.ChangedFileDetail{}, &Error{Code: wire.FailureNotChanged, Message: filepath.Base(path) + " has not changed."}
		}
		detail := wire.ChangedFileDetail{File: *file, Edits: []wire.ReportedEdit{}}
		for _, fe := range f.byFile() {
			if fe.path == path {
				detail.Edits = fe.edits
			}
		}
		if r.Whole && c != nil && !file.OutsideFolder && file.State != wire.ChangeStateBinary {
			if rel, ok := relativeTo(path, c.root); ok {
				if file.State == wire.ChangeStateAdded || file.State == wire.ChangeStateUntracked {
					if text, ok := currentText(path); ok {
						detail.Whole = allLines(text, wire.DiffLineKindAdded)
					}
				} else {
					oldRel := ""
					if file.OldPath != nil {
						oldRel, _ = relativeTo(*file.OldPath, c.root)
					}
					detail.Whole = wholeDiff(c, rel, oldRel)
				}
			}
		}
		return detail, nil
	})
}

// nobody is a sink for a runtime started only to answer a question of the host's.
type nobody struct{}

func (nobody) Update(sdk.SessionNotification)                                  {}
func (nobody) Permission(context.Context, sdk.RequestPermissionRequest) string { return "" }
func (nobody) Served(string, string)                                           {}
func (nobody) Elicitation(context.Context, json.RawMessage) (string, map[string]any) {
	return "cancel", nil
}
func (nobody) ElicitationComplete(string) {}

// fork is agents/fork (DaemonCore.fork): the runtime branches the conversation, and a new
// agent holds the branch, with the record so far, where the first one works.
func (d *Daemon) fork(ctx context.Context, id wire.UUID) (wire.UUID, error) {
	a := d.Store.Agent(id)
	if a == nil {
		return "", noSuchAgent()
	}
	if err := d.refuseToRun(a); err != nil {
		return "", err
	}
	if err := d.promptRefusal(a); err != nil {
		return "", err
	}
	if a.RuntimeSessionID == nil {
		return "", &Error{Code: wire.FailureSessionGone, Message: "That agent has no conversation to branch yet."}
	}
	rt := runtimeByID(a.RuntimeID)
	if rt == nil {
		return "", &Error{Code: CodeRuntimeNotFound, Message: "There is no runtime called " + a.RuntimeID + "."}
	}
	cwd := store.FolderPath(a.Cwd)
	account, err := d.accountFor(a)
	if err != nil {
		return "", err
	}
	launch, err := d.launchAs(rt, cwd, account)
	if err != nil {
		return "", &Error{Code: CodeRuntimeNotFound, Message: err.Error()}
	}
	meta := agentSessionMeta(a)
	brief := d.briefFor(a)
	forked, err := acp.Fork(ctx, launch, nobody{}, *a.RuntimeSessionID, cwd, meta, withSystemPrompt(meta, a.RuntimeID, brief), brief)
	switch {
	case errors.Is(err, acp.ErrCannotFork):
		return "", &Error{Code: wire.FailureNotSupported, Message: a.RuntimeID + " cannot branch a conversation."}
	case errors.Is(err, acp.ErrConversationGone):
		return "", &Error{Code: wire.FailureSessionGone, Message: rt.Name + " no longer has this conversation."}
	case err != nil:
		return "", &Error{Code: CodeServer, Message: err.Error()}
	}
	t := now()
	b := wire.Agent{ID: store.NewUUID(), RuntimeID: a.RuntimeID, Cwd: a.Cwd, State: wire.AgentStateFinished,
		EndedReason: reason(wire.EndedReasonEndTurn), RuntimeSessionID: &forked, StartOptions: a.StartOptions,
		AdvertisedOptions: a.AdvertisedOptions, AvailableCommands: a.AvailableCommands, AdditionalDirectories: a.AdditionalDirectories,
		McpServers: a.McpServers, Worktree: a.Worktree, StartingPoint: a.StartingPoint, MadeInRoot: &d.Store.RootID,
		CreatedAt: t, LastActivityAt: t, AccountID: a.AccountID}
	if a.Title != nil {
		title := *a.Title + " (branch)"
		b.Title = &title
	}
	if err := d.Store.Save(b); err != nil {
		return "", err
	}
	entries, _, _ := d.Store.Transcript(a.ID, 0)
	for _, e := range entries[:min(len(entries), 10000)] {
		d.Store.Append(b.ID, e)
	}
	from := "another agent"
	if a.Title != nil {
		from = *a.Title
	}
	d.record(b.ID, runtimeNote("Branched from "+from+"."))
	d.change(b.ID, func(*wire.Agent) {})
	return b.ID, nil
}

// branchFrom is agents/branchFrom (#1658): a new agent goes on from just before one of the
// person's prompts, with the record up to there. ACP branches a conversation only at its
// end (session/fork), so the new agent has no conversation of its own yet: its runtime
// reads that record ahead of its first prompt (branchPreface), on every runtime.
func (d *Daemon) branchFrom(r wire.BranchFromRequest) (wire.UUID, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return "", noSuchAgent()
	}
	if err := d.refuseToRun(a); err != nil {
		return "", err
	}
	if err := d.promptRefusal(a); err != nil {
		return "", err
	}
	entries, _, err := d.Store.Transcript(a.ID, 0)
	if err != nil {
		return "", err
	}
	at := -1
	for i, e := range entries {
		if e.ID == r.EntryID && e.Kind.UserMessage != nil {
			at = i
			break
		}
	}
	if at < 0 {
		return "", Invalid("That prompt is not in this session's record.")
	}
	t := now()
	b := wire.Agent{ID: store.NewUUID(), RuntimeID: a.RuntimeID, Cwd: a.Cwd, State: wire.AgentStateFinished,
		EndedReason: reason(wire.EndedReasonEndTurn), StartOptions: a.StartOptions,
		AdvertisedOptions: a.AdvertisedOptions, AvailableCommands: a.AvailableCommands, AdditionalDirectories: a.AdditionalDirectories,
		McpServers: a.McpServers, Worktree: a.Worktree, StartingPoint: a.StartingPoint, MadeInRoot: &d.Store.RootID,
		SandboxOverride: a.SandboxOverride, BranchedFrom: &a.ID, CreatedAt: t, LastActivityAt: t,
		AccountID: a.AccountID}
	if a.Title != nil {
		title := *a.Title + " (branch)"
		b.Title = &title
	}
	if err := d.Store.Save(b); err != nil {
		return "", err
	}
	if _, err := d.Store.AppendMany(b.ID, entries[:min(at, 10000)]); err != nil {
		return "", err
	}
	from := "another agent"
	if a.Title != nil {
		from = *a.Title
	}
	d.record(b.ID, runtimeNote("Branched from "+from+" before its prompt "+strconv.Itoa(promptNumber(entries[:at+1]))+". "+branchFilesNote))
	d.change(b.ID, func(*wire.Agent) {})
	return b.ID, nil
}

// branchFilesNote ends a Branch from Here note (#1871): the branch shares the folder and
// worktree, so the record goes back and the files do not. The clients' help says it too.
const branchFilesNote = "The files stay as they are now."

// promptNumber is how many of the person's prompts these entries hold, as the Prompts
// list numbers them.
func promptNumber(entries []wire.TranscriptEntry) int {
	n := 0
	for _, e := range entries {
		if m := e.Kind.UserMessage; m != nil && (m.From == nil || *m.From == wire.PromptOriginPerson) {
			n++
		}
	}
	return n
}

// branchPreface is what a branch's runtime reads ahead of its first prompt: the record it
// was branched with, as read_session writes a session. Nil for any other agent, and once
// the branch has a conversation of its own.
func (d *Daemon) branchPreface(a *wire.Agent) *string {
	if a.BranchedFrom == nil || a.RuntimeSessionID != nil {
		return nil
	}
	entries, _, err := d.Store.Transcript(a.ID, 0)
	if err != nil {
		return nil
	}
	header := "This conversation goes on from an earlier one: the person branched it from just before one of their prompts. " +
		"Below is the app's record of that conversation up to there. Carry on from it as if it were your own; " +
		"the person's next words follow it.\n\n"
	p := history(a, entries, header)
	return &p
}
