package agentsd

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"strings"
	"sync"

	"github.com/agentloops-dev/agents/Go/internal/browser"
	"github.com/agentloops-dev/agents/Go/wire"
)

// The browser and the screen ask on a machine a person uses (#4264, epic #4262). Browser and
// Desktop control are each Ask, Always Approve or Off (wire.DriveApproval). With Ask, an agent's
// call that takes the browser or the screen lease (the browser tools, fill_secret,
// hand_to_person, drive_screen, and lease_resource of either) first waits on a Needs you
// request of kind approve, as a secret's use does (secretuse.go): source secretUse, use browser
// or screen, that names the session, the machine and, for the screen, the app. The answers:
//
//   - once (Approve): this lease, until the agent lets go of it (settle's released event);
//   - session (Approve for This Session): every lease this session takes, until it is archived
//     or agentsd restarts;
//   - always (Always Approve): the setting becomes Always Approve, for every session;
//   - deny (Deny): the call fails, and every other call that would take it in this turn too.
//
// A machine only agents use (a bot's machine, a Codespace) is Always Approve when never set,
// and Ask counts as Always Approve there: nobody answers on it. Only a person's clients change
// the setting: the agent role reaches neither set method (roles.go), and each set checks it too.

const browserControlFile = "browser-control.json"

// askDriveByDefault is whether a setting never set is Ask on a machine a person uses. A var so
// the package's tests, which drive the browser and the screen on this Mac, start at Always
// Approve; a test of the ask turns it back on (askDrive).
var askDriveByDefault = true

// driveApprovalState is what a person approved, in agentsd's memory only: a restart asks again.
type driveApprovalState struct {
	driveMuApproval sync.Mutex
	// driveLeaseOK is each Approve that lasts until its lease is let go, and driveDenied each
	// Deny that lasts until the turn ends, both by secretUseKey.
	driveLeaseOK map[string]bool
	driveDenied  map[string]bool
}

// agentsOnly is whether only agents use this machine: a bot's, or a GitHub Codespace.
func (d *Daemon) agentsOnly() bool {
	return d.isBot() || os.Getenv("CODESPACES") == "true"
}

// driveDefault is a setting's mode when the person never set it.
func (d *Daemon) driveDefault() wire.DriveApproval {
	if d.agentsOnly() || !askDriveByDefault {
		return wire.DriveApprovalAlways
	}
	return wire.DriveApprovalAsk
}

// desktopControlMode is Desktop control's setting. A file from before #4264 has only enabled:
// On is Always Approve, so nothing changes for a Mac that turned it on; Off stays Off.
func (d *Daemon) desktopControlMode() wire.DriveApproval {
	var st struct {
		Enabled *bool               `json:"enabled"`
		Mode    *wire.DriveApproval `json:"mode"`
	}
	d.readSetting(desktopControlFile, &st)
	switch {
	case st.Mode != nil && validDriveApproval(*st.Mode):
		return *st.Mode
	case st.Enabled != nil && *st.Enabled:
		return wire.DriveApprovalAlways
	case st.Enabled != nil:
		return wire.DriveApprovalOff
	}
	return d.driveDefault()
}

// browserControlMode is Browser's setting.
func (d *Daemon) browserControlMode() wire.DriveApproval {
	var st struct {
		Mode *wire.DriveApproval `json:"mode"`
	}
	d.readSetting(browserControlFile, &st)
	if st.Mode != nil && validDriveApproval(*st.Mode) {
		return *st.Mode
	}
	return d.driveDefault()
}

func validDriveApproval(m wire.DriveApproval) bool {
	return m == wire.DriveApprovalAsk || m == wire.DriveApprovalAlways || m == wire.DriveApprovalOff
}

// driveMode is the setting for a use: browser or screen.
func (d *Daemon) driveMode(use wire.SecretUse) wire.DriveApproval {
	if use == wire.SecretUseScreen {
		return d.desktopControlMode()
	}
	return d.browserControlMode()
}

// browserOff is Browser's refusal while it is Off.
const browserOffWords = "Nothing was done: the browser is off on this machine, so no agent may use it. " +
	"The person can turn it on in Settings ▸ Browser."

// driveDeniedWords is a call a person denied: not asked again in this turn.
func driveDeniedWords(use wire.SecretUse) string {
	what := map[wire.SecretUse]string{wire.SecretUseBrowser: "the browser", wire.SecretUseScreen: "the screen"}[use]
	return "A person denied your use of " + what + " on " + thisMachine() + ". Do not ask again in this turn: " +
		"carry on without it, and say what is left that needs it."
}

// driveWaitWords is a call held on its request past the hold: wait, then call again.
func driveWaitWords(r wire.RequestSecretUse, id wire.UUID) string {
	return "Nothing was done yet: " + r.Place + " asks a person before an agent uses " + r.Name + ", and they have not answered yet. " +
		"Wait with wait_for_event, where: {\"request\": \"" + string(id) + "\"}, then call again."
}

// driveAsk is the request for an agent's use of the browser or the screen on this machine.
func (d *Daemon) driveAsk(use wire.SecretUse, app string) wire.RequestSecretUse {
	name := "the browser"
	if use == wire.SecretUseScreen {
		name = "the screen"
	}
	ask := wire.RequestSecretUse{Name: name, Use: use, Place: strings.TrimSpace(d.ownName())}
	if ask.Place == "" {
		ask.Place = thisMachine()
	}
	if app = strings.TrimSpace(app); app != "" && use == wire.SecretUseScreen {
		ask.App = &app
	}
	return ask
}

// approveDrive is whether agent may take the browser or the screen lease now: "" when it may;
// the words to give the agent while the request is still open; or the error of a Deny.
func (d *Daemon) approveDrive(agent wire.UUID, use wire.SecretUse, app string) (string, error) {
	if d.driveMode(use) != wire.DriveApprovalAsk || d.agentsOnly() {
		return "", nil
	}
	ask := d.driveAsk(use, app)
	key := secretUseKey(agent, ask.Name, ask.Use, ask.Place)
	d.driveMuApproval.Lock()
	denied := d.driveDenied[key]
	d.driveMuApproval.Unlock()
	if denied {
		return "", &Error{Code: CodeNotPermitted, Message: driveDeniedWords(use)}
	}
	if d.secretUseAllowed(agent, ask.Name, ask.Use, ask.Place) {
		return "", nil
	}
	return d.holdOnUse(agent, ask, formHoldLimit)
}

// driveAllowed is secretUseAllowed for the browser and the screen: this lease's Approve, or
// this session's. Under secretUseMu.
func (d *Daemon) driveAllowed(key string) bool {
	if d.secretUseSessions[key] {
		return true
	}
	d.driveMuApproval.Lock()
	defer d.driveMuApproval.Unlock()
	return d.driveLeaseOK[key]
}

// answerDriveUse is requests/answer for the browser's or the screen's use.
func (d *Daemon) answerDriveUse(rec wire.Request, a *wire.RequestSecretUseAnswer, by *wire.AuditActor) (wire.RequestUpdate, error) {
	if rec.AskedBy == nil {
		return wire.RequestUpdate{}, Invalid("This request has no session.")
	}
	ask := *rec.Detail.SecretUse
	setting := map[wire.SecretUse]string{wire.SecretUseBrowser: "Browser", wire.SecretUseScreen: "Desktop control"}[ask.Use]
	summary := map[string]string{secretUseOnce: "Approved", secretUseSession: "Approved for this session",
		secretUseAlways: "Always approved: " + setting + " is Always Approve", secretUseDeny: "Denied"}[a.Action]
	if summary == "" {
		return wire.RequestUpdate{}, Invalid("The answer is once, session, always or deny.")
	}
	agent := *rec.AskedBy
	if a.Action == secretUseAlways {
		var err error
		if ask.Use == wire.SecretUseScreen {
			_, err = d.saveDesktopControl(wire.DriveApprovalAlways)
		} else {
			_, err = d.saveBrowserControl(wire.DriveApprovalAlways)
		}
		if err != nil {
			return wire.RequestUpdate{}, err
		}
	}
	key := secretUseKey(agent, ask.Name, ask.Use, ask.Place)
	d.secretUseMu.Lock()
	if a.Action == secretUseSession {
		if d.secretUseSessions == nil {
			d.secretUseSessions = map[string]bool{}
		}
		d.secretUseSessions[key] = true
	}
	d.secretUseMu.Unlock()
	d.driveMuApproval.Lock()
	switch a.Action {
	case secretUseOnce:
		if d.driveLeaseOK == nil {
			d.driveLeaseOK = map[string]bool{}
		}
		d.driveLeaseOK[key] = true
	case secretUseDeny:
		if d.driveDenied == nil {
			d.driveDenied = map[string]bool{}
		}
		d.driveDenied[key] = true
	}
	d.driveMuApproval.Unlock()
	if !d.endRequest(rec.ID, wire.RequestStateAnswered, &summary, "", by) {
		return wire.RequestUpdate{}, &Error{Code: wire.FailureNoSuchAgent, Message: "That request has ended already."}
	}
	log.Printf("drive approval: %s on %s for %s: %s", ask.Use, ask.Place, agent, a.Action)
	d.secretUseEnded(rec.ID)
	after := d.request(rec.ID)
	if after == nil {
		after = &rec
	}
	return wire.RequestUpdate{Request: *after}, nil
}

// driveUseOf is the use a lease of resource needs approved: browser, screen, or "".
func driveUseOf(resource wire.ResourceName) wire.SecretUse {
	switch resource {
	case wire.ResourceName(browser.Resource):
		return wire.SecretUseBrowser
	case "screen":
		return wire.SecretUseScreen
	}
	return ""
}

// forgetDriveLease drops a lease's Approve when its holder lets go of it (settle).
func (d *Daemon) forgetDriveLease(holder wire.UUID, resource wire.ResourceName) {
	use := driveUseOf(resource)
	if use == "" {
		return
	}
	d.forgetDrive(holder, use, false)
}

// forgetDriveDenial drops a Deny at the turn's end: the next turn may ask again.
func (d *Daemon) forgetDriveDenial(agent wire.UUID, use wire.SecretUse) { d.forgetDrive(agent, use, true) }

func (d *Daemon) forgetDrive(agent wire.UUID, use wire.SecretUse, denial bool) {
	prefix := string(sessionKey(agent)) + "|"
	suffix := "|" + grantPlace(use, "")
	d.driveMuApproval.Lock()
	defer d.driveMuApproval.Unlock()
	m := d.driveLeaseOK
	if denial {
		m = d.driveDenied
	}
	for k := range m {
		if strings.HasPrefix(k, prefix) && strings.Contains(k, suffix) {
			delete(m, k)
		}
	}
}

// forgetSessionDrives drops everything a person approved or denied an archived session.
func (d *Daemon) forgetSessionDrives(agent wire.UUID) {
	prefix := string(sessionKey(agent)) + "|"
	d.driveMuApproval.Lock()
	defer d.driveMuApproval.Unlock()
	for _, m := range []map[string]bool{d.driveLeaseOK, d.driveDenied} {
		for k := range m {
			if strings.HasPrefix(k, prefix) {
				delete(m, k)
			}
		}
	}
}

// leaseResourceTool is lease_resource as an agent calls it: a lease of the browser or the
// screen asks first, as their tools do. A lease it holds already is only extended.
func (d *Daemon) leaseResourceTool(agent wire.UUID, args map[string]json.RawMessage) (string, error) {
	if name, ok := resourceName(argString(args, "name")); ok {
		if use := driveUseOf(name); use != "" && !d.holdsResource(agent, name) {
			if words, err := d.approveDrive(agent, use, ""); err != nil || words != "" {
				return words, err
			}
		}
	}
	return d.leaseResource(agent, args)
}

// holdsResource is whether agent holds the resource now.
func (d *Daemon) holdsResource(agent wire.UUID, name wire.ResourceName) bool {
	d.leaseMu.Lock()
	defer d.leaseMu.Unlock()
	d.loadLeases()
	e := d.book.Entries[name]
	return e != nil && holderIndex(e, agent) >= 0
}

// saveDesktopControl keeps Desktop control's mode, with enabled for a client from before #4264.
func (d *Daemon) saveDesktopControl(m wire.DriveApproval) (wire.DesktopControlSettings, error) {
	st := wire.DesktopControlSettings{Enabled: m != wire.DriveApprovalOff, Mode: &m}
	if err := d.writeSetting(desktopControlFile, st); err != nil {
		return wire.DesktopControlSettings{}, &Error{Code: wire.FailureCouldNotSave, Message: desktopControlFile + ": " + err.Error()}
	}
	return st, nil
}

// saveBrowserControl keeps Browser's mode.
func (d *Daemon) saveBrowserControl(m wire.DriveApproval) (wire.BrowserControlSettings, error) {
	st := wire.BrowserControlSettings{Mode: m}
	if err := d.writeSetting(browserControlFile, st); err != nil {
		return wire.BrowserControlSettings{}, &Error{Code: wire.FailureCouldNotSave, Message: browserControlFile + ": " + err.Error()}
	}
	return st, nil
}

// personsClient is whether c is one of the person's own clients: never an agent, an MCP tool or
// a workflow, which reach a host method only over the agent socket role.
func personsClient(c *Client) bool { return c != nil && (c.Role == RoleControl || c.Role == RoleDevice) }

func (d *Daemon) registerBrowserControl() {
	On(d, wire.CallBrowserControlState, func(_ context.Context, _ *Client, _ wire.Empty) (wire.BrowserControlSettings, error) {
		return wire.BrowserControlSettings{Mode: d.browserControlMode()}, nil
	})
	On(d, wire.CallBrowserControlSet, func(_ context.Context, c *Client, in wire.BrowserControlSettings) (wire.BrowserControlSettings, error) {
		if !personsClient(c) {
			return wire.BrowserControlSettings{}, &Error{Code: CodeNotPermitted, Message: "Only your own clients can change the browser's setting."}
		}
		if !validDriveApproval(in.Mode) {
			return wire.BrowserControlSettings{}, Invalid("The browser's setting is ask, always or off.")
		}
		return d.saveBrowserControl(in.Mode)
	})
}
