package agentsd

import (
	"context"
	"io"
	"net/url"
	"os"
	"regexp"
	goruntime "runtime"
	"strings"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/redact"
	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/wire"
)

// Report a Problem (#3718): the person's words and this machine's facts, made into a
// GitHub new-issue link the client opens, so the issue is posted from the person's own
// account and no server of ours sees it. One place cuts the tokens and the home folders,
// for every client.

// problemRepo is where a problem report goes.
const problemRepo = "https://github.com/agentloops-dev/Agents/issues/new"

const (
	// problemLogLines is how many of daemon.log's last lines a report may add.
	problemLogLines = 40
	// problemLogTail is how much of daemon.log's end is read for them.
	problemLogTail = 16 << 10
	// problemURLMost is the longest link a report makes: GitHub refuses a much longer one.
	problemURLMost = 7500
)

// homes is a home folder on a Mac or on Linux; the first group stays, the name goes.
var homes = regexp.MustCompile(`(^|[^A-Za-z0-9_.-])(?:/Users|/home)/[^/\s"'\x60:]+`)

func (d *Daemon) registerProblemReport() {
	On(d, wire.CallReportsProblem, func(ctx context.Context, c *Client, r wire.ProblemReportRequest) (wire.ProblemReport, error) {
		var log []string
		if r.WithLog && d.Store != nil {
			log = lastLogLines(d.Store.Loc.Log(), problemLogLines)
		}
		return problemReport(r, log, d.PersonalHome), nil
	})
}

// problemReport is r as an issue, with log as its recent log lines.
func problemReport(r wire.ProblemReportRequest, log []string, home string) wire.ProblemReport {
	clean := func(s string) string { return cutHomes(redact.Text(s), home) }
	title := clean(problemTitle(r.Happened))
	runtime := "none"
	if r.Runtime != nil && strings.TrimSpace(*r.Runtime) != "" {
		runtime = strings.TrimSpace(*r.Runtime)
	}
	for i := range log {
		log[i] = clean(log[i])
	}
	body := func(log []string) string {
		var b strings.Builder
		b.WriteString("## What happened\n\n")
		b.WriteString(orNone(clean(r.Happened)))
		b.WriteString("\n\n## What I expected\n\n")
		b.WriteString(orNone(clean(r.Expected)))
		b.WriteString("\n\n## About this\n\n")
		b.WriteString("- Client: " + clean(r.Client) + " on " + clean(r.ClientOS) + "\n")
		b.WriteString("- Agents Host: " + buildinfo.String() + " on " + goruntime.GOOS + "/" + goruntime.GOARCH + "\n")
		b.WriteString("- Runtime: " + clean(runtime) + "\n")
		if len(log) > 0 {
			b.WriteString("\n<details><summary>Recent log lines</summary>\n\n```\n")
			b.WriteString(strings.Join(log, "\n"))
			b.WriteString("\n```\n\n</details>\n")
		}
		return b.String()
	}
	full := body(log)
	link := problemLink(title, full)
	// Too long for a link: the oldest lines go first, then the end of the body.
	for kept := log; len(link) > problemURLMost && len(kept) > 0; {
		kept = kept[1:]
		link = problemLink(title, body(kept))
	}
	if len(link) > problemURLMost {
		short := body(nil)
		for len(link) > problemURLMost && len(short) > 0 {
			short = trimRunes(short, len(short)*9/10)
			link = problemLink(title, short+"\n\n…")
		}
	}
	return wire.ProblemReport{Title: title, Body: full, URL: link}
}

func problemLink(title, body string) string {
	q := url.Values{"title": {title}, "body": {body}, "labels": {"bug"}}
	return problemRepo + "?" + q.Encode()
}

// problemTitle is the first line of what happened, at most 80 characters.
func problemTitle(happened string) string {
	line, _, _ := strings.Cut(strings.TrimSpace(happened), "\n")
	line = strings.TrimSpace(line)
	if line == "" {
		return "A problem in Agents"
	}
	if utf8.RuneCountInString(line) > 80 {
		return string([]rune(line)[:79]) + "…"
	}
	return line
}

func orNone(s string) string {
	if strings.TrimSpace(s) == "" {
		return "_Not given._"
	}
	return strings.TrimSpace(s)
}

// cutHomes puts ~ in place of home, and of any other home folder on a Mac or on Linux.
func cutHomes(s, home string) string {
	for _, h := range []string{home, userHome()} {
		if len(h) > 1 {
			s = strings.ReplaceAll(s, strings.TrimSuffix(h, "/"), "~")
		}
	}
	return homes.ReplaceAllString(s, "$1~")
}

func userHome() string {
	h, _ := os.UserHomeDir()
	return h
}

// trimRunes is s cut to at most n bytes, at a character's start.
func trimRunes(s string, n int) string {
	if n >= len(s) {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n]
}

// lastLogLines is the last n lines of the log at path, or none when it cannot be read.
func lastLogLines(path string, n int) []string {
	f, err := os.Open(path)
	if err != nil {
		return nil
	}
	defer f.Close()
	if info, err := f.Stat(); err == nil && info.Size() > problemLogTail {
		if _, err := f.Seek(-problemLogTail, io.SeekEnd); err != nil {
			return nil
		}
	}
	b, err := io.ReadAll(io.LimitReader(f, problemLogTail))
	if err != nil {
		return nil
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	if len(b) == problemLogTail && len(lines) > 1 {
		// The first line was cut in the middle.
		lines = lines[1:]
	}
	if len(lines) > n {
		lines = lines[len(lines)-n:]
	}
	if len(lines) == 1 && lines[0] == "" {
		return nil
	}
	return lines
}
