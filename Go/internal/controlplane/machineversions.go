package controlplane

import (
	"context"
	"encoding/json"
	"regexp"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// A machine's Agents versions (#5272, spec 5239-deploy-model, "What a target reports" and
// "Alex's question"): each host says its version in machine/hello, and a change of it is an
// observed deploy. The component is Agents (agentsd and, on a Mac, the app that carries it),
// the environment is the machines, and each machine is a target labelled machine=<host>.
// A deploy runs from the last time the old version was seen (its last hello, or the end of its
// uplink here) to the first hello at the new one, so "since when" is known to within the
// restart that an update makes.
//
// Each machine has one object, v1/machine-versions/<host>.json: the version it said last,
// when that was first and last seen, and the last mostMachineVersions deploys, newest first.
// Only the copy that holds a host writes it; a write is conditional in any case.

const (
	machineVersionsPrefix = "v1/machine-versions/"
	// mostMachineVersions bounds a machine's deploys: the oldest go first.
	mostMachineVersions = 20
	// agentsRepo is the repo Agents is built from, so a version's commit is a ref there.
	agentsRepo = "agentloops-dev/agent-loops"
)

// storedMachineVersions is one machine's object.
type storedMachineVersions struct {
	Version   string        `json:"version"`
	FirstSeen time.Time     `json:"firstSeen"`
	Seen      time.Time     `json:"seen"`
	Deploys   []wire.Deploy `json:"deploys"`
}

func machineVersionsKey(host string) string {
	return machineVersionsPrefix + strings.ToLower(host) + ".json"
}

// readMachineVersions is a machine's object and its tag, or none.
func (s *Service) readMachineVersions(ctx context.Context, host string) (*storedMachineVersions, string, error) {
	object, err := s.cfg.Store.Get(ctx, machineVersionsKey(host))
	if err != nil || object == nil {
		return nil, "", err
	}
	var stored storedMachineVersions
	if json.Unmarshal(object.Data, &stored) != nil {
		// A broken object starts again from the next hello.
		return nil, object.ETag, nil
	}
	return &stored, object.ETag, nil
}

// changeMachineVersions reads a machine's object, changes it and writes it if change says
// so, again once when another write came between.
func (s *Service) changeMachineVersions(ctx context.Context, host string, change func(*storedMachineVersions) bool) error {
	for try := 0; ; try++ {
		stored, tag, err := s.readMachineVersions(ctx, host)
		if err != nil {
			return err
		}
		when := store.Absent
		if tag != "" {
			when = store.Matching(tag)
		}
		if stored == nil {
			stored = &storedMachineVersions{}
		}
		if !change(stored) {
			return nil
		}
		data, err := json.Marshal(stored)
		if err != nil {
			return err
		}
		if _, err = s.cfg.Store.Put(ctx, machineVersionsKey(host), data, when); err == nil || !isConflict(err) || try > 0 {
			return err
		}
	}
}

// noteVersion is a machine's machine/hello at version, at now: the first hello at a new
// version keeps an observed deploy.
func (s *Service) noteVersion(ctx context.Context, host, version string, now time.Time) error {
	if strings.TrimSpace(version) == "" {
		return nil
	}
	return s.changeMachineVersions(ctx, host, func(m *storedMachineVersions) bool {
		switch {
		case m.Version == "":
			m.FirstSeen = now
		case m.Version != version:
			m.Deploys = append([]wire.Deploy{observedDeploy(host, version, m.Seen, now)}, m.Deploys...)
			if len(m.Deploys) > mostMachineVersions {
				m.Deploys = m.Deploys[:mostMachineVersions]
			}
			m.FirstSeen = now
		}
		m.Version, m.Seen = version, now
		return true
	})
}

// uplinkEnded is the router's word that a host's uplink here ended.
func (s *Service) uplinkEnded(host string) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := s.noteUplinkEnded(ctx, host, time.Now()); err != nil {
		s.log("could not keep when " + host + "'s version was last seen: " + err.Error())
	}
}

// noteUplinkEnded is the end of a host's uplink here: the version it said was seen until now.
func (s *Service) noteUplinkEnded(ctx context.Context, host string, now time.Time) error {
	return s.changeMachineVersions(ctx, host, func(m *storedMachineVersions) bool {
		if m.Version == "" || !now.After(m.Seen) {
			return false
		}
		m.Seen = now
		return true
	})
}

// machineVersions is machines/versions's answer.
func (s *Service) machineVersions(ctx context.Context, host string) (wire.MachineVersions, error) {
	out := wire.MachineVersions{Host: wire.MachineRef(host), Deploys: []wire.Deploy{}}
	stored, _, err := s.readMachineVersions(ctx, host)
	if err != nil {
		return out, fail(storeUnavailable, "The machine's versions could not be read: %v", err)
	}
	if stored == nil {
		if h := s.records.Host(host); h != nil {
			out.Version = h.Version
		}
		return out, nil
	}
	out.Version = stored.Version
	out.FirstSeen, out.Seen = optional(wire.DateOf(stored.FirstSeen)), optional(wire.DateOf(stored.Seen))
	if stored.Deploys != nil {
		out.Deploys = stored.Deploys
	}
	return out, nil
}

// observedDeploy is a machine's change to version, seen at from last at the old version and
// at to first at the new one. Its id is the machine and the time of the hello, as a machine
// can go back to a version it ran before.
func observedDeploy(host, version string, from, to time.Time) wire.Deploy {
	id := strings.ToLower(host) + "/" + strconv.FormatInt(to.UnixMilli(), 10)
	ref := wire.Ref{Provider: "agents", Type: "deploy", Topic: "machines", ID: id}.String()
	d := wire.Deploy{
		System: "agents", ID: id, Ref: &ref,
		Target: wire.DeployTarget{
			Component: wire.DeployComponent{Kind: optional("app"), System: "agents", ID: "agents",
				Name: optional("Agents"), Repo: optional(agentsRepo)},
			Environment: wire.DeployEnvironment{System: "agents", Name: "machines", Tier: wire.EnvironmentTierOther},
			Labels:      map[string]string{"machine": host},
		},
		Version:  agentsVersion(version),
		State:    wire.DeployStateSucceeded,
		RawState: "observed",
		Finished: optional(wire.DateOf(to)),
		Observed: optional(true),
	}
	if !from.IsZero() {
		d.Started = optional(wire.DateOf(from))
	}
	return d
}

var (
	// taggedVersion is a build on a tag, X.Y.Z, and devVersion one after it, X.Y.Z-dev.N+g<sha>
	// (scripts/version.sh).
	taggedVersion = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+$`)
	devVersion    = regexp.MustCompile(`^[0-9]+\.[0-9]+\.[0-9]+-dev\.[0-9]+\+g([0-9a-f]{7,40})$`)
)

// agentsVersion is a version as the model's: named by the version, its one artifact the
// commit it was built from (the tag for X.Y.Z, the sha after +g), so the changes between two
// versions are the forge's compare of their commits. A version of another form has no commit.
func agentsVersion(version string) wire.DeployVersion {
	v := wire.DeployVersion{Name: optional(version), Artifacts: []wire.DeployArtifact{}}
	commit := ""
	if taggedVersion.MatchString(version) {
		commit = "v" + version
		ref := wire.Ref{Provider: "github", Type: "release", Topic: agentsRepo, ID: commit}.String()
		v.Ref = &ref
	} else if m := devVersion.FindStringSubmatch(version); m != nil {
		commit = m[1]
	}
	if commit != "" {
		ref := wire.Ref{Provider: "github", Type: "artifact", Topic: agentsRepo, ID: commit}.String()
		v.Artifacts = append(v.Artifacts, wire.DeployArtifact{Kind: "commit", System: "github", ID: commit, Ref: &ref})
	} else {
		v.Artifacts = append(v.Artifacts, wire.DeployArtifact{Kind: "version", System: "agents", ID: version})
	}
	return v
}
