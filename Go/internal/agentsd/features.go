package agentsd

import (
	"context"
	"log"
	"path/filepath"
	"sort"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/safe"
	"github.com/alexec/agents/Go/wire"
)

// Which features are used (#2165, specs/2165-feature-counts): a count per day, method and
// client, never what a call said. It stays on this machine, in <root>/features-history.json,
// for 90 days. Only a method this host serves or an app tool is counted, and only five
// clients, so the file is bounded by 90 days × the methods × 5, whatever a caller sends.

const (
	featuresDaysKept = 90
	featuresWeek     = 7
	// featuresSaveEvery is how often the counts go to disk when they changed: a call is
	// counted in memory, never written at once, so a busy host does not write at each call.
	featuresSaveEvery = time.Minute
)

// The clients a use is counted for.
const (
	featureMac      = "mac"
	featureRemote   = "remote"
	featureWeb      = "web"
	featureAgent    = "agent"
	featureWorkflow = "workflow"
)

// featuresFile is features-history.json: day → method → client → uses.
type featuresFile struct {
	Days map[string]map[string]map[string]int64 `json:"days"`
}

type featureBook struct {
	featureMu    sync.Mutex
	features     *featuresFile
	featureDirty bool
}

func (d *Daemon) featuresPath() string {
	return filepath.Join(d.Store.Loc.Root, "features-history.json")
}

// featuresLocked is the counts, read once; a file that cannot be read starts again.
func (d *Daemon) featuresLocked() *featuresFile {
	if d.features == nil {
		d.features = &featuresFile{}
		readStore(d.featuresPath(), d.features, "the feature counts start again")
		if d.features.Days == nil {
			d.features.Days = map[string]map[string]map[string]int64{}
		}
	}
	return d.features
}

// countFeature counts one use of method by client today.
func (d *Daemon) countFeature(method, client string) {
	if method == "" || client == "" {
		return
	}
	today := dayStamp(time.Now())
	d.featureMu.Lock()
	defer d.featureMu.Unlock()
	f := d.featuresLocked()
	day := f.Days[today]
	if day == nil {
		day = map[string]map[string]int64{}
		f.Days[today] = day
		keepNewest(f.Days, featuresDaysKept, today)
	}
	if day[method] == nil {
		day[method] = map[string]int64{}
	}
	day[method][client]++
	d.featureDirty = true
}

// countCall counts a socket call that was answered, as the client its connection is.
// A stranger's and a pairing phone's calls are not a feature anyone chose.
func (d *Daemon) countCall(c *Client, method string) {
	if _, served := d.handlers[method]; served {
		d.countFeature(method, d.featureClient(c))
	}
}

// featureClient is which client a connection is: an agent's helper, a phone or an iPad
// (a device this Mac paired), a browser (any other device, or the page this host
// carries), else the Mac's own window.
func (d *Daemon) featureClient(c *Client) string {
	switch c.Role {
	case RoleAgent:
		return featureAgent
	case RoleControl, RoleDevice:
	case RoleHostApp, RoleWindow:
		return featureMac
	default:
		return ""
	}
	if _, page := c.conn.(*pageChannel); page {
		return featureWeb
	}
	d.devMu.Lock()
	defer d.devMu.Unlock()
	b, _ := d.callerDevice(c)
	if b == nil || b.device == "" {
		if c.Role == RoleDevice {
			return featureRemote
		}
		return featureMac
	}
	d.loadDevices()
	for _, r := range d.devRecords {
		if r.ID == b.device && (r.Kind == wire.DeviceKindIPhone || r.Kind == wire.DeviceKindIPad) {
			return featureRemote
		}
	}
	return featureWeb
}

// countAppTool counts an agent's call to an app tool: a workflow's when a workflow
// started the agent.
func (d *Daemon) countAppTool(agent wire.UUID, tool string) {
	client := featureAgent
	if a := d.Store.Agent(agent); a != nil && a.StartedByWorkflow != nil {
		client = featureWorkflow
	}
	d.countFeature(appToolMethod(tool), client)
}

// saveFeaturesEveryMinute writes the counts when they changed, and once more when the
// host stops.
func (d *Daemon) saveFeaturesEveryMinute() {
	safe.Go("feature counts", func() {
		tick := time.NewTicker(featuresSaveEvery)
		defer tick.Stop()
		for {
			select {
			case <-d.ctx.Done():
				d.saveFeatures()
				return
			case <-tick.C:
				d.saveFeatures()
			}
		}
	})
}

func (d *Daemon) saveFeatures() {
	d.featureMu.Lock()
	defer d.featureMu.Unlock()
	if !d.featureDirty || d.features == nil {
		return
	}
	if err := writeStore(d.featuresPath(), d.features); err != nil {
		log.Printf("features-history.json: could not save: %v", err)
		return
	}
	d.featureDirty = false
}

// featureNames is every feature that can be counted: the methods this host serves and the
// app tools' methods.
func (d *Daemon) featureNames() map[string]bool {
	names := make(map[string]bool, len(d.handlers)+len(appToolMethods))
	for m := range d.handlers {
		names[m] = true
	}
	for _, t := range appToolCalls() {
		names[appToolMethod(t.name)] = true
	}
	return names
}

// featureUsage is reports/features: each feature with its uses in the last 7 and 90 days
// and the clients that used it, the least used first. A feature never used is in it too.
func (d *Daemon) featureUsage(now time.Time) wire.FeatureUsage {
	week := map[string]bool{}
	for i := range featuresWeek {
		week[dayStamp(now.AddDate(0, 0, -i))] = true
	}
	oldest := dayStamp(now.AddDate(0, 0, -(featuresDaysKept - 1)))
	type tally struct {
		week, quarter int64
		clients       map[string]bool
		last          string
	}
	names := d.featureNames()
	tallies := make(map[string]*tally, len(names))
	for m := range names {
		tallies[m] = &tally{clients: map[string]bool{}}
	}
	d.featureMu.Lock()
	f := d.featuresLocked()
	since := ""
	for day, methods := range f.Days {
		if day < oldest {
			continue
		}
		if since == "" || day < since {
			since = day
		}
		for m, clients := range methods {
			t := tallies[m]
			if t == nil {
				continue // a method an earlier build served
			}
			for client, n := range clients {
				t.quarter += n
				if week[day] {
					t.week += n
				}
				if n > 0 {
					t.clients[client] = true
				}
			}
			if day > t.last {
				t.last = day
			}
		}
	}
	d.featureMu.Unlock()
	out := wire.FeatureUsage{Days: featuresDaysKept, Features: make([]wire.FeatureUse, 0, len(tallies))}
	if since != "" {
		out.Since = &since
	}
	for m, t := range tallies {
		u := wire.FeatureUse{Method: m, Week: t.week, Quarter: t.quarter, Clients: make([]string, 0, len(t.clients))}
		for c := range t.clients {
			u.Clients = append(u.Clients, c)
		}
		sort.Strings(u.Clients)
		if t.last != "" {
			u.LastUsed = &t.last
		}
		out.Features = append(out.Features, u)
	}
	sort.Slice(out.Features, func(i, j int) bool {
		a, b := out.Features[i], out.Features[j]
		if a.Quarter != b.Quarter {
			return a.Quarter < b.Quarter
		}
		if a.Week != b.Week {
			return a.Week < b.Week
		}
		return a.Method < b.Method
	})
	return out
}

func (d *Daemon) registerFeatures() {
	On(d, wire.CallReportsFeatures, func(_ context.Context, _ *Client, _ wire.Empty) (wire.FeatureUsage, error) {
		return d.featureUsage(time.Now()), nil
	})
}
