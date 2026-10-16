package daemon

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"strings"
	"time"
)

// Date is a Swift Date as a bare JSONEncoder writes it: seconds since 2001-01-01.
type Date float64

const appleEpoch = 978307200

func Now() Date                { return FromTime(time.Now()) }
func FromTime(t time.Time) Date { return Date(float64(t.UnixNano())/1e9 - appleEpoch) }
func (d Date) Time() time.Time {
	return time.Unix(0, int64((float64(d)+appleEpoch)*1e9))
}

// NewUUID is upper case, as Swift writes UUIDs.
func NewUUID() string {
	b := make([]byte, 16)
	rand.Read(b)
	b[6] = b[6]&0x0f | 0x40
	b[8] = b[8]&0x3f | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:]))
}

type StartOptions struct {
	Values         map[string]any `json:"values"`
	ExtraArguments []string       `json:"extraArguments"`
}

type WorkReport struct {
	Outcome string `json:"outcome"`
	Message string `json:"message"`
	At      Date   `json:"at"`
}

// Agent is Model/Agent.swift, the fields this host fills.
type Agent struct {
	ID                string          `json:"id"`
	RuntimeID         string          `json:"runtimeID"`
	Cwd               string          `json:"cwd"`
	Title             string          `json:"title,omitempty"`
	State             string          `json:"state"`
	StartOptions      StartOptions    `json:"startOptions"`
	AdvertisedOptions json.RawMessage `json:"advertisedOptions"`
	AvailableCommands json.RawMessage `json:"availableCommands"`
	CreatedAt         Date            `json:"createdAt"`
	LastActivityAt    Date            `json:"lastActivityAt"`
	EndedReason       string          `json:"endedReason,omitempty"`
	Report            *WorkReport     `json:"report,omitempty"`
	RuntimeSessionID  string          `json:"runtimeSessionID,omitempty"`
	Plans             json.RawMessage `json:"plans,omitempty"`
	IsUnread          bool            `json:"isUnread,omitempty"`
	ArchivedAt        *Date           `json:"archivedAt,omitempty"`
	Usage             json.RawMessage `json:"usage,omitempty"`
	StartedByWorkflow string          `json:"startedByWorkflow,omitempty"`
	StartedByRun      string          `json:"startedByRun,omitempty"`
	Labels            json.RawMessage `json:"labels,omitempty"`
}

// Entry is a TranscriptEntry: kind is an object with one key, the case.
type Entry struct {
	ID   string         `json:"id"`
	At   Date           `json:"at"`
	Kind map[string]any `json:"kind"`
}

func entry(kind string, body any) Entry {
	return Entry{ID: NewUUID(), At: Now(), Kind: map[string]any{kind: body}}
}

type Project struct {
	Folder     string `json:"folder"`
	AddedAt    Date   `json:"addedAt"`
	ArchivedAt *Date  `json:"archivedAt,omitempty"`
}

type ProjectSummary struct {
	Project          Project        `json:"project"`
	Name             string         `json:"name"`
	Exists           bool           `json:"exists"`
	LastActivityAt   Date           `json:"lastActivityAt"`
	Counts           map[string]int `json:"counts"`
	CostToDate       map[string]any `json:"costToDate"`
	UnmeasuredAgents int            `json:"unmeasuredAgents"`
	RetiredCount     int            `json:"retiredCount"`
}

type PermissionOption struct {
	OptionID string `json:"optionID"`
	Name     string `json:"name"`
	Kind     string `json:"kind"`
}

type PermissionRequest struct {
	ID       string             `json:"id"`
	AgentID  string             `json:"agentID"`
	ToolCall map[string]any     `json:"toolCall"`
	Options  []PermissionOption `json:"options"`
	AskedAt  Date               `json:"askedAt"`
}

// group is Model/AgentGroup.swift's sidebar group, for a project's counts.
func (a *Agent) group() string {
	switch a.State {
	case "waitingOnUser":
		return "needsAttention"
	case "running", "starting", "queued":
		return "running"
	case "finished":
		if a.Report != nil && (a.Report.Outcome == "needs_answer" || a.Report.Outcome == "stuck" || a.Report.Outcome == "blocked") {
			return "needsAttention"
		}
		return "finished"
	case "archived":
		return "archived"
	}
	return "stopped"
}
