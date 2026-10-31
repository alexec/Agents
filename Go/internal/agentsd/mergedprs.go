package agentsd

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// The pull requests merged from the branches the app makes (#985, #1987), for the Time
// page's recap and records and the firstLandedPR milestone, as DaemonCore+MergedPRs did.
// Asked of the person's own gh once an hour, in each folder that is a git repository; a
// folder whose remote is not GitHub, or a machine with no gh, says nothing, and the page
// shows a dash.

const (
	mergedPRsInterval = time.Hour
	// How many days an hourly ask goes back: a pull request merged on a day the machine
	// was asleep is still counted on its own day.
	mergedPRsDaysAsked = 7
)

// mergedPRsDelay is how long after the start the first ask is, when the folders are known.
var mergedPRsDelay = time.Minute

// findGH is the person's gh, or "" when it is not installed. Only TestMain sets it, before
// any daemon starts: a test hands its fake gh to countMergedPRsWith instead (#2806).
var findGH = func() string {
	for _, dir := range searchPaths() {
		p := filepath.Join(dir, "gh")
		if info, err := os.Stat(p); err == nil && info.Mode()&0o111 != 0 {
			return p
		}
	}
	return ""
}

// mergedPull is one pull request gh pr list --state merged named.
type mergedPull struct {
	URL         string    `json:"url"`
	MergedAt    time.Time `json:"mergedAt"`
	HeadRefName string    `json:"headRefName"`
}

// countMergedPRsEveryHour asks a minute after the start, then every hour, and looks for a
// running cloud machine each time too.
func (d *Daemon) countMergedPRsEveryHour() {
	safe.Go("merged pull requests", func() {
		wait := time.NewTimer(mergedPRsDelay)
		defer wait.Stop()
		for {
			select {
			case <-d.ctx.Done():
				return
			case <-wait.C:
			}
			d.checkCloudHosts()
			d.countMergedPRs()
			d.checkMilestonesSoon()
			wait.Reset(mergedPRsInterval)
		}
	})
}

// countMergedPRs asks every folder's gh, when the person has one.
func (d *Daemon) countMergedPRs() {
	if gh := findGH(); gh != "" {
		d.countMergedPRsWith(gh)
	}
}

// countMergedPRsWith asks every folder's gh, and writes what they said for the days asked
// about. The first answer goes back as far as the Time page keeps days.
func (d *Daemon) countMergedPRsWith(gh string) {
	d.timeMu.Lock()
	days := usageDaysKept
	for _, r := range d.timeLocked().Recap {
		if r.PrsMerged != nil {
			days = mergedPRsDaysAsked
			break
		}
	}
	d.timeMu.Unlock()
	today := time.Now()
	stamps := make([]string, days)
	for i := range stamps {
		stamps[i] = dayStamp(today.AddDate(0, 0, -i))
	}
	folders := d.folderPaths()
	sort.Strings(folders)
	var pulls []mergedPull
	answered := false
	for _, f := range folders {
		if _, err := os.Stat(filepath.Join(f, ".git")); err != nil {
			continue
		}
		found, err := mergedPullRequests(d.ctx, gh, f, stamps[len(stamps)-1])
		if err != nil {
			continue
		}
		pulls = append(pulls, found...)
		answered = true
	}
	if !answered {
		return
	}
	d.setPRsMerged(mergedByDay(pulls), stamps)
}

// mergedPullRequests is the pull requests of the repository folder is in that merged on
// or after day (yyyy-MM-dd), at most 1,000 of them.
func mergedPullRequests(ctx context.Context, gh, folder, day string) ([]mergedPull, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, gh, "pr", "list", "--state", "merged", "--search", "merged:>="+day,
		"--json", "url,mergedAt,headRefName", "--limit", "1000")
	cmd.Dir = folder
	cmd.Env = append(os.Environ(), "GH_PROMPT_DISABLED=1", "GH_NO_UPDATE_NOTIFIER=1", "NO_COLOR=1")
	var out, errs bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errs
	if err := cmd.Run(); err != nil {
		if line, _, _ := strings.Cut(strings.TrimSpace(errs.String()), "\n"); line != "" {
			return nil, errors.New(line)
		}
		return nil, err
	}
	var pulls []mergedPull
	if err := json.Unmarshal(out.Bytes(), &pulls); err != nil {
		return nil, err
	}
	return pulls, nil
}

// mergedByDay is how many of pulls came from the app's branches, by the day each merged
// here. The same pull request named by two checkouts of one repository counts once.
func mergedByDay(pulls []mergedPull) map[string]int64 {
	seen := map[string]bool{}
	counts := map[string]int64{}
	for _, p := range pulls {
		if !strings.HasPrefix(p.HeadRefName, branchPrefix) || seen[p.URL] {
			continue
		}
		seen[p.URL] = true
		counts[dayStamp(p.MergedAt)]++
	}
	return counts
}

// setPRsMerged is what gh said about the pull requests merged on each of days. A day it
// named none of is a day with none.
func (d *Daemon) setPRsMerged(counts map[string]int64, days []string) {
	d.timeMu.Lock()
	defer d.timeMu.Unlock()
	h := d.timeLocked()
	for _, day := range days {
		n := counts[day]
		changeRecap(h, day, func(r *wire.DayRecap) { r.PrsMerged = &n })
	}
	pruneTime(h)
	if err := writeStore(d.timePath(), h); err != nil {
		log.Printf("time-history.json: could not save: %v", err)
	}
}
