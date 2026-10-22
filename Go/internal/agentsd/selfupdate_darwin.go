package agentsd

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/buildinfo"
	"github.com/alexec/agents/Go/wire"
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
	cleanSelfUpdates(app)
	u := newSelfUpdater(filepath.Join(d.Store.Loc.Root, selfUpdateFile), app, buildinfo.Version)
	u.unpack, u.verify, u.version, u.restart = dittoUnpack, verifyRelease, bundleVersion, restartLaunchAgents
	if u.status.State != wire.SelfUpdateStateCannot {
		if team, _ := signingOf(app); team == "" {
			why := "This copy of Agents Host is not signed by a team, so it does not update itself."
			u.status.State, u.status.Message = wire.SelfUpdateStateCannot, &why
		}
	}
	d.serveSelfUpdate(u)
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
