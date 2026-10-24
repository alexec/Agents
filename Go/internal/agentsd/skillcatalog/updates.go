package skillcatalog

import (
	"context"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// Updates is whether a skill's source has moved on since it was added (SkillUpdates). Per
// source repository, at most once an hour: its HEAD from git's ref list, which costs
// nothing; and only when HEAD has moved past what was recorded, the tree at the new HEAD,
// one API request. A skill whose folder is the same at the new HEAD is current, and its
// recorded commit moves forward so the next check needs no request at all.
type Updates struct {
	GitHub  GitHub
	Sidecar string
	Cache   *UpdateCache
}

// UpdateCache is each source's last answer: its HEAD, and each folder's tree SHA there.
type UpdateCache struct {
	mu      sync.Mutex
	answers map[string]updateAnswer
}

type updateAnswer struct {
	at      time.Time
	head    string
	folders map[string]string
}

const updateInterval = time.Hour

// Check is the update state of each managed skill at place, by folder name.
func (u Updates) Check(ctx context.Context, managed map[string]wire.ManagedSkill, place Place, now time.Time) map[string]wire.UpdateState {
	out := map[string]wire.UpdateState{}
	side := LoadSidecar(u.Sidecar)
	bySource := map[string][]wire.ManagedSkill{}
	for _, m := range managed {
		bySource[strings.ToLower(m.Source)] = append(bySource[strings.ToLower(m.Source)], m)
	}
	unknown := wire.UpdateState{Unknown: &struct{}{}}
	for source, skills := range bySource {
		owner, repo, ok := GitHubSource(skills[0].Source)
		if !ok {
			continue
		}
		u.Cache.mu.Lock()
		if u.Cache.answers == nil {
			u.Cache.answers = map[string]updateAnswer{}
		}
		answer, had := u.Cache.answers[source]
		u.Cache.mu.Unlock()
		if !had || now.Sub(answer.at) > updateInterval {
			head, err := u.GitHub.Head(ctx, owner, repo)
			if err != nil {
				for _, s := range skills {
					out[s.Name] = unknown
				}
				continue
			}
			moved := false
			for _, s := range skills {
				if s.Commit == nil || *s.Commit != head.Commit {
					moved = true
				}
			}
			folders := map[string]string{}
			if moved {
				if tree, err := u.GitHub.Tree(ctx, owner, repo, head.Commit); err == nil {
					for _, e := range tree {
						if e.Type == "tree" {
							folders[e.Path] = e.SHA
						}
					}
				}
			}
			answer = updateAnswer{at: now, head: head.Commit, folders: folders}
			u.Cache.mu.Lock()
			u.Cache.answers[source] = answer
			u.Cache.mu.Unlock()
		}
		for _, s := range skills {
			key := SidecarKey(place.Destination, s.Name)
			if s.Commit != nil && *s.Commit == answer.head {
				out[s.Name] = wire.UpdateState{Current: &struct{}{}}
				continue
			}
			folder := ""
			if s.SkillPath != nil {
				folder = strings.Trim(strings.TrimSuffix(*s.SkillPath, "SKILL.md"), "/")
			}
			// What the folder was when it was added: the lock's tree SHA for a personal
			// skill, the sidecar's for a folder one.
			var was *string
			if place.LockKind == Personal {
				was = s.RecordedHash
			} else if r, ok := side.Skills[key]; ok {
				was = &r.TreeSHA
			}
			sha, ok := answer.folders[folder]
			switch {
			case !ok || was == nil:
				out[s.Name] = unknown
			case sha == *was:
				out[s.Name] = wire.UpdateState{Current: &struct{}{}}
				if r, ok := side.Skills[key]; ok {
					r.Commit = answer.head
					side.Skills[key] = r
				}
			default:
				out[s.Name] = wire.UpdateState{Available: &wire.UpdateStateAvailable{Commit: answer.head}}
			}
		}
	}
	side.Save(u.Sidecar)
	return out
}
