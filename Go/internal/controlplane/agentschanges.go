package controlplane

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The changes in Agents between two versions (#5273, spec 5239 board 6): a version names its
// commit (agentsVersion), so the changes from one to another are GitHub's compare of the two
// commits in agentsRepo. The repo is public, so the compare needs no token. A compare of two
// commits never changes, so each is kept in memory, at most agentsComparesKept, and
// GitHub's limit for a caller with no token (60 an hour) is spent once for each pair.

const (
	// agentsComparesKept bounds the compares kept: the one asked longest ago goes first.
	agentsComparesKept = 256
	// mostAgentsChanges bounds one answer's changes, and the pages asked for it.
	mostAgentsChanges = 1000
	// agentsChangesPage is GitHub's largest page of a compare's commits.
	agentsChangesPage = 100
	// agentsChangesShown is how many changes a machine's page shows before Show all.
	agentsChangesShown = 6
	// mostOthersCompared bounds the other machines a page compares with this one; the rest
	// show their versions alone (#5289 groups them at 100 or more).
	mostOthersCompared = 20
)

// agentsGitHub is where the compares are asked; a test sets its own.
var agentsGitHub = "https://api.github.com"

// agentsCompareBook keeps the compares; its zero value is ready.
type agentsCompareBook struct {
	mu   sync.Mutex
	kept map[string]agentsCompare
	// get asks GitHub; nil is the HTTP client below. A test sets its own.
	get func(ctx context.Context, address string) ([]byte, error)
}

// agentsCompare is one compare: its counts, and its newest commits as far as they were read.
type agentsCompare struct {
	ahead, behind int
	// newest are head's new commits, newest first; all is true when they are every one
	// (up to mostAgentsChanges).
	newest []wire.AgentsChange
	all    bool
	asked  time.Time
}

// agentsCommit is the commit a version was built from, or none for a version of another form.
func agentsCommit(version string) string {
	v := agentsVersion(strings.TrimSpace(version))
	if len(v.Artifacts) == 1 && v.Artifacts[0].Kind == "commit" {
		return v.Artifacts[0].ID
	}
	return ""
}

// agentsChanges is machines/agentsChanges's answer: the changes from version base to version
// head, newest first, at most limit (0: all, up to mostAgentsChanges; less than 0: the
// counts alone).
func (s *Service) agentsChanges(ctx context.Context, base, head string, limit int) (wire.AgentsChanges, error) {
	out := wire.AgentsChanges{Base: base, Head: head, Changes: []wire.AgentsChange{}}
	from, to := agentsCommit(base), agentsCommit(head)
	if from == "" || to == "" {
		return out, fail(invalidParams, "%s and %s do not both name a commit of Agents.", base, head)
	}
	if limit == 0 || limit > mostAgentsChanges {
		limit = mostAgentsChanges
	}
	limit = max(limit, 0)
	c, err := s.agentsCompares.compare(ctx, from, to, limit)
	if err != nil {
		return out, fail(storeUnavailable, "GitHub did not say the changes from %s to %s: %v", base, head, err)
	}
	out.Ahead, out.Behind = int64(c.ahead), int64(c.behind)
	shown := c.newest[:min(len(c.newest), limit)]
	out.Changes = append(out.Changes, shown...)
	out.Complete = len(shown) == c.ahead
	return out, nil
}

// compare is the compare of from and to with at least the newest want commits read (or every
// one), from what is kept or from GitHub.
func (b *agentsCompareBook) compare(ctx context.Context, from, to string, want int) (agentsCompare, error) {
	key := from + "..." + to
	b.mu.Lock()
	c, found := b.kept[key]
	get := b.get
	b.mu.Unlock()
	if get == nil {
		get = getGitHub
	}
	if found && (c.all || len(c.newest) >= want) {
		b.keep(key, c)
		return c, nil
	}
	read, err := readCompare(ctx, get, from, to, want)
	if err != nil {
		return agentsCompare{}, err
	}
	b.keep(key, read)
	return read, nil
}

func (b *agentsCompareBook) keep(key string, c agentsCompare) {
	c.asked = time.Now()
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.kept == nil {
		b.kept = map[string]agentsCompare{}
	}
	b.kept[key] = c
	for len(b.kept) > agentsComparesKept {
		oldest := ""
		for k, e := range b.kept {
			if oldest == "" || e.asked.Before(b.kept[oldest].asked) {
				oldest = k
			}
		}
		delete(b.kept, oldest)
	}
}

// githubCompare is the part of GitHub's compare answer that is read.
type githubCompare struct {
	AheadBy  int `json:"ahead_by"`
	BehindBy int `json:"behind_by"`
	Commits  []struct {
		SHA    string `json:"sha"`
		Commit struct {
			Message   string `json:"message"`
			Committer struct {
				Date time.Time `json:"date"`
			} `json:"committer"`
		} `json:"commit"`
	} `json:"commits"`
}

// readCompare asks GitHub for the compare's counts and then, oldest page first among those
// needed, the pages that hold its newest want commits. GitHub lists them oldest first.
func readCompare(ctx context.Context, get func(context.Context, string) ([]byte, error), from, to string, want int) (agentsCompare, error) {
	page := func(n, size int) (githubCompare, error) {
		address := fmt.Sprintf("%s/repos/%s/compare/%s...%s?per_page=%d&page=%d", agentsGitHub, agentsRepo,
			url.PathEscape(from), url.PathEscape(to), size, n)
		body, err := get(ctx, address)
		if err != nil {
			return githubCompare{}, err
		}
		var g githubCompare
		if err := json.Unmarshal(body, &g); err != nil {
			return githubCompare{}, fmt.Errorf("its answer could not be read: %w", err)
		}
		return g, nil
	}
	first, err := page(1, 1)
	if err != nil {
		return agentsCompare{}, err
	}
	c := agentsCompare{ahead: first.AheadBy, behind: first.BehindBy, newest: []wire.AgentsChange{}}
	read := min(want, c.ahead, mostAgentsChanges)
	if read == 0 {
		c.all = c.ahead == 0
		return c, nil
	}
	// The newest read commits are the indexes ahead-read … ahead-1, oldest first.
	firstPage := (c.ahead-read)/agentsChangesPage + 1
	lastPage := (c.ahead-1)/agentsChangesPage + 1
	var oldestFirst []wire.AgentsChange
	for n := firstPage; n <= lastPage; n++ {
		g, err := page(n, agentsChangesPage)
		if err != nil {
			return agentsCompare{}, err
		}
		for _, commit := range g.Commits {
			oldestFirst = append(oldestFirst, agentsChangeOf(commit.SHA, commit.Commit.Message, commit.Commit.Committer.Date))
		}
	}
	// Only the newest read of what the pages held.
	if len(oldestFirst) > read {
		oldestFirst = oldestFirst[len(oldestFirst)-read:]
	}
	for i := len(oldestFirst) - 1; i >= 0; i-- {
		c.newest = append(c.newest, oldestFirst[i])
	}
	c.all = len(c.newest) == c.ahead
	return c, nil
}

// squashedPR is the PR at the end of a squash commit's title: "Title (#5272) (#5418)" is #5418.
var squashedPR = regexp.MustCompile(`\s*\(#([0-9]+)\)$`)

// agentsChangeOf is a commit as a change: its title with its PR's number taken off the end.
func agentsChangeOf(sha, message string, date time.Time) wire.AgentsChange {
	title, _, _ := strings.Cut(message, "\n")
	title = strings.TrimSpace(title)
	change := wire.AgentsChange{Sha: sha}
	if m := squashedPR.FindStringSubmatch(title); m != nil {
		if n, err := strconv.ParseInt(m[1], 10, 64); err == nil {
			change.Number = &n
			title = strings.TrimSpace(title[:len(title)-len(m[0])])
		}
	}
	change.Title = title
	if !date.IsZero() {
		change.Date = optional(wire.DateOf(date))
	}
	return change
}

var agentsHTTP = &http.Client{Timeout: 15 * time.Second}

// getGitHub asks GitHub's API with no token: the repo is public.
func getGitHub(ctx context.Context, address string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "agent-loops-control-plane")
	response, err := agentsHTTP.Do(request)
	if err != nil {
		return nil, err
	}
	defer func() { _ = response.Body.Close() }()
	body, err := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	switch {
	case response.StatusCode == http.StatusNotFound:
		return nil, errors.New("GitHub does not know one of the commits")
	case response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests:
		return nil, errors.New("GitHub's limit for now is spent; try again later")
	case response.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("GitHub answered %d", response.StatusCode)
	}
	return body, nil
}

// machineAgents is machines/agents's answer: a machine page's Agents section, for the
// machine's own person (from).
func (m *Methods) machineAgents(ctx context.Context, host string, from Caller) (wire.MachineAgents, error) {
	s := m.s
	out := wire.MachineAgents{Host: wire.MachineRef(host), History: []wire.MachineAgentsVersion{},
		Others: []wire.MachineAgentsOther{}}
	versions, err := s.machineVersions(ctx, host)
	if err != nil {
		return out, err
	}
	out.Version, out.Since = versions.Version, versions.FirstSeen
	if versions.Previous != nil {
		out.Previous = versions.Previous
	}
	for _, d := range versions.Deploys {
		if d.Version.Name == nil {
			continue
		}
		out.History = append(out.History, wire.MachineAgentsVersion{Version: *d.Version.Name, Since: d.Finished})
	}
	if len(out.History) == 0 && out.Version != "" {
		out.History = append(out.History, wire.MachineAgentsVersion{Version: out.Version, Since: out.Since})
	}
	if out.Previous != nil && out.Version != "" {
		changes, err := s.agentsChanges(ctx, *out.Previous, out.Version, agentsChangesShown)
		if err != nil {
			out.ChangesError = optional(errorText(err))
		} else {
			out.Changes = &changes
		}
	}
	compared := 0
	for _, h := range m.records.Hosts() {
		if h.ID == host || !m.owns(from, h.ID) {
			continue
		}
		other := wire.MachineAgentsOther{Host: wire.MachineRef(h.ID), Name: h.Name, Version: h.Version}
		if other.Name == "" {
			other.Name = h.ID
		}
		if v, err := s.machineVersions(ctx, h.ID); err == nil && v.Version != "" {
			other.Version, other.Since = v.Version, v.FirstSeen
		}
		if other.Version != "" && out.Version != "" && compared < mostOthersCompared {
			compared++
			if other.Version == out.Version {
				zero := int64(0)
				other.Ahead, other.Behind = &zero, &zero
			} else if c, err := s.agentsChanges(ctx, out.Version, other.Version, -1); err == nil {
				other.Ahead, other.Behind = &c.Ahead, &c.Behind
			}
		}
		out.Others = append(out.Others, other)
	}
	return out, nil
}

// errorText is an error's words, a call's message when it is one.
func errorText(err error) string {
	var c *RPCError
	if errors.As(err, &c) {
		return c.Message
	}
	return err.Error()
}
