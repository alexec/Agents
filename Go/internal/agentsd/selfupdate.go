package agentsd

import (
	"bufio"
	"cmp"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
	"golang.org/x/sys/unix"
)

// Agents Host updates itself on a Mac (#2178, Enterprise T7). The control plane names its
// release in host/release at each join. When it is newer than this copy, and the person
// has not turned updating off (selfUpdate/set, self-update.json in the root), the host:
//
//  1. downloads the release's Agents-Host-<version>.zip and SHA256SUMS, and checks the sum;
//  2. unpacks it beside this copy, and checks the new copy's signature (the same team and
//     identifier as this one), its notarisation and its version;
//  3. waits until no turn runs, then swaps the new copy and this one in one step, and keeps
//     this one beside it, with a mark (#2710);
//  4. restarts the launch agents, which run what is in the bundle now.
//
// The old copy stays until the new one has stayed up selfUpdateHealthy. A new copy that
// starts selfUpdateTries times without staying up is swapped back for the old one, and its
// release is not taken again (settleSelfUpdates).
//
// It never asks for an administrator (#2178, hosts never escalate): a copy in a folder the
// person cannot change, such as /Applications for a standard user, says so and stays.
// A development build, or a copy with no team, never updates itself.

const selfUpdateFile = "self-update.json"

// selfUpdateLimit bounds the download: the release's zip is about 100 MB.
const selfUpdateLimit = 1 << 30

// selfUpdateMark is the mark an update leaves in its folder beside the app just before the
// swap (#2710): which release replaced which, where the old copy is, and how many times the
// new copy has started.
const selfUpdateMark = "update.json"

// A new copy has selfUpdateTries starts to stay up selfUpdateHealthy; then the old copy
// goes back. launchd starts a host that ends again after about ten seconds.
const (
	selfUpdateTries   = 3
	selfUpdateHealthy = 5 * time.Minute
)

type selfUpdateMarkFile struct {
	From   string `json:"from"`
	To     string `json:"to"`
	Old    string `json:"old"` // the old copy, in the update's folder
	Starts int    `json:"starts"`
}

// releaseDownloads is where a release's files are, by tag. AGENTS_RELEASE_DOWNLOADS
// replaces it, for a test or a mirror.
const releaseDownloads = "https://github.com/alexec/Agents/releases/download"

// selfUpdater is one Mac host's updater; nil on a host that is not in an Agents Host.app.
type selfUpdater struct {
	file    string
	app     string // the Agents Host.app this host runs from
	running string // this copy's version
	tell    func(wire.SelfUpdate)
	turns   func() int
	ctx     context.Context

	// What the Mac does, replaced by a test.
	fetch    func(ctx context.Context, url string, w io.Writer, limit int64) error
	unpack   func(zip, dir string) error
	verify   func(next, running string) error
	version  func(app string) (string, error)
	writable func(app string) error
	swap     func(a, b string) error
	restart  func() error
	pause    time.Duration

	mu     sync.Mutex
	status wire.SelfUpdate
	// busy is a release being downloaded, checked or waited on; another named meanwhile
	// waits for it to end.
	busy bool
	// rolledBack is a release that did not stay up here, so it is not taken again.
	rolledBack string
}

type selfUpdateState struct {
	updater *selfUpdater
}

type selfUpdateSettings struct {
	AutoUpdate bool   `json:"autoUpdate"`
	RolledBack string `json:"rolledBack,omitempty"`
}

func readSelfUpdateSettings(path string) selfUpdateSettings {
	s := selfUpdateSettings{AutoUpdate: true}
	if b, err := os.ReadFile(path); err == nil {
		var m map[string]json.RawMessage
		if json.Unmarshal(b, &m) == nil {
			json.Unmarshal(m["autoUpdate"], &s.AutoUpdate)
			json.Unmarshal(m["rolledBack"], &s.RolledBack)
		}
	}
	return s
}

func writeSelfUpdateSettings(path string, s selfUpdateSettings) error {
	b, _ := json.Marshal(s)
	return store.WriteAtomically(path, b, 0o600)
}

func newSelfUpdater(file, app, running string) *selfUpdater {
	u := &selfUpdater{file: file, app: app, running: running, pause: 15 * time.Second,
		fetch: fetchTo, writable: folderWritable, swap: exchangePaths, ctx: context.Background()}
	settings := readSelfUpdateSettings(file)
	u.rolledBack = settings.RolledBack
	u.status = wire.SelfUpdate{AutoUpdate: settings.AutoUpdate, State: wire.SelfUpdateStateUpToDate, Running: running}
	if why := u.cannot(); why != "" {
		u.status.State, u.status.Message = wire.SelfUpdateStateCannot, &why
	} else if !u.status.AutoUpdate {
		u.status.State = wire.SelfUpdateStateOff
	}
	return u
}

// cannot is why this copy never updates itself, or "".
func (u *selfUpdater) cannot() string {
	if _, ok := releaseVersion(u.running); !ok {
		return "This copy of Agents Host is a development build, so it does not update itself."
	}
	if strings.Contains(u.app, "/AppTranslocation/") {
		return "macOS runs this copy of Agents Host from a temporary place. Move it to Applications in your home folder, then open it again, so it can update itself."
	}
	return ""
}

func (u *selfUpdater) Status() wire.SelfUpdate {
	u.mu.Lock()
	defer u.mu.Unlock()
	return u.status
}

func (u *selfUpdater) set(change func(*wire.SelfUpdate)) {
	u.mu.Lock()
	change(&u.status)
	s := u.status
	u.mu.Unlock()
	if u.tell != nil {
		u.tell(s)
	}
}

// Set is selfUpdate/set: kept, and a release named before is taken up at once.
func (u *selfUpdater) Set(r wire.SelfUpdateSet) (wire.SelfUpdate, error) {
	settings := readSelfUpdateSettings(u.file)
	settings.AutoUpdate = r.AutoUpdate
	if err := writeSelfUpdateSettings(u.file, settings); err != nil {
		return u.Status(), err
	}
	u.mu.Lock()
	release := u.status.Release
	u.mu.Unlock()
	u.set(func(s *wire.SelfUpdate) {
		s.AutoUpdate = r.AutoUpdate
		if s.State == wire.SelfUpdateStateOff && r.AutoUpdate {
			s.State = wire.SelfUpdateStateUpToDate
		}
	})
	if release != nil {
		u.Named(*release)
	} else if !r.AutoUpdate {
		u.set(func(s *wire.SelfUpdate) {
			if s.State == wire.SelfUpdateStateUpToDate {
				s.State = wire.SelfUpdateStateOff
			}
		})
	}
	return u.Status(), nil
}

// Named is host/release: the release the control plane names. A newer one is taken up,
// unless updating is off or this copy cannot update itself.
func (u *selfUpdater) Named(version string) {
	u.mu.Lock()
	u.status.Release = &version
	busy, on, state := u.busy, u.status.AutoUpdate, u.status.State
	u.mu.Unlock()
	if busy || state == wire.SelfUpdateStateCannot || state == wire.SelfUpdateStateRestarting {
		u.set(func(*wire.SelfUpdate) {})
		return
	}
	if !on {
		u.set(func(s *wire.SelfUpdate) { s.State, s.Message = wire.SelfUpdateStateOff, nil })
		return
	}
	if !newerRelease(version, u.running) {
		u.set(func(s *wire.SelfUpdate) { s.State, s.Message = wire.SelfUpdateStateUpToDate, nil })
		return
	}
	if version == u.rolledBack {
		why := "Agents Host " + version + " did not stay running here, so this Mac went back to " + u.running +
			". It waits for the next release."
		u.set(func(s *wire.SelfUpdate) { s.State, s.Message = wire.SelfUpdateStateFailed, &why })
		return
	}
	if err := u.writable(u.app); err != nil {
		why := "Agents Host is in a folder you can change only as an administrator (" + filepath.Dir(u.app) +
			"). Move it to Applications in your home folder, then open it again, so it can update itself."
		u.set(func(s *wire.SelfUpdate) { s.State, s.Message = wire.SelfUpdateStateCannot, &why })
		return
	}
	u.mu.Lock()
	u.busy = true
	u.mu.Unlock()
	safe.Go("self-update", func() {
		err := u.update(version)
		u.mu.Lock()
		u.busy = false
		u.mu.Unlock()
		if err != nil {
			log.Printf("self-update: %s: %v", version, err)
			why := err.Error()
			u.set(func(s *wire.SelfUpdate) {
				if s.State == wire.SelfUpdateStateOff {
					return
				}
				s.State, s.Message = wire.SelfUpdateStateFailed, &why
			})
		}
	})
}

// errTurnedOff is updating turned off while a release waited: nothing was changed.
var errTurnedOff = errors.New("turned off")

func (u *selfUpdater) update(version string) error {
	u.set(func(s *wire.SelfUpdate) { s.State, s.Message = wire.SelfUpdateStateDownloading, nil })
	work, err := os.MkdirTemp(filepath.Dir(u.app), ".Agents Host.update-")
	if err != nil {
		return fmt.Errorf("Agents Host could not make a folder beside itself for the update: %w", err)
	}
	swapped := false
	defer func() {
		// After the swap the folder holds the old copy, which may still be running: the
		// new copy takes it away once it has stayed up (settleSelfUpdates).
		if !swapped {
			os.RemoveAll(work)
		}
	}()
	next, err := u.download(version, work)
	if err != nil {
		return err
	}
	if v, err := u.version(next); err != nil || v != version {
		return fmt.Errorf("The download is not Agents Host %s (it says %q), so it was not installed.", version, v)
	}
	if err := u.verify(next, u.app); err != nil {
		return fmt.Errorf("The download's signature or notarisation did not check out, so it was not installed: %v", err)
	}
	u.set(func(s *wire.SelfUpdate) { s.State = wire.SelfUpdateStateWaiting })
	if err := u.betweenTurns(); err != nil {
		return err
	}
	if err := u.putInPlace(version, work, next); err != nil {
		return err
	}
	swapped = true
	log.Printf("self-update: Agents Host %s is in place of %s", version, u.running)
	u.set(func(s *wire.SelfUpdate) { s.State, s.Message = wire.SelfUpdateStateRestarting, nil })
	// A turn that started since is not cut: the restart waits for it too.
	if err := u.betweenTurns(); err != nil && !errors.Is(err, errTurnedOff) {
		return err
	}
	if err := u.restart(); err != nil {
		return fmt.Errorf("Agents Host %s is installed. Quit and open Agents Host to finish: %v", version, err)
	}
	return nil
}

// putInPlace swaps the new copy and this one in one step, so the app is never missing; the
// old copy is then where the new one was. Where the folder cannot swap, it takes two
// renames, and a start that finds no app puts the old copy back. The mark is written
// first either way.
func (u *selfUpdater) putInPlace(version, work, next string) error {
	mark := selfUpdateMarkFile{From: u.running, To: version, Old: strings.TrimPrefix(next, work+string(filepath.Separator))}
	if err := writeSelfUpdateMark(work, mark); err != nil {
		return fmt.Errorf("Agents Host could not keep a note of the update: %w", err)
	}
	err := u.swap(u.app, next)
	if err == nil {
		return nil
	}
	log.Printf("self-update: no swap in one step (%v): two renames", err)
	mark.Old = "old.app"
	if err := writeSelfUpdateMark(work, mark); err != nil {
		return fmt.Errorf("Agents Host could not keep a note of the update: %w", err)
	}
	old := filepath.Join(work, mark.Old)
	if err := os.Rename(u.app, old); err != nil {
		return fmt.Errorf("Agents Host could not move itself aside: %w", err)
	}
	if err := os.Rename(next, u.app); err != nil {
		os.Rename(old, u.app)
		return fmt.Errorf("Agents Host could not put the new copy in its place: %w", err)
	}
	return nil
}

func writeSelfUpdateMark(work string, m selfUpdateMarkFile) error {
	b, _ := json.Marshal(m)
	return store.WriteAtomically(filepath.Join(work, selfUpdateMark), b, 0o600)
}

// betweenTurns waits until no turn runs; it ends early when the host stops or updating is
// turned off before the swap.
func (u *selfUpdater) betweenTurns() error {
	for {
		u.mu.Lock()
		state, on := u.status.State, u.status.AutoUpdate
		u.mu.Unlock()
		if !on && state == wire.SelfUpdateStateWaiting {
			u.set(func(s *wire.SelfUpdate) { s.State = wire.SelfUpdateStateOff })
			return errTurnedOff
		}
		if u.turns() == 0 {
			return nil
		}
		select {
		case <-u.ctx.Done():
			return u.ctx.Err()
		case <-time.After(u.pause):
		}
	}
}

// download fetches the release's zip and its sum, checks the one against the other, and
// unpacks it in work. It is the new Agents Host.app.
func (u *selfUpdater) download(version, work string) (string, error) {
	base := strings.TrimSuffix(cmp.Or(os.Getenv("AGENTS_RELEASE_DOWNLOADS"), releaseDownloads), "/") + "/v" + version + "/"
	name := "Agents-Host-" + version + ".zip"
	var sums strings.Builder
	if err := u.fetch(u.ctx, base+"SHA256SUMS", &sums, 1<<16); err != nil {
		return "", fmt.Errorf("Agents Host could not download release %s's checksums: %w", version, err)
	}
	want := sumFor(sums.String(), name)
	if want == "" {
		return "", fmt.Errorf("Release %s lists no checksum for %s.", version, name)
	}
	zip := filepath.Join(work, name)
	f, err := os.Create(zip)
	if err != nil {
		return "", err
	}
	h := sha256.New()
	err = u.fetch(u.ctx, base+name, io.MultiWriter(f, h), selfUpdateLimit)
	f.Close()
	if err != nil {
		return "", fmt.Errorf("Agents Host could not download release %s: %w", version, err)
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		return "", fmt.Errorf("The download of release %s does not match its checksum, so it was not installed.", version)
	}
	out := filepath.Join(work, "new")
	if err := u.unpack(zip, out); err != nil {
		return "", fmt.Errorf("Agents Host could not unpack release %s: %w", version, err)
	}
	os.Remove(zip)
	next := filepath.Join(out, filepath.Base(u.app))
	if fi, err := os.Stat(next); err != nil || !fi.IsDir() {
		return "", fmt.Errorf("Release %s holds no %s.", version, filepath.Base(u.app))
	}
	return next, nil
}

// sumFor is the sum SHA256SUMS gives a file ("<hex>  <name>"), or "".
func sumFor(sums, name string) string {
	sc := bufio.NewScanner(strings.NewReader(sums))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) == 2 && strings.TrimPrefix(f[1], "*") == name && len(f[0]) == 64 {
			return strings.ToLower(f[0])
		}
	}
	return ""
}

var selfUpdateHTTP = &http.Client{Timeout: 30 * time.Minute}

// fetchTo copies a URL's body to w: at most limit bytes, or an error.
func fetchTo(ctx context.Context, url string, w io.Writer, limit int64) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return err
	}
	resp, err := selfUpdateHTTP.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s answered %s", url, resp.Status)
	}
	n, err := io.Copy(w, io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return err
	}
	if n > limit {
		return fmt.Errorf("%s is larger than %d bytes", url, limit)
	}
	return nil
}

// folderWritable is nil when this user can move the app within its folder, with no
// administrator.
func folderWritable(app string) error {
	if err := unix.Access(filepath.Dir(app), unix.W_OK); err != nil {
		return err
	}
	return unix.Access(app, unix.W_OK)
}

// settleSelfUpdates is what a start does with what an update left beside the app (#2710).
// A folder with no mark is a download that a stop cut short: it goes. A folder with a mark
// holds the old copy:
//   - with no app in place (a cut between two renames), the old copy goes back;
//   - when this is the new copy, the start is counted, and the folder is kept until this
//     copy has stayed up; a start past selfUpdateTries swaps the old copy back and keeps its
//     release from being taken again;
//   - otherwise (the old copy runs again, or another copy was put there), it goes.
//
// keep is the folders to take away once this copy has stayed up selfUpdateHealthy. back is
// the old copy put back: this host restarts, to run it.
func settleSelfUpdates(app, running, settingsFile string, swap func(a, b string) error) (keep []string, back bool) {
	matches, _ := filepath.Glob(filepath.Join(filepath.Dir(app), ".Agents Host.update-*"))
	for _, work := range matches {
		var mark selfUpdateMarkFile
		b, err := os.ReadFile(filepath.Join(work, selfUpdateMark))
		if err != nil || json.Unmarshal(b, &mark) != nil || mark.Old == "" {
			os.RemoveAll(work)
			continue
		}
		old := filepath.Join(work, mark.Old)
		if _, err := os.Stat(app); errors.Is(err, os.ErrNotExist) {
			if err := os.Rename(old, app); err != nil {
				log.Printf("self-update: no app at %s, and the old copy did not go back: %v", app, err)
				continue
			}
			log.Printf("self-update: no app at %s: Agents Host %s went back", app, mark.From)
			os.RemoveAll(work)
			back = true
			continue
		}
		if mark.To != running {
			os.RemoveAll(work)
			continue
		}
		mark.Starts++
		if mark.Starts <= selfUpdateTries {
			if err := writeSelfUpdateMark(work, mark); err != nil {
				log.Printf("self-update: %v", err)
			}
			keep = append(keep, work)
			continue
		}
		if err := swapBack(app, old, swap); err != nil {
			log.Printf("self-update: Agents Host %s did not stay up, and %s did not go back: %v", mark.To, mark.From, err)
			keep = append(keep, work)
			continue
		}
		log.Printf("self-update: Agents Host %s started %d times without staying up: %s went back", mark.To, selfUpdateTries, mark.From)
		settings := readSelfUpdateSettings(settingsFile)
		settings.RolledBack = mark.To
		if err := writeSelfUpdateSettings(settingsFile, settings); err != nil {
			log.Printf("self-update: %v", err)
		}
		os.RemoveAll(work)
		back = true
	}
	return keep, back
}

// swapBack puts the old copy in the app's place: in one step, or with two renames.
func swapBack(app, old string, swap func(a, b string) error) error {
	if swap(app, old) == nil {
		return nil
	}
	aside := old + ".failed"
	if err := os.Rename(app, aside); err != nil {
		return err
	}
	if err := os.Rename(old, app); err != nil {
		os.Rename(aside, app)
		return err
	}
	return nil
}

// releaseVersion is X.Y.Z as three numbers; not ok for a development build (a suffix).
func releaseVersion(v string) ([3]int, bool) {
	var out [3]int
	parts := strings.Split(strings.TrimPrefix(v, "v"), ".")
	if len(parts) != 3 {
		return out, false
	}
	for i, p := range parts {
		n, err := strconv.Atoi(p)
		if err != nil || n < 0 {
			return out, false
		}
		out[i] = n
	}
	return out, true
}

// newerRelease is whether named is a release later than running. An older one is never
// taken: an update never goes back.
func newerRelease(named, running string) bool {
	a, ok1 := releaseVersion(named)
	b, ok2 := releaseVersion(running)
	if !ok1 || !ok2 {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return a[i] > b[i]
		}
	}
	return false
}

// enclosingApp is the outermost-first .app the executable is in: Agents Host.app for
// Contents/Helpers/agentsd. "" when it is in none.
func enclosingApp(executable string) string {
	for dir := filepath.Dir(executable); dir != "/" && dir != "."; dir = filepath.Dir(dir) {
		if strings.HasSuffix(dir, ".app") {
			return dir
		}
	}
	return ""
}

// toldRelease is host/release.
func (d *Daemon) toldRelease(params json.RawMessage) {
	var r wire.MachineRelease
	if err := json.Unmarshal(params, &r); err != nil {
		log.Printf("self-update: %s: %v", wire.NotifyHostRelease.Name, err)
		return
	}
	if u := d.selfUpdateState.updater; u != nil {
		u.Named(r.Version)
	}
}
