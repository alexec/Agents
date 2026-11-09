package agentsd

import (
	"cmp"
	"context"
	_ "embed"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/alexec/agents/Go/internal/browser"
	"github.com/alexec/agents/Go/wire"
)

// The browser tools (#3534, spike #3527): the `agents` server offers Playwright's tools
// (browser_navigate, browser_snapshot, browser_click and the rest) under their own names,
// and passes each call to an @playwright/mcp that agentsd starts for the session, pointed
// at the machine's browser with --cdp-endpoint. agentsd stays in the path for three
// things: the first call takes the lease browser:agents, so one agent at a time drives the
// browser; every result goes through the machine's browser.Filter (text and images) before
// the agent gets it, and calls that could read a filled secret past it are refused
// (browserfill.go, #3530); and while the person has the page (hand_to_person, handoff.go,
// #3529), the agent's calls are held off.
//
// The tools are listed from browsertools.json, which scripts/browser-tools.sh writes from
// the pinned @playwright/mcp, so a session sees them before Node or Chromium is on the
// machine. The first call installs both (browser.Machine.Endpoint).

//go:embed browsertools.json
var browserToolsFile []byte

// browserArgs is how agentsd starts @playwright/mcp, after its cli.js: the machine's
// browser; its output out of the person's folder, named by whole paths so that
// outputLinks finds them; and no tools that a page registers (WebMCP), so the list stays
// the one in browsertools.json. scripts/browser-tools.sh lists the tools with the same flags.
func browserArgs(endpoint, output string) []string {
	return []string{"--cdp-endpoint", endpoint, "--output-dir", output, "--file-paths", "absolute", "--no-webmcp"}
}

// browserNavigateNote is added to browser_navigate's description, so an agent picks the
// app's browser for a page a person may need to see over a browser of its own.
const browserNavigateNote = " This is the app's browser on this machine: it keeps the sign-ins that agents here share, " +
	"and the person can see its pages. Use it for any page a person may need to see or act on."

// browserCallLongest is the most one browser call may take: Playwright's own navigation
// timeout is a minute, and the first call also installs Node and Chromium.
var browserCallLongest = 15 * time.Minute

type browserToolList struct {
	Package string            `json:"package"`
	Version string            `json:"version"`
	Tools   []json.RawMessage `json:"tools"`
}

// browserTools is the list as tools/list sends it, and each tool's name.
var browserTools = sync.OnceValues(func() ([]json.RawMessage, map[string]bool) {
	var list browserToolList
	if err := json.Unmarshal(browserToolsFile, &list); err != nil {
		log.Printf("browser tools: %v", err)
		return nil, nil
	}
	names := map[string]bool{}
	out := make([]json.RawMessage, 0, len(list.Tools))
	for _, raw := range list.Tools {
		var t map[string]json.RawMessage
		if json.Unmarshal(raw, &t) != nil {
			continue
		}
		var name, description string
		json.Unmarshal(t["name"], &name)
		json.Unmarshal(t["description"], &description)
		if name == "" {
			continue
		}
		if name == "browser_navigate" {
			t["description"], _ = json.Marshal(description + browserNavigateNote)
		}
		names[name] = true
		b, _ := json.Marshal(t)
		out = append(out, b)
	}
	// The app's own fill (#3530), listed and called with Playwright's tools.
	names[fillSecretName] = true
	out = append(out, fillSecretTool)
	// The app's own password maker (#4000), the same.
	names[generateSecretName] = true
	out = append(out, generateSecretTool)
	// The app's own capture of a shown value (#4028), the same.
	names[captureSecretName] = true
	out = append(out, captureSecretTool)
	// The app's own device profile (#4086), the same.
	names[emulateDeviceName] = true
	out = append(out, emulateDeviceTool)
	// The hand-off to the person (#3529), the same.
	names[handToPersonName] = true
	out = append(out, handToPersonTool)
	return out, names
})

// browserToolNamed is the browser tool a call names, matched by the end of the name as the
// app's own tools are: a runtime may put its own prefix on it.
func browserToolNamed(called string) (string, bool) {
	_, names := browserTools()
	best := ""
	for n := range names {
		if strings.HasSuffix(called, n) && len(n) > len(best) {
			best = n
		}
	}
	return best, best != ""
}

// offersBrowser is whether this host lists the browser tools: it has the machine's browser
// and somewhere to install it.
func (d *Daemon) offersBrowser() bool { return d.browser != nil && toolsHome != "" }

// browserSession is one @playwright/mcp, connected: a test gives its own.
type browserSession interface {
	callTool(ctx context.Context, name string, args map[string]json.RawMessage) (*mcp.CallToolResult, error)
	close()
}

// browserStart is what a session's @playwright/mcp starts with.
type browserStart struct {
	toolset  browser.Toolset
	endpoint string
	cwd      string
	output   string
	env      []string
}

// browserEndpoint is the machine's browser's address, after it installs and starts it when
// it must. A var so a test can give an address with no Chromium behind it.
var browserEndpoint = func(m *browser.Machine) (string, error) {
	return m.Endpoint(func(step string) { log.Printf("browser: %s", step) })
}

// openBrowserSession starts @playwright/mcp and connects to it over stdio. A var so a test
// can give a session of its own.
var openBrowserSession = func(ctx context.Context, s browserStart) (browserSession, error) {
	cmd := exec.Command(s.toolset.Node, append([]string{s.toolset.MCP()}, browserArgs(s.endpoint, s.output)...)...)
	// It runs in the agent's folder: with no roots from its client, that is where the files
	// it uploads, and the screenshots given a name, are.
	cmd.Dir, cmd.Env, cmd.Stderr = s.cwd, s.env, os.Stderr
	client := mcp.NewClient(&mcp.Implementation{Name: "agentsd", Version: "1.0.0"}, nil)
	cs, err := client.Connect(ctx, &mcp.CommandTransport{Command: cmd, TerminateDuration: 2 * time.Second}, nil)
	if err != nil {
		return nil, err
	}
	return playwrightSession{cs}, nil
}

type playwrightSession struct{ cs *mcp.ClientSession }

func (p playwrightSession) callTool(ctx context.Context, name string, args map[string]json.RawMessage) (*mcp.CallToolResult, error) {
	return p.cs.CallTool(ctx, &mcp.CallToolParams{Name: name, Arguments: args})
}

func (p playwrightSession) close() { p.cs.Close() }

// browserDrive is one agent's @playwright/mcp, and the browser address it was started on.
type browserDrive struct {
	mu       sync.Mutex // one call at a time: one page, one pointer
	session  browserSession
	endpoint string
	output   string
}

// browserDriveState is the Daemon's @playwright/mcp processes, one per agent that drives
// the browser this turn. Under browserMu.
type browserDriveState struct {
	browserMu     sync.Mutex
	browserDrives map[wire.UUID]*browserDrive
}

var browserLeaseName = map[string]json.RawMessage{"name": json.RawMessage(`"` + browser.Resource + `"`)}

// holdsBrowser is whether this agent holds browser:agents now.
func (d *Daemon) holdsBrowser(agent wire.UUID) bool {
	d.leaseMu.Lock()
	defer d.leaseMu.Unlock()
	d.loadLeases()
	e := d.book.Entries[wire.ResourceName(browser.Resource)]
	return e != nil && holderIndex(e, agent) >= 0
}

// callBrowserTool is one browser tool's call: the lease, the agent's @playwright/mcp, the
// call, and the filter on what comes back. It answers as tools/call does.
func (d *Daemon) callBrowserTool(ctx context.Context, agent wire.UUID, name string, args map[string]json.RawMessage) map[string]any {
	began := time.Now()
	content, isError, note := d.driveBrowser(ctx, agent, name, args)
	var err error
	if isError {
		err = errors.New(note)
	}
	d.keepAppToolCall(agent, name, args, note, err, began)
	d.countAppTool(agent, name)
	return map[string]any{"content": content, "isError": isError}
}

// driveBrowser does the call, and says what the agent gets, whether it failed, and its text
// in one line for the record.
func (d *Daemon) driveBrowser(ctx context.Context, agent wire.UUID, name string, args map[string]json.RawMessage) ([]any, bool, string) {
	failed := func(msg string) ([]any, bool, string) {
		return []any{map[string]any{"type": "text", "text": msg}}, true, msg
	}
	a := d.Store.Agent(agent)
	if a == nil {
		return failed(leaseNoCall)
	}
	if !d.offersBrowser() {
		return failed("The browser can't be installed on " + thisMachine() + ".")
	}
	if name == handToPersonName && d.isBot() {
		return failed(noOneAnswersWords)
	}
	if h := d.handOffOpen(agent); h != nil {
		return failed(handOffHolds(h))
	}
	var fill secretFill
	if name == fillSecretName {
		var refusal string
		if fill, refusal = d.fillSecretValue(agent, args); refusal != "" {
			return failed(refusal)
		}
	}
	if name == generateSecretName {
		if refusal := d.generateSecretCheck(args); refusal != "" {
			return failed(refusal)
		}
	}
	if name == captureSecretName {
		if refusal := d.captureSecretCheck(args); refusal != "" {
			return failed(refusal)
		}
	}
	var device *browser.Device
	if name == emulateDeviceName {
		var refusal string
		if device, refusal = emulateDeviceCheck(args); refusal != "" {
			return failed(refusal)
		}
	}
	reply, err := d.leaseResource(agent, browserLeaseName)
	if err != nil {
		return failed(browserWords(err))
	}
	if !d.holdsBrowser(agent) {
		// In line behind another agent: told its place, started again on lease.granted.
		return []any{map[string]any{"type": "text", "text": reply}}, false, reply
	}
	// The tabs that open from here on are this agent's (#3916); the first call of its turn
	// opens its session's Agent Browser pane on the clients.
	if d.driveBrowserAs(agent) {
		d.markBrowserUsed(agent)
	}
	// Its tab is the chat's live tile while it drives, and for liveDriveWindow after (#4139).
	d.browserDrove(agent)
	defer d.browserDrove(agent)
	if name == handToPersonName {
		// The person drives: no Playwright is needed for it.
		said, isError := d.handToPerson(agent, args)
		return []any{map[string]any{"type": "text", "text": said}}, isError, said
	}
	ctx, cancel := context.WithTimeout(ctx, browserCallLongest)
	defer cancel()
	drive, err := d.browserDriveFor(ctx, agent, folderPath(a))
	if err != nil {
		return failed("The browser did not start: " + browserWords(err))
	}
	if name == fillSecretName {
		words, isError, site := d.approveFill(ctx, agent, drive, fill, args)
		if words != "" {
			return []any{map[string]any{"type": "text", "text": words}}, isError, words
		}
		if fill.released {
			// Approved: the value is in agentsd's memory now (#4058).
			var refusal string
			if fill, refusal = d.fillSecretValue(agent, args); refusal != "" || fill.released {
				return failed(cmp.Or(refusal, "Nothing was filled: "+fill.name+" did not open."))
			}
		}
		fill.agent, fill.site = agent, site
		return d.fillSecret(ctx, drive, fill, args)
	}
	if name == generateSecretName {
		return d.generateSecret(ctx, drive, args)
	}
	if name == captureSecretName {
		return d.captureSecret(ctx, drive, args)
	}
	if name == emulateDeviceName {
		said, isError := d.emulateDevice(agent, device)
		return []any{map[string]any{"type": "text", "text": said}}, isError, said
	}
	if refusal := d.browserRefusal(ctx, drive, name, args); refusal != "" {
		return failed(refusal)
	}
	res, err := drive.call(ctx, name, args)
	if err != nil {
		// A Playwright that died takes nothing else with it: the next call starts another.
		d.endBrowserSession(agent)
		return failed(fmt.Sprintf("%s failed: %v", name, err))
	}
	content, text := d.filterBrowserResult(res, drive.output)
	return content, res.IsError, text
}

// browserDriveFor is this agent's @playwright/mcp on the browser as it runs now: started
// on first use, and started again when Chromium was (its address changed). The browser
// itself installs and starts here when it must, and each call counts as its use.
func (d *Daemon) browserDriveFor(ctx context.Context, agent wire.UUID, cwd string) (*browserDrive, error) {
	d.browserMu.Lock()
	if d.browserDrives == nil {
		d.browserDrives = map[wire.UUID]*browserDrive{}
	}
	drive := d.browserDrives[agent]
	if drive == nil {
		drive = &browserDrive{output: filepath.Join(d.Store.Loc.Cache, "browser", "output", string(agent))}
		d.browserDrives[agent] = drive
	}
	d.browserMu.Unlock()
	drive.mu.Lock()
	defer drive.mu.Unlock()
	endpoint, err := browserEndpoint(d.browser)
	if err != nil {
		return nil, err
	}
	if drive.session != nil && drive.endpoint == endpoint {
		return drive, nil
	}
	if drive.session != nil {
		drive.session.close()
		drive.session = nil
	}
	if err := os.MkdirAll(drive.output, 0o700); err != nil {
		return nil, err
	}
	// Followed before Playwright starts, so the tab it opens is known to be this agent's.
	d.followBrowserTabs(endpoint)
	s, err := openBrowserSession(ctx, browserStart{toolset: d.browser.Toolset(), endpoint: endpoint, cwd: cwd, output: drive.output, env: loginEnvironment()})
	if err != nil {
		return nil, err
	}
	d.startOnSessionTab(ctx, agent, s)
	drive.session, drive.endpoint = s, endpoint
	return drive, nil
}

func (b *browserDrive) call(ctx context.Context, name string, args map[string]json.RawMessage) (*mcp.CallToolResult, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.session == nil {
		return nil, errors.New("the browser's session ended")
	}
	if args == nil {
		args = map[string]json.RawMessage{}
	}
	return b.session.callTool(ctx, name, args)
}

// filterBrowserResult is what the agent gets of a result: its text with every hidden value
// out and no link into output, its images masked, and nothing else (structured content
// and resources are not filtered, so they are not sent). text is its text, for the record.
func (d *Daemon) filterBrowserResult(res *mcp.CallToolResult, output string) ([]any, string) {
	f := &d.browser.Filter
	var out []any
	var texts []string
	for _, c := range res.Content {
		switch c := c.(type) {
		case *mcp.TextContent:
			t := f.Text(outputLinks(c.Text, output))
			texts = append(texts, t)
			out = append(out, map[string]any{"type": "text", "text": t})
		case *mcp.ImageContent:
			data, err := f.Image(c.Data, c.MIMEType)
			if err != nil {
				log.Printf("browser: an image was left out, as it could not be masked: %v", err)
				out = append(out, map[string]any{"type": "text", "text": "(An image was left out: it could not be masked.)"})
				continue
			}
			out = append(out, map[string]any{"type": "image", "data": base64.StdEncoding.EncodeToString(data), "mimeType": c.MIMEType})
		default:
			out = append(out, map[string]any{"type": "text", "text": "(Something other than text or an image was left out.)"})
		}
	}
	if len(out) == 0 {
		out = []any{map[string]any{"type": "text", "text": ""}}
	}
	return out, strings.Join(texts, "\n")
}

// outputLinks is text with each file Playwright wrote in output named by the tool that
// reads it through the filter instead. After an action Playwright puts the page's
// snapshot, and new console lines, in files there and links them; an agent that read the
// file would read it past the filter (#3534).
func outputLinks(text, output string) string {
	if output == "" || !strings.Contains(text, output) {
		return text
	}
	quoted := regexp.QuoteMeta(output + string(filepath.Separator))
	link := regexp.MustCompile(`\[([^\]]*)\]\(` + quoted + `[^)\s]*\)|` + quoted + "[^\\s)'\"`]*")
	return link.ReplaceAllStringFunc(text, func(m string) string {
		label, path := "", m
		if strings.HasPrefix(m, "[") {
			i := strings.Index(m, "](")
			label, path = m[1:i], m[i+2:len(m)-1]
		}
		hint := "kept by the app"
		switch ext := filepath.Ext(strings.SplitN(path, "#", 2)[0]); ext {
		case ".yml", ".yaml":
			hint = "call browser_snapshot to read the page"
		case ".log":
			hint = "call browser_console_messages to read them"
		case ".png", ".jpeg", ".jpg":
			hint = "the image is in this result"
		}
		if label != "" {
			return label + " (" + hint + ")"
		}
		return "(" + hint + ")"
	})
}

// endBrowserSession ends this agent's @playwright/mcp, if one runs, and keeps its lease.
func (d *Daemon) endBrowserSession(agent wire.UUID) {
	d.browserMu.Lock()
	drive := d.browserDrives[agent]
	delete(d.browserDrives, agent)
	d.browserMu.Unlock()
	if drive == nil {
		return
	}
	drive.mu.Lock()
	if drive.session != nil {
		drive.session.close()
		drive.session = nil
	}
	drive.mu.Unlock()
	os.RemoveAll(drive.output)
}

// endBrowserDrive is what a turn's end does to the browser: the agent's @playwright/mcp
// ends and browser:agents goes to the next agent in line. The browser itself, its pages
// and its sign-ins stay, until it is idle (browser.IdleAfter). An agent whose hand-off is
// still open (#3529) keeps the lease, so no other agent takes the page from the person;
// the answer starts it again, and the lease's own length ends it if nobody answers.
func (d *Daemon) endBrowserDrive(agent wire.UUID) {
	d.endBrowserSession(agent)
	d.stopDrivingBrowser(agent)
	if d.holdsBrowser(agent) && d.handOffOpen(agent) == nil {
		d.releaseResource(agent, browserLeaseName)
	}
}

// stopBrowserDrives ends every @playwright/mcp this host started (Daemon.Shutdown).
func (d *Daemon) stopBrowserDrives() {
	d.browserMu.Lock()
	var agents []wire.UUID
	for a := range d.browserDrives {
		agents = append(agents, a)
	}
	d.browserMu.Unlock()
	for _, a := range agents {
		d.endBrowserSession(a)
	}
}

// browserWords is an error as a tool's answer says it: an *Error's message, without its code.
func browserWords(err error) string {
	var e *Error
	if errors.As(err, &e) {
		return e.Message
	}
	return err.Error()
}
