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
// release in machine/release at each join. When it is newer than this copy, and the person
// has not turned updating off (selfUpdate/set, self-update.json in the root), the host:
//
//  1. downloads the release's Agents-Host-<version>.zip and SHA256SUMS, and checks the sum;
//  2. unpacks it beside this copy, and checks the new copy's signature (the same team and
//     identifier as this one), its notarisation and its version;
//  3. waits until no turn runs, then puts the new copy where this one is;
//  4. restarts the launch agents, which run what is in the bundle now.
//
// It never asks for an administrator (#2178, hosts never escalate): a copy in a folder the
// person cannot change, such as /Applications for a standard user, says so and stays.
// A development build, or a copy with no team, never updates itself.

const selfUpdateFile = "self-update.json"

// selfUpdateLimit bounds the download: the release's zip is about 100 MB.
const selfUpdateLimit = 1 << 30

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
	restart  func() error
	pause    time.Duration

	mu     sync.Mutex
	status wire.SelfUpdate
	// busy is a release being downloaded, checked or waited on; another named meanwhile
	// waits for it to end.
	busy bool
}

type selfUpdateState struct {
	updater *selfUpdater
}

type selfUpdateSettings struct {
	AutoUpdate bool `json:"autoUpdate"`
}

func readSelfUpdateSettings(path string) selfUpdateSettings {
	s := selfUpdateSettings{AutoUpdate: true}
	if b, err := os.ReadFile(path); err == nil {
		var m map[string]json.RawMessage
		if json.Unmarshal(b, &m) == nil {
			json.Unmarshal(m["autoUpdate"], &s.AutoUpdate)
		}
	}
	return s
}

func newSelfUpdater(file, app, running string) *selfUpdater {
	u := &selfUpdater{file: file, app: app, running: running, pause: 15 * time.Second,
		fetch: fetchTo, writable: folderWritable, ctx: context.Background()}
	u.status = wire.SelfUpdate{AutoUpdate: readSelfUpdateSettings(file).AutoUpdate, State: wire.SelfUpdateStateUpToDate, Running: running}
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
	b, _ := json.Marshal(selfUpdateSettings{AutoUpdate: r.AutoUpdate})
	if err := store.WriteAtomically(u.file, b, 0o600); err != nil {
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

// Named is machine/release: the release the control plane names. A newer one is taken up,
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
		// next start takes it away (cleanSelfUpdates).
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
	old := filepath.Join(work, "old.app")
	if err := os.Rename(u.app, old); err != nil {
		return fmt.Errorf("Agents Host could not move itself aside: %w", err)
	}
	if err := os.Rename(next, u.app); err != nil {
		os.Rename(old, u.app)
		return fmt.Errorf("Agents Host could not put the new copy in its place: %w", err)
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

// cleanSelfUpdates takes away what an update left beside the app: the old copy, which
// ran until the restart, or a download that a stop cut short.
func cleanSelfUpdates(app string) {
	matches, _ := filepath.Glob(filepath.Join(filepath.Dir(app), ".Agents Host.update-*"))
	for _, m := range matches {
		os.RemoveAll(m)
	}
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

// toldRelease is machine/release.
func (d *Daemon) toldRelease(params json.RawMessage) {
	var r wire.MachineRelease
	if err := json.Unmarshal(params, &r); err != nil {
		log.Printf("self-update: %s: %v", wire.NotifyMachineRelease.Name, err)
		return
	}
	if u := d.selfUpdateState.updater; u != nil {
		u.Named(r.Version)
	}
}
