package daemon

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// Store keeps agents (agents/<id>/agent.json, transcript.jsonl) and projects.json in the
// root, as the Swift daemon lays them out, and every transcript in memory once read.
type Store struct {
	root string
	mu   sync.Mutex
	// agents by id, with their transcripts
	agents      map[string]*Agent
	transcripts map[string][]Entry
	projects    []Project
}

func OpenStore(root string) (*Store, error) {
	s := &Store{root: root, agents: map[string]*Agent{}, transcripts: map[string][]Entry{}}
	if err := os.MkdirAll(filepath.Join(root, "agents"), 0o700); err != nil {
		return nil, err
	}
	if b, err := os.ReadFile(filepath.Join(root, "projects.json")); err == nil {
		_ = json.Unmarshal(b, &s.projects)
	}
	dirs, _ := os.ReadDir(filepath.Join(root, "agents"))
	for _, d := range dirs {
		b, err := os.ReadFile(filepath.Join(root, "agents", d.Name(), "agent.json"))
		if err != nil {
			continue
		}
		var a Agent
		if json.Unmarshal(b, &a) != nil {
			continue
		}
		// A turn that was running when the daemon went is over.
		if a.State == "running" || a.State == "starting" || a.State == "waitingOnUser" {
			a.State, a.EndedReason = "stopped", "daemonGone"
		}
		s.agents[a.ID] = &a
		s.transcripts[a.ID] = readTranscript(filepath.Join(root, "agents", d.Name(), "transcript.jsonl"))
	}
	return s, nil
}

func readTranscript(file string) []Entry {
	f, err := os.Open(file)
	if err != nil {
		return nil
	}
	defer f.Close()
	var out []Entry
	r := bufio.NewScanner(f)
	r.Buffer(make([]byte, 1<<20), 64<<20)
	for r.Scan() {
		var e Entry
		if json.Unmarshal(r.Bytes(), &e) == nil {
			out = append(out, e)
		}
	}
	return out
}

func (s *Store) dir(id string) string { return filepath.Join(s.root, "agents", id) }

func (s *Store) SaveAgent(a *Agent) {
	s.mu.Lock()
	s.agents[a.ID] = a
	b, _ := json.Marshal(a)
	s.mu.Unlock()
	os.MkdirAll(s.dir(a.ID), 0o700)
	tmp := filepath.Join(s.dir(a.ID), ".agent.json.tmp")
	if os.WriteFile(tmp, b, 0o600) == nil {
		os.Rename(tmp, filepath.Join(s.dir(a.ID), "agent.json"))
	}
}

func (s *Store) Agent(id string) *Agent {
	s.mu.Lock()
	defer s.mu.Unlock()
	a := s.agents[strings.ToUpper(id)]
	if a == nil {
		return nil
	}
	c := *a
	return &c
}

// Append records an entry and returns its index.
func (s *Store) Append(id string, e Entry) int {
	s.mu.Lock()
	s.transcripts[id] = append(s.transcripts[id], e)
	n := len(s.transcripts[id]) - 1
	s.mu.Unlock()
	b, _ := json.Marshal(e)
	f, err := os.OpenFile(filepath.Join(s.dir(id), "transcript.jsonl"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err == nil {
		f.Write(append(b, '\n'))
		f.Close()
	}
	return n
}

func (s *Store) Transcript(id string) []Entry {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Entry(nil), s.transcripts[id]...)
}

// Agents, newest activity first.
func (s *Store) Agents() []Agent {
	s.mu.Lock()
	out := make([]Agent, 0, len(s.agents))
	for _, a := range s.agents {
		out = append(out, *a)
	}
	s.mu.Unlock()
	sort.Slice(out, func(i, j int) bool {
		if out[i].LastActivityAt != out[j].LastActivityAt {
			return out[i].LastActivityAt > out[j].LastActivityAt
		}
		return out[i].ID < out[j].ID
	})
	return out
}

func (s *Store) Projects() []Project {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]Project(nil), s.projects...)
}

func (s *Store) AddProject(folder string) Project {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, p := range s.projects {
		if p.Folder == folder {
			return p
		}
	}
	p := Project{Folder: folder, AddedAt: Now()}
	s.projects = append(s.projects, p)
	b, _ := json.Marshal(s.projects)
	os.WriteFile(filepath.Join(s.root, "projects.json"), b, 0o600)
	return p
}

func (s *Store) RemoveProject(folder string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var keep []Project
	for _, p := range s.projects {
		if p.Folder != folder {
			keep = append(keep, p)
		}
	}
	s.projects = keep
	b, _ := json.Marshal(s.projects)
	os.WriteFile(filepath.Join(s.root, "projects.json"), b, 0o600)
}
