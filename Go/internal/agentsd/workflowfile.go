package agentsd

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/agentsd/yamlnode"
	"github.com/alexec/agents/Go/wire"
)

// A workflow's file, as WorkflowFile, WorkflowFolder and FrontMatter read it on the Swift
// host: <folder>/.agents/workflows/<id>.md, front matter between --- lines and the prompt
// under it. A file that cannot be read is still listed, with what can be read of it and
// why the rest cannot; nothing in it ever runs.

func workflowsFolder(folder string) string { return filepath.Join(folder, workflowsRel) }

const workflowsRel = ".agents/workflows"

// validWorkflowID is WorkflowFolder.isValidID.
func validWorkflowID(id string) bool {
	return id != "" && len(id) <= 200 && !strings.HasPrefix(id, ".") && !strings.ContainsAny(id, "/\\") && id != ".."
}

func workflowPath(folder, id string) (string, bool) {
	if !validWorkflowID(id) {
		return "", false
	}
	p := filepath.Join(workflowsFolder(folder), id+".md")
	if filepath.Dir(p) != filepath.Clean(workflowsFolder(folder)) || !ownFolders(folder, workflowsRel) {
		return "", false
	}
	return p, true
}

func workflowSourcePath(folder, id string, f *workflowFile) (string, bool) {
	if f != nil && f.sourceFolder != "" {
		return workflowPath(f.sourceFolder, id)
	}
	return workflowPath(folder, id)
}

// workflowIDs is WorkflowFolder.ids: the .md files, not hidden, by name.
func workflowIDs(folder string) []string {
	if !ownFolders(folder, workflowsRel) {
		return nil
	}
	entries, err := os.ReadDir(workflowsFolder(folder))
	if err != nil {
		return nil
	}
	var ids []string
	for _, e := range entries {
		n := e.Name()
		if strings.HasPrefix(n, ".") || !strings.HasSuffix(n, ".md") {
			continue
		}
		if id := strings.TrimSuffix(n, ".md"); validWorkflowID(id) {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids
}

// defaultWorkflowName is Workflow.defaultName: "morning-build-check" is "Morning build check".
func defaultWorkflowName(id string) string {
	words := strings.FieldsFunc(id, func(r rune) bool { return r == '-' || r == '_' })
	if len(words) == 0 {
		return id
	}
	r, n := utf8.DecodeRuneInString(words[0])
	words[0] = strings.ToUpper(string(r)) + words[0][n:]
	return strings.Join(words, " ")
}

// readWorkflowFile is WorkflowFile.read: the bytes of a file of its own, not a link, and
// the digest of them.
func readWorkflowFile(path string) (text, digest string, why string) {
	fi, err := os.Lstat(path)
	if err != nil {
		return "", "", "This file could not be read"
	}
	if fi.Mode()&os.ModeSymlink != 0 || links(fi) > 1 {
		return "", "", "This file is a link, and a workflow must be a file of its own"
	}
	f, err := os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return "", "", "This file could not be read"
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil || !st.Mode().IsRegular() || links(st) != 1 {
		return "", "", "This file is a link, and a workflow must be a file of its own"
	}
	b := make([]byte, st.Size())
	if _, err := f.ReadAt(b, 0); err != nil && st.Size() > 0 {
		return "", "", "This file could not be read"
	}
	if !utf8.Valid(b) {
		return "", "", "This file could not be read"
	}
	sum := sha256.Sum256(b)
	return string(b), hex.EncodeToString(sum[:]), ""
}

// A workflow that hands its method to a skill (#1563) names it as
// .agents/skills/<name>/SKILL.md, as scripts/check-workflow-github-reads.py finds it. What
// is approved is the workflow and every skill it names, so a change to one of them waits
// for the person as a change to the workflow does (S20261019-2). A name with a / or ..,
// a skill that is a link or in a folder that is one, or one that is not there, is not
// read, and the workflow does not run.

const skillsRel = ".agents/skills"

var (
	namedSkill = regexp.MustCompile("\\.agents/skills/([^\\s`'\"()<>]*?)/SKILL\\.md")
	skillName  = regexp.MustCompile(`^[\w-]+$`)
)

// workflowSkill is a skill a workflow names, as read now.
type workflowSkill struct{ name, text string }

func skillChangePath(name string) string { return skillsRel + "/" + name + "/SKILL.md" }

// skillPath is a skill's file, when every folder down to it is a folder of the folder's own.
func skillPath(folder, name string) (string, bool) {
	if !skillName.MatchString(name) || !ownFolders(folder, filepath.Join(skillsRel, name)) {
		return "", false
	}
	return filepath.Join(folder, skillsRel, name, "SKILL.md"), true
}

// readWorkflowSkills is the skills a workflow's text names, by name, or why one cannot be read.
func readWorkflowSkills(folder, text string) ([]workflowSkill, string) {
	names := map[string]bool{}
	for _, m := range namedSkill.FindAllStringSubmatch(text, -1) {
		names[m[1]] = true
	}
	var skills []workflowSkill
	for name := range names {
		path, ok := skillPath(folder, name)
		if !ok {
			return nil, "This workflow names " + skillChangePath(name) + ", which is not a file of the folder's own in " + skillsRel
		}
		body, _, why := readWorkflowFile(path)
		if why != "" {
			return nil, "This workflow names " + skillChangePath(name) + ", which could not be read, or is a link"
		}
		skills = append(skills, workflowSkill{name: name, text: body})
	}
	sort.Slice(skills, func(i, j int) bool { return skills[i].name < skills[j].name })
	return skills, ""
}

// workflowDigest is what approval checks: the file's digest, or with skills, one digest of
// the workflow and each skill, every part with its length so that none runs into the next.
func workflowDigest(fileDigest, text string, skills []workflowSkill) string {
	if len(skills) == 0 {
		return fileDigest
	}
	h := sha256.New()
	part := func(s string) { h.Write([]byte(strconv.Itoa(len(s)) + ":" + s)) }
	part(text)
	for _, s := range skills {
		part(s.name)
		part(s.text)
	}
	return hex.EncodeToString(h.Sum(nil))
}

// shownWorkflow is what the person is shown to approve: the workflow, then each skill it names.
func shownWorkflow(text string, skills []workflowSkill) string {
	for _, s := range skills {
		text += "\n\n――― " + skillChangePath(s.name) + " ―――\n\n" + s.text
	}
	return text
}

// workflowFileOf is a workflow as scanLocked lists it, from its file's bytes as
// readWorkflowFile read them.
func workflowFileOf(folder, id, text, digest, why string) *workflowFile {
	if why != "" {
		wf := parseWorkflow("", id, folder)
		wf.Problem = &wire.WorkflowProblem{Unreadable: &wire.WorkflowProblemUnreadable{Value: why}}
		return &workflowFile{wf: wf, sourceFolder: folder, scope: "folder"}
	}
	wf := parseWorkflow(text, id, folder)
	skills, why := readWorkflowSkills(folder, text)
	if why != "" {
		if wf.Problem == nil {
			wf.Problem = &wire.WorkflowProblem{Unreadable: &wire.WorkflowProblemUnreadable{Value: why}}
		}
		return &workflowFile{wf: wf, text: text, sourceFolder: folder, scope: "folder"}
	}
	return &workflowFile{wf: wf, digest: workflowDigest(digest, text, skills), text: text, skills: skills,
		sourceFolder: folder, scope: "folder"}
}

// stripFrontMatter is FrontMatter.strip: what is under the closing ---, blank lines at its
// head left out.
func stripFrontMatter(text string) string {
	lines := strings.Split(text, "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return text
	}
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			rest := lines[i+1:]
			for len(rest) > 0 && strings.TrimSpace(rest[0]) == "" {
				rest = rest[1:]
			}
			return strings.Join(rest, "\n")
		}
	}
	return text
}

func failure(msg string) error { return &yamlnode.Failure{Message: msg} }

func failureMessage(err error, otherwise string) string {
	if f, ok := err.(*yamlnode.Failure); ok {
		return f.Message
	}
	return otherwise
}

// parseCooldown is WorkflowCooldown.parse: digits and m, h or d, at least a minute.
var cooldownPart = regexp.MustCompile(`^(\d+)([mhd])`)

func parseCooldown(text string) (float64, error) {
	t := strings.ToLower(strings.ReplaceAll(text, " ", ""))
	if t == "" {
		return 0, failure("`cooldown:` must be a length of time, like 15m, 2h or 1d, not \"" + text + "\"")
	}
	seconds := 0.0
	for t != "" {
		m := cooldownPart.FindStringSubmatch(t)
		if m == nil {
			return 0, failure("`cooldown:` must be a length of time, like 15m, 2h or 1d, not \"" + text + "\"")
		}
		n, _ := strconv.ParseFloat(m[1], 64)
		seconds += n * map[string]float64{"m": 60, "h": 3600, "d": 86400}[m[2]]
		t = t[len(m[0]):]
	}
	if seconds < 60 {
		return 0, failure("`cooldown:` must be at least a minute, not \"" + text + "\"")
	}
	return seconds, nil
}

// cooldownText is WorkflowCooldown.fileText: 1d2h30m.
func cooldownText(seconds float64) string {
	s := int(seconds)
	out := ""
	if d := s / 86400; d > 0 {
		out += strconv.Itoa(d) + "d"
	}
	if h := s % 86400 / 3600; h > 0 {
		out += strconv.Itoa(h) + "h"
	}
	if m := s % 3600 / 60; m > 0 {
		out += strconv.Itoa(m) + "m"
	}
	return out
}

func flag(n yamlnode.Node, ok bool) *bool {
	if !ok {
		return nil
	}
	switch t, _ := n.Text(); t {
	case "true":
		v := true
		return &v
	case "false":
		v := false
		return &v
	}
	return nil
}

// runsOnLabels is runs-on: (#1761), which replaced hosts:: one label or a list of them.
func runsOnLabels(n yamlnode.Node) ([]string, error) {
	var texts []string
	switch {
	case n.IsMapping():
		return nil, failure("`runs-on:` must be a list of labels")
	case n.IsSequence():
		for _, e := range n.Sequence {
			t, ok := e.Text()
			if !ok {
				return nil, failure("`runs-on:` must be a list of labels")
			}
			texts = append(texts, t)
		}
	default:
		t, _ := n.Text()
		texts = []string{t}
	}
	seen := map[string]bool{}
	var out []string
	for _, t := range texts {
		if t = strings.TrimSpace(t); t != "" && !seen[t] {
			seen[t] = true
			out = append(out, t)
		}
	}
	return out, nil
}

// parseWorkflow is WorkflowFile.parse.
func parseWorkflow(text, id, folder string) wire.Workflow {
	w := wire.Workflow{WorkflowID: id, Folder: store.FolderURL(folder), Name: defaultWorkflowName(id), Triggers: []wire.WorkflowTrigger{},
		Mode: wire.WorkflowModeNew, UnknownFields: map[string]wire.JSONValue{},
		Settings: wire.WorkflowSettings{Options: map[string]string{}, Labels: []string{}}}
	var front []string
	broken := func(why string) wire.Workflow {
		b := w
		b.Problem = &wire.WorkflowProblem{Unreadable: &wire.WorkflowProblemUnreadable{Value: why}}
		if front != nil {
			if m, err := yamlnode.MappingFrom(front); err == nil {
				if n, ok := m["name"].Text(); ok && n != "" {
					b.Name = n
				}
				if on, ok := m["on"]; ok {
					if ts, err := parseTriggers(on); err == nil {
						b.Triggers = ts
					}
				}
				if mode, ok := m["agent"].Text(); ok && (mode == "new" || mode == "standing" || mode == "triggering") {
					b.Mode = wire.WorkflowMode(mode)
				}
				if t, ok := m["cooldown"].Text(); ok {
					if c, err := parseCooldown(t); err == nil {
						b.Cooldown = &c
					}
				}
				e, has := m["enabled"]
				b.Enabled = flag(e, has)
				a, has := m["archived"]
				b.Archived = flag(a, has)
				if t, ok := m["when-done"].Text(); ok {
					if wd, ok := whenDoneOf(t); ok {
						b.WhenDone = &wd
					}
				}
				if h, ok := m["runs-on"]; ok {
					if labels, err := runsOnLabels(h); err == nil && len(labels) > 0 {
						b.RunsOn = labels
					}
				}
			}
		}
		return b
	}
	lines := strings.Split(text, "\n")
	if strings.TrimSpace(lines[0]) != "---" {
		return broken("This file does not start with a metadata block")
	}
	closing := -1
	for i := 1; i < len(lines); i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			closing = i
			break
		}
	}
	if closing < 0 {
		return broken("The metadata block is never closed")
	}
	front = lines[1:closing]
	body := stripFrontMatter(text)
	if strings.TrimSpace(body) == "" {
		return broken("There is no prompt under the metadata")
	}
	m, err := yamlnode.MappingFrom(front)
	if err != nil {
		return broken(failureMessage(err, "The metadata could not be read"))
	}
	if on, ok := m["on"]; ok {
		ts, err := parseTriggers(on)
		if err != nil {
			return broken(failureMessage(err, "The triggers could not be read"))
		}
		w.Triggers = ts
	}
	if named, ok := m["agent"].Text(); ok && named != "" {
		switch named {
		case "new", "standing", "triggering":
			w.Mode = wire.WorkflowMode(named)
		default:
			w.Problem = &wire.WorkflowProblem{UnsupportedMode: &wire.WorkflowProblemUnsupportedMode{Value: named}}
		}
	}
	if w.Problem == nil && len(w.Triggers) > 0 {
		all := true
		for _, t := range w.Triggers {
			all = all && !triggerSupported(t)
		}
		if all {
			w.Problem = &wire.WorkflowProblem{TriggerNotSupported: &wire.WorkflowProblemTriggerNotSupported{Value: triggerName(w.Triggers[0])}}
		}
	}
	if n, ok := m["cooldown"]; ok {
		t, isText := n.Text()
		if !isText {
			return broken("`cooldown:` must be a single value, like 15m")
		}
		if t != "" {
			c, err := parseCooldown(t)
			if err != nil {
				return broken(failureMessage(err, ""))
			}
			w.Cooldown = &c
		}
	}
	for _, key := range []string{"enabled", "archived", "continue-when-back", "muted"} {
		if n, ok := m[key]; ok {
			t, _ := n.Text()
			var v *bool
			switch t {
			case "true":
				b := true
				v = &b
			case "false":
				b := false
				v = &b
			case "":
			default:
				return broken("`" + key + ":` must be true or false")
			}
			switch key {
			case "enabled":
				w.Enabled = v
			case "archived":
				w.Archived = v
			case "muted":
				// Unmuted is no choice at all, as continue-when-back's off is.
				if v != nil && *v {
					w.Muted = v
				}
			default:
				// Off is no choice at all, as when-done's keep is.
				if v != nil && *v {
					w.ContinueWhenBack = v
				}
			}
		}
	}
	if n, ok := m["when-done"]; ok {
		t, isText := n.Text()
		if !isText {
			return broken("`when-done:` must be keep, archive-allowed or archive")
		}
		if t != "" {
			wd, ok := whenDoneOf(t)
			if !ok {
				return broken("`when-done:` must be keep, archive-allowed or archive")
			}
			w.WhenDone = &wd
		}
	}
	if n, ok := m["runs-on"]; ok {
		labels, err := runsOnLabels(n)
		if err != nil {
			return broken(failureMessage(err, ""))
		}
		if len(labels) > 0 {
			w.RunsOn = labels
		}
	}
	s, err := workflowSettings(m)
	if err != nil {
		return broken(failureMessage(err, "The settings could not be read"))
	}
	w.Settings = s
	known := map[string]bool{"on": true, "agent": true, "name": true, "permission-mode": true, "runtime": true, "model": true,
		"labels": true, "effort": true, "options": true, "enabled": true, "archived": true, "cooldown": true, "runs-on": true, "when-done": true,
		"continue-when-back": true, "permission-requests": true, "sandbox": true}
	for k, v := range m {
		if !known[k] {
			b, _ := json.Marshal(v.JSON())
			w.UnknownFields[k] = b
		}
	}
	if n, ok := m["name"].Text(); ok && n != "" {
		w.Name = n
	}
	w.Prompt = body
	return w
}

func whenDoneOf(t string) (wire.WorkflowWhenDone, bool) {
	switch t {
	case "keep", "park":
		return wire.WorkflowWhenDoneKeep, true
	case "archive-allowed":
		return wire.WorkflowWhenDoneArchiveAllowed, true
	case "archive":
		return wire.WorkflowWhenDoneArchive, true
	}
	return "", false
}

// Triggers: a schedule, or a name with what it is narrowed by, carried on the wire as an
// unrecognised trigger is (WorkflowTrigger's Codable).

func parseTriggers(n yamlnode.Node) ([]wire.WorkflowTrigger, error) {
	entries := []yamlnode.Node{n}
	if n.IsSequence() {
		entries = n.Sequence
	}
	out := []wire.WorkflowTrigger{}
	for _, e := range entries {
		if name, ok := e.Text(); ok && (name == "" || name == "manual") {
			continue
		}
		t, err := parseTrigger(e)
		if err != nil {
			return nil, err
		}
		out = append(out, t)
	}
	return out, nil
}

func parseTrigger(n yamlnode.Node) (wire.WorkflowTrigger, error) {
	if name, ok := n.Text(); ok {
		return triggerNamed(name, map[string]yamlnode.Node{})
	}
	if !n.IsMapping() || len(n.Mapping) != 1 {
		return wire.WorkflowTrigger{}, failure("A trigger must be a name, or a name with settings under it")
	}
	for name, v := range n.Mapping {
		if !v.IsMapping() {
			if t, ok := v.Text(); ok && t == "" {
				return triggerNamed(name, map[string]yamlnode.Node{})
			}
			return wire.WorkflowTrigger{}, failure("The settings for \"" + name + "\" are not a list of keys")
		}
		return triggerNamed(name, v.Mapping)
	}
	return wire.WorkflowTrigger{}, failure("A trigger must be a name, or a name with settings under it")
}

func unrecognisedTrigger(name string, keys map[string]any) wire.WorkflowTrigger {
	ks := map[string]wire.JSONValue{}
	for k, v := range keys {
		b, _ := json.Marshal(v)
		ks[k] = b
	}
	return wire.WorkflowTrigger{Unrecognised: &wire.WorkflowTriggerStoredUnrecognised{Name: name, Keys: ks}}
}

func triggerNamed(name string, keys map[string]yamlnode.Node) (wire.WorkflowTrigger, error) {
	if name == "schedule" {
		s, err := parseSchedule(keys)
		if err != nil {
			return wire.WorkflowTrigger{}, err
		}
		return wire.WorkflowTrigger{Schedule: &wire.WorkflowTriggerStoredSchedule{Value: s}}, nil
	}
	raw := map[string]any{}
	for k, v := range keys {
		raw[k] = v.JSON()
	}
	if isServerEventName(name) {
		// A server's event (#383): `noun.verbed`, not the app's, its keys the subscription's
		// arguments rather than details matched here. Whether a server offers it is known
		// only once one is asked, so that is said on the page, not here.
		t := unrecognisedTrigger(name, raw)
		mt, ok := serverTrigger(t)
		if !ok {
			return wire.WorkflowTrigger{}, failure("`server:` under \"" + name + "\" is a server's name, or a list of them")
		}
		if len(canonicalJSON(mustRaw(mt.arguments))) > mcpArgumentLimit {
			return wire.WorkflowTrigger{}, failure("The settings under \"" + name + "\" are over 2 KB")
		}
		return t, nil
	}
	if strings.Contains(name, ".") {
		filters := map[string][]string{}
		keyed := map[string]any{}
		for k, v := range keys {
			if t, ok := v.Text(); ok {
				filters[k] = []string{t}
				keyed[k] = t
				continue
			}
			if v.IsSequence() {
				var ts []string
				for _, e := range v.Sequence {
					if t, ok := e.Text(); ok {
						ts = append(ts, t)
					}
				}
				if len(ts) == len(v.Sequence) && len(ts) > 0 {
					filters[k] = ts
					if len(ts) == 1 {
						keyed[k] = ts[0]
					} else {
						keyed[k] = ts
					}
					continue
				}
			}
			return wire.WorkflowTrigger{}, failure("The \"" + k + "\" under \"" + name + "\" should be one value or a list of values")
		}
		p, problem := parsePattern(name, filters)
		if problem == "" {
			return unrecognisedTrigger(p.name, keyed), nil
		}
		// A key it cannot be narrowed by, or a custom. event, leaves the trigger unreadable.
		if !strings.HasPrefix(problem, "\"") || strings.Contains(problem, "is never raised") {
			return wire.WorkflowTrigger{}, failure(problem)
		}
	}
	return unrecognisedTrigger(name, raw), nil
}

func parseSchedule(keys map[string]yamlnode.Node) (wire.WorkflowSchedule, error) {
	at, ok := keys["at"]
	if !ok {
		return wire.WorkflowSchedule{}, failure("A schedule must say what time with `at:`")
	}
	values, isList := at.Values()
	if !isList || !at.IsSequence() {
		t, _ := at.Text()
		values = []string{t}
	}
	minutes := map[int64]bool{}
	for _, v := range values {
		t := strings.TrimSpace(v)
		n, err := strconv.Atoi(strings.TrimPrefix(t, ":"))
		if !strings.HasPrefix(t, ":") || err != nil || (n != 0 && n != 30) {
			return wire.WorkflowSchedule{}, failure("\"" + t + "\" is not a time a workflow can run at — only \":00\" and \":30\"")
		}
		minutes[int64(n)] = true
	}
	if len(minutes) == 0 {
		return wire.WorkflowSchedule{}, failure("A schedule must say what time with `at:`")
	}
	s := wire.WorkflowSchedule{Hours: [2]int64{0, 23}, StartMinute: 0, EndMinute: 30}
	for m := range minutes {
		s.Minutes = append(s.Minutes, m)
	}
	sort.Slice(s.Minutes, func(i, j int) bool { return s.Minutes[i] < s.Minutes[j] })
	if b, ok := keys["between"].Text(); ok && b != "" {
		halves := strings.SplitN(b, "-", 2)
		bad := failure("\"" + b + "\" is not a range of times, like \"09:00-18:00\"")
		if len(halves) != 2 {
			return wire.WorkflowSchedule{}, bad
		}
		fh, fm, ok1 := clockTime(strings.TrimSpace(halves[0]))
		th, tm, ok2 := clockTime(strings.TrimSpace(halves[1]))
		if !ok1 || !ok2 || fh*60+fm > th*60+tm {
			return wire.WorkflowSchedule{}, bad
		}
		s.Hours, s.StartMinute, s.EndMinute = [2]int64{fh, th}, fm, tm
	}
	all := []wire.Weekday{wire.WeekdaySun, wire.WeekdayMon, wire.WeekdayTue, wire.WeekdayWed, wire.WeekdayThu, wire.WeekdayFri, wire.WeekdaySat}
	s.Days = all
	if n, ok := keys["days"]; ok {
		named, _ := n.Values()
		got := map[wire.Weekday]bool{}
		for _, d := range named {
			w := wire.Weekday(strings.ToLower(strings.TrimSpace(d)))
			valid := false
			for _, x := range all {
				valid = valid || x == w
			}
			if !valid {
				return wire.WorkflowSchedule{}, failure("\"" + d + "\" is not a day of the week")
			}
			got[w] = true
		}
		if len(got) == 0 {
			return wire.WorkflowSchedule{}, failure("`days:` names no days")
		}
		s.Days = nil
		for _, x := range all {
			if got[x] {
				s.Days = append(s.Days, x)
			}
		}
	}
	return s, nil
}

func clockTime(t string) (int64, int64, bool) {
	parts := strings.Split(t, ":")
	if len(parts) < 1 || len(parts) > 2 {
		return 0, 0, false
	}
	h, err := strconv.Atoi(parts[0])
	if err != nil || h < 0 || h > 23 {
		return 0, 0, false
	}
	if len(parts) == 1 {
		return int64(h), 0, true
	}
	m, err := strconv.Atoi(parts[1])
	if err != nil || (m != 0 && m != 30) {
		return 0, 0, false
	}
	return int64(h), int64(m), true
}

func triggerName(t wire.WorkflowTrigger) string {
	if t.Schedule != nil {
		return "schedule"
	}
	if t.Unrecognised != nil {
		return t.Unrecognised.Name
	}
	return ""
}

// triggerPattern is the event pattern a trigger is, when it is one the app raises.
func triggerPattern(t wire.WorkflowTrigger) (waitPattern, bool) {
	u := t.Unrecognised
	if u == nil || !strings.Contains(u.Name, ".") || isServerEventName(u.Name) {
		return waitPattern{}, false
	}
	filters := map[string][]string{}
	for k, raw := range u.Keys {
		var one string
		var list []string
		if json.Unmarshal(raw, &one) == nil {
			filters[k] = []string{one}
		} else if json.Unmarshal(raw, &list) == nil && len(list) > 0 {
			filters[k] = list
		} else {
			return waitPattern{}, false
		}
	}
	p, problem := parsePattern(u.Name, filters)
	return p, problem == ""
}

// triggerSupported is WorkflowTrigger.isSupported: a schedule or an event this host raises.
func triggerSupported(t wire.WorkflowTrigger) bool {
	if t.Schedule != nil {
		return true
	}
	if _, ok := serverTrigger(t); ok {
		return true
	}
	_, ok := triggerPattern(t)
	return ok
}
