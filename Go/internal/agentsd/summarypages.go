package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The Summary row and page (#3721): the clients read the saved pages of the daily summary
// through the host (summaries/list, summaries/read), as the Remote and the web are not on the
// machine that saved them. Which page is unread, and which session wrote it, is kept beside
// the pages in pages.json.

// summaryPageMark is one page's line in pages.json.
type summaryPageMark struct {
	Writer *wire.UUID `json:"writer,omitempty"`
	Unread bool       `json:"unread,omitempty"`
}

// summaryPagesMu keeps one read-modify-write of pages.json at a time.
var summaryPagesMu sync.Mutex

func summaryMarksFile(home string) string { return filepath.Join(summariesDir(home), "pages.json") }

func readSummaryMarks(home string) map[string]summaryPageMark {
	marks := map[string]summaryPageMark{}
	if b, err := os.ReadFile(summaryMarksFile(home)); err == nil {
		_ = json.Unmarshal(b, &marks)
	}
	return marks
}

// writeSummaryMarks keeps the marks of the pages still on disk only.
func writeSummaryMarks(home string, marks map[string]summaryPageMark) error {
	kept := map[string]summaryPageMark{}
	for _, f := range summaryFiles(home) {
		name := summaryName(f)
		if m, ok := marks[name]; ok {
			kept[name] = m
		}
	}
	b, err := json.Marshal(kept)
	if err != nil {
		return err
	}
	return store.WriteAtomically(summaryMarksFile(home), b, 0o600)
}

func summaryName(file string) string { return strings.TrimSuffix(filepath.Base(file), ".md") }

// summaryPages is summaries/list: the saved pages, newest first. A page with no mark (saved
// before #3721) is read and has no writer.
func (d *Daemon) summaryPages() []wire.SummaryPage {
	out := []wire.SummaryPage{}
	home := d.personalHome()
	if home == "" {
		return out
	}
	summaryPagesMu.Lock()
	marks := readSummaryMarks(home)
	summaryPagesMu.Unlock()
	for _, f := range summaryFiles(home) {
		out = append(out, summaryPageOf(f, marks))
	}
	return out
}

func summaryPageOf(file string, marks map[string]summaryPageMark) wire.SummaryPage {
	name := summaryName(file)
	page := wire.SummaryPage{Name: name, Title: name, Unread: marks[name].Unread, Writer: marks[name].Writer}
	if at, err := time.ParseInLocation("2006-01-02-1504", name, time.Local); err == nil {
		page.SavedAt = wire.DateOf(at)
	} else if st, err := os.Stat(file); err == nil {
		page.SavedAt = wire.DateOf(st.ModTime())
	}
	if b, err := os.ReadFile(file); err == nil {
		if title := summaryTitle(string(b)); title != "" {
			page.Title = title
		}
	}
	return page
}

// readSummaryPage is summaries/read. Reading the newest page marks it read, and its writer's
// session too, so neither waits on the person any more.
func (d *Daemon) readSummaryPage(name string) (wire.SummaryPageText, error) {
	home := d.personalHome()
	files := summaryFiles(home)
	i := -1
	for j, f := range files {
		if summaryName(f) == name {
			i = j
		}
	}
	if home == "" || i < 0 {
		return wire.SummaryPageText{}, Invalid("There is no daily summary %q on this machine: it may be older than the last %d.", name, summariesKept)
	}
	b, err := os.ReadFile(files[i])
	if err != nil {
		return wire.SummaryPageText{}, &Error{Message: "The summary could not be read: " + err.Error()}
	}
	summaryPagesMu.Lock()
	marks := readSummaryMarks(home)
	m := marks[name]
	read := i == 0 && m.Unread
	if read {
		m.Unread = false
		marks[name] = m
		_ = writeSummaryMarks(home, marks)
	}
	summaryPagesMu.Unlock()
	if read {
		if m.Writer != nil {
			d.markRead(*m.Writer)
		}
		Broadcast(d, wire.NotifySummariesChanged, d.summaryPages())
	}
	return wire.SummaryPageText{Page: summaryPageOf(files[i], marks), Markdown: string(b)}, nil
}

// markSummarySaved is a new page's mark: unread, by its writer; the older pages are read, so
// only the newest has the Summary row's dot.
func (d *Daemon) markSummarySaved(home, path string, writer wire.UUID) {
	summaryPagesMu.Lock()
	marks := readSummaryMarks(home)
	for name, m := range marks {
		m.Unread = false
		marks[name] = m
	}
	marks[summaryName(path)] = summaryPageMark{Writer: &writer, Unread: true}
	_ = writeSummaryMarks(home, marks)
	summaryPagesMu.Unlock()
	Broadcast(d, wire.NotifySummariesChanged, d.summaryPages())
}

func (d *Daemon) registerSummaryPages() {
	On(d, wire.CallSummariesList, func(ctx context.Context, c *Client, _ wire.Empty) ([]wire.SummaryPage, error) {
		return d.summaryPages(), nil
	})
	On(d, wire.CallSummariesRead, func(ctx context.Context, c *Client, r wire.SummaryReadRequest) (wire.SummaryPageText, error) {
		return d.readSummaryPage(r.Name)
	})
}
