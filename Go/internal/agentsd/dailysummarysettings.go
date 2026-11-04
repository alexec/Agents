package agentsd

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The daily summary's one control (#3351): Off or Summary, and the time, for all folders. It
// is kept in the home folder's ready-made Daily summary workflow itself, so a hand edit and the
// control agree: the mode is the workflow's enabled:, the time its schedule's at: and between:.

// summaryDefaultAt is the time the ready-made workflow runs at.
const summaryDefaultAt = "08:00"

// dailySummarySettings is dailySummary/settings.
func (d *Daemon) dailySummarySettings() wire.DailySummarySettings {
	s := wire.DailySummarySettings{Mode: wire.DailySummaryModeOff, At: summaryDefaultAt}
	home := d.personalHome()
	if home == "" {
		return s
	}
	summary, err := d.oneWorkflow(home, dailySummaryID)
	if err != nil {
		return s
	}
	if summary.IsEnabled {
		s.Mode = wire.DailySummaryModeSummary
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

// setDailySummarySettings is dailySummary/setSettings: the time first, then on or off.
func (d *Daemon) setDailySummarySettings(r wire.DailySummarySettings) (wire.DailySummarySettings, error) {
	h, m, ok := clockTime(r.At)
	if !ok || !strings.Contains(r.At, ":") {
		return wire.DailySummarySettings{}, Invalid("%q is not a time the daily summary can run at: say HH:MM, on the hour or the half hour", r.At)
	}
	if r.Mode != wire.DailySummaryModeOff && r.Mode != wire.DailySummaryModeSummary {
		return wire.DailySummarySettings{}, Invalid("%q is not a daily summary mode", r.Mode)
	}
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
	d.workflowMu.Unlock()
	if err != nil {
		return wire.DailySummarySettings{}, err
	}
	if _, err := d.enableWorkflow(wire.WorkflowEnableRequest{Folder: store.FolderURL(home), WorkflowID: dailySummaryID, Enabled: r.Mode == wire.DailySummaryModeSummary}, "person"); err != nil {
		return wire.DailySummarySettings{}, err
	}
	// The checks report through the summary (#3355): Off turns them off too. Summary leaves
	// them as the Daily checks workflow says, until the control has Summary and checks.
	if r.Mode == wire.DailySummaryModeOff {
		if checks, err := d.oneWorkflow(home, dailyChecksID); err == nil && checks.IsEnabled {
			if _, err := d.enableWorkflow(wire.WorkflowEnableRequest{Folder: store.FolderURL(home), WorkflowID: dailyChecksID, Enabled: false}, "person"); err != nil {
				return wire.DailySummarySettings{}, err
			}
		}
	}
	return d.dailySummarySettings(), nil
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
