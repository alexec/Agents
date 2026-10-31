package agentsd

import (
	"context"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
	"golang.org/x/sys/unix"
)

// registerSelfUpdate serves selfUpdate/status and selfUpdate/set on a Mac whose host runs
// from an Agents Host.app (#2178). A test's host serves neither: it is in no bundle a
// release could replace.
func (d *Daemon) registerSelfUpdate() {
	if testing.Testing() {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		return
	}
	if real, err := filepath.EvalSymlinks(exe); err == nil {
		exe = real
	}
	app := enclosingApp(exe)
	if app == "" {
		return
	}
	file := filepath.Join(d.Store.Loc.Root, selfUpdateFile)
	keep, back := settleSelfUpdates(app, buildinfo.Version, file, exchangePaths)
	if back {
		if err := restartLaunchAgents(); err != nil {
			log.Printf("self-update: the old copy is back; quit and open Agents Host to run it: %v", err)
		}
		return
	}
	if len(keep) > 0 {
		safe.Go("self-update-settle", func() {
			select {
			case <-d.ctx.Done():
			case <-time.After(selfUpdateHealthy):
				for _, work := range keep {
					os.RemoveAll(work)
				}
			}
		})
	}
	u := newSelfUpdater(file, app, buildinfo.Version)
	u.unpack, u.verify, u.version, u.restart = dittoUnpack, verifyRelease, bundleVersion, restartLaunchAgents
	if u.status.State != wire.SelfUpdateStateCannot {
		if team, _ := signingOf(app); team == "" {
			why := "This copy of Agents Host is not signed by a team, so it does not update itself."
			u.status.State, u.status.Message = wire.SelfUpdateStateCannot, &why
		}
	}
	d.serveSelfUpdate(u)
}

// exchangePaths swaps two paths in one step (renamex_np with RENAME_SWAP, #2710).
func exchangePaths(a, b string) error {
	return unix.RenamexNp(a, b, unix.RENAME_SWAP)
}

func dittoUnpack(zip, dir string) error {
	if out, err := exec.Command("/usr/bin/ditto", "-x", "-k", zip, dir).CombinedOutput(); err != nil {
		return fmt.Errorf("%v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

func bundleVersion(app string) (string, error) {
	out, err := exec.Command("/usr/bin/plutil", "-extract", "CFBundleShortVersionString", "raw", "-o", "-",
		filepath.Join(app, "Contents", "Info.plist")).Output()
	return strings.TrimSpace(string(out)), err
}

// signingOf is an app's team and identifier, as codesign prints them; "" for one
// signed ad hoc.
func signingOf(app string) (team, identifier string) {
	out, _ := exec.Command("/usr/bin/codesign", "-dv", "--verbose=2", app).CombinedOutput()
	for _, line := range strings.Split(string(out), "\n") {
		if v, ok := strings.CutPrefix(line, "TeamIdentifier="); ok && v != "not set" {
			team = strings.TrimSpace(v)
		}
		if v, ok := strings.CutPrefix(line, "Identifier="); ok {
			identifier = strings.TrimSpace(v)
		}
	}
	return team, identifier
}

// verifyRelease checks the new copy as Gatekeeper would, and more: signed, sealed and
// whole, by this copy's team with this copy's identifier, and notarised.
func verifyRelease(next, running string) error {
	team, identifier := signingOf(running)
	if team == "" || identifier == "" {
		return fmt.Errorf("this copy has no team to check the new one against")
	}
	req := fmt.Sprintf(`=anchor apple generic and identifier "%s" and certificate leaf[subject.OU] = "%s"`, identifier, team)
	if out, err := exec.Command("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R", req, next).CombinedOutput(); err != nil {
		return fmt.Errorf("codesign: %s", strings.TrimSpace(string(out)))
	}
	out, err := exec.Command("/usr/sbin/spctl", "--assess", "--type", "execute", "-vv", next).CombinedOutput()
	if err != nil {
		return fmt.Errorf("spctl: %s", strings.TrimSpace(string(out)))
	}
	if !strings.Contains(string(out), "Notarized Developer ID") {
		return fmt.Errorf("not notarised: %s", strings.TrimSpace(string(out)))
	}
	return nil
}

// restartLaunchAgents starts each of Agents Host's launch agents again, this host last:
// launchd runs what is in the bundle now. It is started by launchd as
// <prefix>.daemon, and the others are <prefix>.control and <prefix>.relay.
func restartLaunchAgents() error {
	label := os.Getenv("XPC_SERVICE_NAME")
	prefix, ok := strings.CutSuffix(label, ".daemon")
	if !ok {
		return fmt.Errorf("this host was not started by its launch agent")
	}
	domain := fmt.Sprintf("gui/%d/", os.Getuid())
	for _, job := range []string{"control", "relay"} {
		// One not loaded (no control plane here, no relay) answers an error, and is left.
		exec.Command("/bin/launchctl", "kickstart", "-k", domain+prefix+"."+job).Run()
	}
	// launchd stops this process (a SIGTERM, which ends it as a stop does) and starts it again.
	return exec.Command("/bin/launchctl", "kickstart", "-k", domain+label).Start()
}

// turnsRunning is how many agents are in a turn: one waiting on the person is too.
// Only a Mac's self-update asks (serveSelfUpdate); a Linux build would call it unused.
func (d *Daemon) turnsRunning() int {
	n := 0
	for _, a := range d.Store.Agents() {
		if d.turnIsRunning(a.ID) {
			n++
		}
	}
	return n
}

// serveSelfUpdate serves selfUpdate/status and selfUpdate/set for an updater.
func (d *Daemon) serveSelfUpdate(u *selfUpdater) {
	u.ctx = d.ctx
	u.turns = d.turnsRunning
	u.tell = func(s wire.SelfUpdate) { Broadcast(d, wire.NotifySelfUpdateChanged, s) }
	d.selfUpdateState.updater = u
	On(d, wire.CallSelfUpdateStatus, func(context.Context, *Client, wire.Empty) (wire.SelfUpdate, error) {
		return u.Status(), nil
	})
	On(d, wire.CallSelfUpdateSet, func(_ context.Context, _ *Client, r wire.SelfUpdateSet) (wire.SelfUpdate, error) {
		return u.Set(r)
	})
}
