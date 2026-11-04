package agentsd

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The daily summary's one control (#3351): Off, Summary only or Summary and checks (#3395), the
// time, and how often the checks run, for all folders. It is kept in the home folder's
// ready-made Daily summary and Daily checks workflows themselves, so a hand edit and the control
// agree: the mode is their enabled:, the time the summary's schedule's at: and between:, and
// how often the checks' schedules, counted from the summary's time and never at it.

// summaryDefaultAt is the time the ready-made workflow runs at.
const summaryDefaultAt = "08:00"

// checksDefaultEvery is how many hours apart the ready-made Daily checks run.
const checksDefaultEvery = 4

// checksEveryChoices are the hours the checks can run apart: each divides the day evenly, so
// they run at the same hours every day.
var checksEveryChoices = []int64{2, 3, 4, 6, 8, 12}

// dailySummarySettings is dailySummary/settings.
func (d *Daemon) dailySummarySettings() wire.DailySummarySettings {
	every := int64(checksDefaultEvery)
	s := wire.DailySummarySettings{Mode: wire.DailySummaryModeOff, At: summaryDefaultAt, ChecksEvery: &every}
	home := d.personalHome()
	if home == "" {
		return s
	}
	summary, err := d.oneWorkflow(home, dailySummaryID)
	if err != nil {
		return s
	}
	checks, err := d.oneWorkflow(home, dailyChecksID)
	if err == nil {
		every = checksEveryOf(checks.Workflow)
	}
	if summary.IsEnabled {
		s.Mode = wire.DailySummaryModeSummary
		if err == nil && checks.IsEnabled {
			s.Mode = wire.DailySummaryModeSummaryAndChecks
		}
	}
	for _, t := range summary.Workflow.Triggers {
		if t.Schedule != nil {
			sc := t.Schedule.Value
			s.At = fmt.Sprintf("%02d:%02d", sc.Hours[0], sc.StartMinute)
			break
		}
	}
	return s
}

// checksEveryOf is how many hours apart a Daily checks workflow's schedules run: n schedules a
// day, and the summary's hour, are 24/(n+1) hours apart. A hand edit that is no choice reads as
// the default.
func checksEveryOf(w wire.Workflow) int64 {
	n := int64(0)
	for _, t := range w.Triggers {
		if t.Schedule != nil {
			n++
		}
	}
	if every := 24 / (n + 1); 24%(n+1) == 0 && slices.Contains(checksEveryChoices, every) {
		return every
	}
	return checksDefaultEvery
}

// checksSchedules is the Daily checks workflow's on: block: every few hours from the summary's
// time, and never at it, so a check and the summary do not run together.
func checksSchedules(h, m, every int64) []string {
	var hours []int64
	for k := int64(1); k*every < 24; k++ {
		hours = append(hours, (h+k*every)%24)
	}
	slices.Sort(hours)
	block := []string{"on:"}
	for _, x := range hours {
		at := fmt.Sprintf("%02d:%02d", x, m)
		block = append(block, "  - schedule:", "      at: "+doubleQuoted(fmt.Sprintf(":%02d", m)), "      between: "+doubleQuoted(at+"-"+at))
	}
	return block
}

// setDailySummarySettings is dailySummary/setSettings: the times first, then on or off.
func (d *Daemon) setDailySummarySettings(r wire.DailySummarySettings) (wire.DailySummarySettings, error) {
	h, m, ok := clockTime(r.At)
	if !ok || !strings.Contains(r.At, ":") {
		return wire.DailySummarySettings{}, Invalid("%q is not a time the daily summary can run at: say HH:MM, on the hour or the half hour", r.At)
	}
	if r.Mode != wire.DailySummaryModeOff && r.Mode != wire.DailySummaryModeSummary && r.Mode != wire.DailySummaryModeSummaryAndChecks {
		return wire.DailySummarySettings{}, Invalid("%q is not a daily summary mode", r.Mode)
	}
	every := int64(checksDefaultEvery)
	if r.ChecksEvery != nil {
		every = *r.ChecksEvery
	}
	if !slices.Contains(checksEveryChoices, every) {
		return wire.DailySummarySettings{}, Invalid("the checks cannot run every %d hours: say 2, 3, 4, 6, 8 or 12", every)
	}
	withChecks := r.Mode == wire.DailySummaryModeSummaryAndChecks
	home := d.personalHome()
	if home == "" {
		return wire.DailySummarySettings{}, &Error{Code: wire.FailureNotAllowed, Message: "This machine has no home folder for the Daily summary workflow."}
	}
	at := fmt.Sprintf("%02d:%02d", h, m)
	d.workflowMu.Lock()
	d.scanLocked()
	err := d.editWorkflowLocked(home, dailySummaryID, true, func(text string) (string, error) {
		text, err := setScheduleLine("at", fmt.Sprintf(":%02d", m), text)
		if err != nil {
			return "", err
		}
		return setScheduleLine("between", at+"-"+at, text)
	})
	if err == nil && withChecks {
		err = d.editWorkflowLocked(home, dailyChecksID, true, func(text string) (string, error) {
			return setFrontMatterBlock("on", checksSchedules(h, m, every), text)
		})
	}
	d.workflowMu.Unlock()
	if err != nil {
		return wire.DailySummarySettings{}, err
	}
	if _, err := d.enableWorkflow(wire.WorkflowEnableRequest{Folder: store.FolderURL(home), WorkflowID: dailySummaryID, Enabled: r.Mode != wire.DailySummaryModeOff}, "person"); err != nil {
		return wire.DailySummarySettings{}, err
	}
	// The checks report through the summary (#3355): only Summary and checks has them on.
	if checks, err := d.oneWorkflow(home, dailyChecksID); err == nil && checks.IsEnabled != withChecks {
		if _, err := d.enableWorkflow(wire.WorkflowEnableRequest{Folder: store.FolderURL(home), WorkflowID: dailyChecksID, Enabled: withChecks}, "person"); err != nil {
			return wire.DailySummarySettings{}, err
		}
	}
	return d.dailySummarySettings(), nil
}

// setFrontMatterBlock puts block in place of a workflow metadata's key: and the lines under it,
// such as the whole on: list. It refuses when there is not exactly one, as setScheduleLine does.
func setFrontMatterBlock(key string, block []string, source string) (string, error) {
	lines, nl, closing, err := splitSource(source)
	if err != nil {
		return "", err
	}
	found := -1
	for i := 1; i < closing; i++ {
		if isKeyLine(lines[i], key) {
			if found >= 0 {
				return "", refuse("`" + key + ":` appears more than once in the metadata — which one is meant is not something to pick between silently")
			}
			found = i
		}
	}
	if found < 0 {
		return "", refuse("the metadata has no `" + key + ":`")
	}
	end := found + 1
	for end < closing && isContinuation(lines[end]) {
		end++
	}
	out := append(append(append([]string{}, lines[:found]...), block...), lines[end:]...)
	return strings.Join(out, nl), nil
}

// setScheduleLine sets the one key: line, such as a schedule's at: or between:, in a
// workflow's metadata. It refuses when there is not exactly one, as setFrontMatter does.
func setScheduleLine(key, value, source string) (string, error) {
	lines, nl, closing, err := splitSource(source)
	if err != nil {
		return "", err
	}
	found := -1
	for i := 1; i < closing; i++ {
		t := strings.TrimLeft(strings.TrimPrefix(strings.TrimSpace(lines[i]), "- "), " ")
		if strings.HasPrefix(t, key+":") {
			if found >= 0 {
				return "", refuse("`" + key + ":` appears more than once in the metadata — which one is meant is not something to pick between silently")
			}
			found = i
		}
	}
	if found < 0 {
		return "", refuse("the schedule has no `" + key + ":`")
	}
	line := lines[found]
	start := strings.Index(line, key+":") + len(key) + 1
	lines[found] = line[:start] + " " + doubleQuoted(value)
	return strings.Join(lines, nl), nil
}

func (d *Daemon) registerDailySummary() {
	On(d, wire.CallDailySummarySettings, func(ctx context.Context, c *Client, _ wire.Empty) (wire.DailySummarySettings, error) {
		return d.dailySummarySettings(), nil
	})
	On(d, wire.CallDailySummarySetSettings, func(ctx context.Context, c *Client, r wire.DailySummarySettings) (wire.DailySummarySettings, error) {
		return d.setDailySummarySettings(r)
	})
	// The daily summary another of the person's machines writes (#3354), from the control plane.
	On(d, wire.CallAgentsSummaryFacts, func(ctx context.Context, c *Client, r wire.SummaryFactsRequest) (wire.SummaryFacts, error) {
		since := r.Since.Time()
		if reach := time.Now().Add(-summaryReach); since.Before(reach) {
			since = reach
		}
		return sentSummaryFacts(d.machineSummaryFacts("", since)), nil
	})
}
