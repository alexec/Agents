package agentsd

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The first build (#5048, spec "How the agent starts", #5056): a newcomer's idea, sent from
// the plan page of the Mac window or the web page, starts one agent with the start-a-new-app
// skill. The host makes its folder and writes its prompt, so every client starts the same agent.

// firstBuildLabel marks the first-build session: the plan page, and a second client, find it
// by this label.
const firstBuildLabel = "first-build"

// firstBuildMu makes the check for a first-build session and the start one step, so two
// Submits at once (two clients) start one agent.
var firstBuildMu sync.Mutex

// registerFirstBuild serves firstBuild/start.
func (d *Daemon) registerFirstBuild() {
	On(d, wire.CallFirstBuildStart, func(ctx context.Context, c *Client, r wire.FirstBuildStartRequest) (wire.UUID, error) {
		return d.startFirstBuild(r, c.actor())
	})
}

// startFirstBuild adds the folder ~/.agents/first-build when it is not there and starts the
// agent in it, labelled first-build. While a first-build session that is not archived is
// there, it refuses with that session's id, unless the request asks for another (New App…).
func (d *Daemon) startFirstBuild(r wire.FirstBuildStartRequest, actor *wire.AuditActor) (wire.UUID, error) {
	idea := strings.TrimSpace(r.Idea)
	if idea == "" {
		return "", Invalid("firstBuild/start: no idea")
	}
	kind, ok := firstBuildKinds[r.Starter]
	if !ok {
		return "", Invalid("firstBuild/start: %q is not a starter", r.Starter)
	}
	if r.RuntimeID == "" {
		return "", Invalid("firstBuild/start: no runtime")
	}
	firstBuildMu.Lock()
	defer firstBuildMu.Unlock()
	// New App… (#5132) asks for one more on purpose: only the newcomer's Submit is one per control plane.
	another := r.Another != nil && *r.Another
	if id, ok := d.firstBuildSession(); ok && !another {
		return "", &Error{Code: wire.FailureFirstBuildRunning,
			Message: "A first build is there already: session " + string(id) + ".",
			Data:    map[string]any{"agentID": id}}
	}
	folder, err := d.firstBuildFolder()
	if err != nil {
		return "", err
	}
	return d.startAs(wire.StartRequest{RuntimeID: r.RuntimeID, Cwd: store.FolderURL(folder),
		Prompt: firstBuildPrompt(idea, kind, r.Starter), Attachments: []wire.Attachment{},
		StartOptions:          wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}},
		AdditionalDirectories: []wire.URL{}, McpServers: []wire.MCPServer{}, Labels: []string{firstBuildLabel}}, actor)
}

// firstBuildKinds is the words the prompt gives each starter.
var firstBuildKinds = map[wire.FirstBuildStarter]string{
	wire.FirstBuildStarterIphoneApp:  "iPhone app",
	wire.FirstBuildStarterWebService: "Web service",
}

// firstBuildPrompt is the agent's first prompt, the same from every client.
func firstBuildPrompt(idea, kind string, starter wire.FirstBuildStarter) string {
	return "Build my first app with the start-a-new-app skill. The idea: " + idea + ". The kind: " + kind +
		"; the starter: " + string(starter) + ". Keep the first-build task list as your plan."
}

// firstBuildSession is the first-build session that is not archived, when one is there.
func (d *Daemon) firstBuildSession() (wire.UUID, bool) {
	for _, a := range d.Store.Agents() {
		if a.ArchivedAt != nil {
			continue
		}
		if slices.ContainsFunc(a.Labels, func(l wire.SessionLabel) bool { return l.Value == firstBuildLabel }) {
			return a.ID, true
		}
	}
	return "", false
}

// firstBuildFolder makes ~/.agents/first-build, an empty folder and not a repository, and adds
// it as a folder when it is not one already. A root with no personal home (a scratch root)
// keeps it in the root, so a walk never writes into the person's home.
func (d *Daemon) firstBuildFolder() (string, error) {
	base := d.Store.Loc.Root
	if home := d.personalHome(); home != "" {
		base = filepath.Join(home, ".agents")
	}
	folder := filepath.Join(base, firstBuildLabel)
	if err := os.MkdirAll(folder, 0o755); err != nil {
		return "", &Error{Code: CodeFolderGone, Message: folder + " could not be made: " + err.Error()}
	}
	if r, err := store.Resolve(folder); err == nil {
		folder = r
	}
	for _, f := range d.Store.Folders() {
		if store.FolderPath(f.Folder) == folder {
			return folder, nil
		}
	}
	if _, err := d.addFolderOf(store.FolderURL(folder), true, ""); err != nil {
		return "", err
	}
	return folder, nil
}
