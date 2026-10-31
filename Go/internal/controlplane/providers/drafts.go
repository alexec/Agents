package providers

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// The writer's tools (AppTool).
const (
	ToolReadTools  = "read_tools"
	ToolReadHelp   = "read_help"
	ToolCheckDraft = "check_draft"
	ToolProveStart = "prove_start"
	ToolProveStop  = "prove_stop"
	ToolSendDraft  = "send_draft"
	ToolGiveUp     = "give_up"
)

// ProviderDraftStart is DaemonAPI.ProviderDraftStart: providers/draftStart. Form is the
// form so far (for Your commands, kind is commands and cli is set); Secrets, name to value,
// are typed in the sheet and held in memory for the draft only; Provider, in Edit…, is the
// provider whose map or commands are written again (US4).
type ProviderDraftStart = wire.ProviderDraftStart

// ProviderDraftStarted is DaemonAPI.ProviderDraftStarted.
type ProviderDraftStarted = wire.ProviderDraftStarted

// DraftAnswered is DaemonAPI.ProviderDraftStarted.Answered: answered with no agent (R8),
// with the shipped map that fits, or the preset whose CLI this is.
type DraftAnswered = wire.ProviderDraftAnswered

// ProviderDraftRequest is DaemonAPI.ProviderDraftRequest: providers/draftCancel.
type ProviderDraftRequest = wire.ProviderDraftRequest

// ProviderDraftAnswer is DaemonAPI.ProviderDraftAnswer: providers/draftAnswer.
type ProviderDraftAnswer = wire.ProviderDraftAnswer

// ProviderRuntimes is DaemonAPI.ProviderRuntimes: providers/runtimes. Host is the host the
// agent runs on, by name; Why, why none can write here.
type ProviderRuntimes = wire.ProviderRuntimes

// ProviderRuntime is DaemonAPI.ProviderRuntimes.Runtime.
type ProviderRuntime = wire.ProviderRuntime

// Step kinds (DaemonAPI.DraftStep.Kind).
const (
	StepRead  = "read"
	StepHelp  = "help"
	StepCheck = "check"
	StepAsk   = "ask"
	StepProve = "prove"
	StepNote  = "note"
)

// DraftStep is DaemonAPI.DraftStep: one thing a draft did, redacted.
type DraftStep = wire.DraftStep

// DraftCheck is DaemonAPI.DraftCheck: a draft's last check. SSH is what ssh -G resolved
// one workspace's destination to, in words; NoSSH, that the draft gives no ssh destination
// (#975).
type DraftCheck = wire.DraftCheck

// DraftQuestion is DaemonAPI.DraftQuestion: a question for the person in the sheet. Kind is
// start, stop or check; Text is worded whole ("Claude wants to start scratch-1 on
// DigitalOcean to prove the map."); Yes is Start It, Stop It or Run Check.
type DraftQuestion = wire.DraftQuestion

// DraftUpdate is DaemonAPI.ProviderDraftUpdate: control/providerDraft, where a draft
// stands, sent on every step and change. State is reading, writing, checking, asking,
// proving, done, failed or cancelled; Note, in done the agent's note, in failed the reason.
type DraftUpdate = wire.ProviderDraftUpdate

// Ended says the draft has ended.
func Ended(u DraftUpdate) bool {
	return u.State == "done" || u.State == "failed" || u.State == "cancelled"
}

// MachineProviderDraftCall is DaemonAPI.MachineProviderDraftCall: a writer's tool call, relayed
// by its host. AgentID is the caller, which is checked against the draft's agent (FR-011).
type MachineProviderDraftCall = wire.MachineProviderDraftCall

// StartRequest is DaemonAPI.StartRequest, as a writing agent's start sends it.
type StartRequest = wire.StartRequest

// PurposeDraft is AgentPurpose.providerDraft's id, or "".
func PurposeDraft(s StartRequest) string {
	if s.Purpose == nil || s.Purpose.ProviderDraft == nil {
		return ""
	}
	return string(s.Purpose.ProviderDraft.ID)
}

// Help is ProviderDrafts.Help: what a CLI's help printed.
type Help struct {
	Status int
	Text   string
}

// NotInstalled is the shell's word for a command it cannot find.
func (h Help) NotInstalled() bool { return h.Status == 127 }

// LocalHost is ProviderDrafts.LocalHost: the host on this control plane's machine, which
// runs the agent (research R1).
type LocalHost struct {
	ID   string
	Name string
}

// DraftTiming is ProviderDrafts.Timing.
type DraftTiming struct {
	// How long a draft has, less the time spent asking and proving (FR-017).
	Total time.Duration
	// How long a question waits for the person before it is a no (FR-019).
	Answer time.Duration
	// How long the agent has, once the time is over, to send its best draft.
	LastWord time.Duration
	// How long a draft lives once its sheet has gone (R9).
	OwnerGone time.Duration
	// How long an ended draft is kept, for Add to mark the record writtenBy.
	KeptAfter time.Duration
	// How often the clock and the owner are looked at.
	Tick time.Duration
	Help time.Duration
}

// StandardDraftTiming is ProviderDrafts.Timing.standard.
var StandardDraftTiming = DraftTiming{Total: 300 * time.Second, Answer: 120 * time.Second, LastWord: 60 * time.Second,
	OwnerGone: 30 * time.Second, KeptAfter: 600 * time.Second, Tick: time.Second, Help: 25 * time.Second}

// DraftHooks is ProviderDrafts.Hooks: what the executable does for it.
type DraftHooks struct {
	// Connect is a connection to a provider as a record says, with its secrets.
	Connect func(record ProviderRecord, secrets map[string]string) (Provider, error)
	// Help is ‹cli› ‹words…› --help where the control plane runs, the secrets as environment.
	Help func(cli string, words []string, secrets map[string]string) Help
	// LocalHost is the host on this machine, online; nil when there is none.
	LocalHost func() *LocalHost
	// StartAgent starts the writing agent on host, as the sheet's client: its id.
	StartAgent func(host string, request StartRequest, owner Caller) (string, error)
	StopAgent  func(host, agent string, owner Caller)
	// Notify tells the sheet; false when its session has gone.
	Notify func(owner Caller, update DraftUpdate) bool
	// OwnerHere says the sheet's session is still here.
	OwnerHere func(owner Caller) bool
	// BusyHost is the host with agents working that a provider's workspace runs, by name;
	// "" for none (FR-020).
	BusyHost func(provider, workspace string) string
	// SSHConfig is ssh -G ‹destination› where the control plane runs (#975); nil when ssh
	// could not say.
	SSHConfig func(destination string) *Help
}

// ExistingProvider is the provider whose map or commands are written again, in Edit… (US4).
type ExistingProvider struct {
	Record  ProviderRecord
	Secrets map[string]string
	// Its last list's failure, "" for none.
	Problem string
}

// The limits a draft has (FR-017).
const (
	MaxChecks = 8
	MaxCalls  = 40
	maxSteps  = 100
	// What the agent is given of one output (FR-015).
	cutBytes = 16 * 1024
)

// OverWords is ProviderDrafts.overWords: the answer every tool gives once the time is over.
const OverWords = "The time for this draft is over: send your best draft with send_draft, or give_up."

// NotYoursWords is ProviderDrafts.notYoursWords.
const NotYoursWords = "This tool is for the agent writing that provider's map."

// presets is ProviderDrafts.presets: the CLIs Agents has a preset for, and the preset.
var presets = map[string][2]string{
	"docker": {"docker", "Docker Containers"}, "doctl": {"doctl", "DigitalOcean Droplets"},
	"gh": {"codespaces", "GitHub Codespaces"}, "coder": {"coder", "Coder Workspaces"},
	"gcloud": {"gcloud-workstations", "Google Cloud Workstations"},
}

// runtimeNames is RuntimeCatalog's names, for the words.
var runtimeNames = map[string]string{"claude": "Claude", "grok": "Grok", "copilot": "Copilot", "cursor": "Cursor",
	"codex": "Codex", "gemini": "Gemini", "antigravity": "Antigravity", "opencode": "OpenCode"}

// WriterRuntimes is ToolPolicyCatalog.writerRuntimes: the runtimes whose own tools can be
// turned off for one session, so they can write.
var WriterRuntimes = []string{"claude"}

func runtimeName(id string) string {
	if name, ok := runtimeNames[id]; ok {
		return name
	}
	return id
}

// ShippedDigitalOceanMap is ShippedToolMaps.digitalOcean (#691 FR-072).
var ShippedDigitalOceanMap = mustParse(`{
  "list": {"tool": "droplet-list", "arguments": {"PerPage": 200},
           "items": "droplets", "id": "id", "name": "name", "state": "status",
           "ssh": "root@{networks.v4[0].ip_address}", "cost": "${size.price_hourly}/hour while running",
           "states": {"active": "running", "new": "starting", "off": "stopped", "archive": "stopped"}},
  "start": {"tool": "power-on-droplet", "arguments": {"ID": "{id:number}"}},
  "stop": {"tool": "power-off-droplet", "arguments": {"ID": "{id:number}"}},
  "delete": {"tool": "droplet-delete", "arguments": {"ID": "{id:number}"}}
}`)

func mustParse(text string) any {
	v, err := parseJSON([]byte(text))
	if err != nil {
		panic(err)
	}
	return v
}

// draft is ProviderDrafts.Draft. Every field past redact is guarded by Drafts.mu.
type draft struct {
	id          string
	owner       Caller
	form        ProviderAdd
	secrets     map[string]string
	provider    string
	runtimeID   string
	runtimeName string
	redact      Redaction

	host     string
	agent    string
	state    string
	steps    []DraftStep
	sent     any
	passed   any
	check    *DraftCheck
	question *DraftQuestion
	waiter   chan bool
	note     string
	checks   int
	calls    int
	// Time used, less asking and proving.
	used           time.Duration
	paused         bool
	over           bool
	overSince      *time.Time
	ownerGoneSince *time.Time
	ended          bool
	tools          []any
	helpSeen       string
	workspaces     []MachineInfo
	stop           chan struct{}
}

func (d *draft) isCommands() bool { return d.form.Kind == KindCommands }

func (d *draft) cli() string {
	if d.form.CLI == nil {
		return ""
	}
	return trimSpaces(*d.form.CLI)
}

// best is the result as it stands: the last sent, or the last that passed.
func (d *draft) best() any {
	if d.sent != nil {
		return d.sent
	}
	return d.passed
}

// Drafts is ProviderDrafts (#858, plan.md): each draft of a provider's tool map or
// commands, held in memory while an agent on this control plane's own host writes it. The
// control plane does everything that touches the server, the CLI or a secret, and asks the
// person before a start, a stop or a check that may change something. The agent sees each
// answer with every secret's value replaced by its name (FR-022).
type Drafts struct {
	timing DraftTiming
	hooks  DraftHooks
	log    func(string)
	// The clock the time limits read; a test gives its own (#891).
	now func() time.Time

	mu     sync.Mutex
	drafts map[string]*draft
}

// NewDrafts is ProviderDrafts.init. now is nil for the real clock.
func NewDrafts(timing DraftTiming, hooks DraftHooks, log func(string), now func() time.Time) *Drafts {
	if log == nil {
		log = func(string) {}
	}
	if now == nil {
		now = time.Now
	}
	if hooks.BusyHost == nil {
		hooks.BusyHost = func(string, string) string { return "" }
	}
	if hooks.SSHConfig == nil {
		hooks.SSHConfig = func(string) *Help { return nil }
	}
	return &Drafts{timing: timing, hooks: hooks, log: log, now: now, drafts: map[string]*draft{}}
}

func refusal(format string, args ...any) *Failure { return invalid(format, args...) }

// MARK: The sheet's methods

// Runtimes is ProviderDrafts.runtimes: the runtimes that can write here.
func (s *Drafts) Runtimes() ProviderRuntimes {
	host := s.hooks.LocalHost()
	if host == nil {
		return ProviderRuntimes{Runtimes: []ProviderRuntime{}, Why: new("No host runs where the control plane runs, so no agent can write here.")}
	}
	out := ProviderRuntimes{Runtimes: []ProviderRuntime{}, Host: &host.Name}
	for i, id := range WriterRuntimes {
		out.Runtimes = append(out.Runtimes, ProviderRuntime{ID: id, Name: runtimeName(id), IsDefault: i == 0})
	}
	if len(out.Runtimes) == 0 {
		out.Why = new("No runtime here can write with its own tools turned off.")
	}
	return out
}

var cliPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]*$`)

// Start is ProviderDrafts.start: providers/draftStart, the cheap answers first (R8), then
// the agent. existing is the provider's record and secrets in Edit… (US4).
func (s *Drafts) Start(request ProviderDraftStart, owner Caller, existing *ExistingProvider) (ProviderDraftStarted, error) {
	secrets := map[string]string{}
	if existing != nil {
		for k, v := range existing.Secrets {
			secrets[k] = v
		}
	}
	for k, v := range request.Secrets {
		if v != "" {
			secrets[k] = v
		}
	}
	if !contains(WriterRuntimes, request.RuntimeID) {
		return ProviderDraftStarted{}, refusal("%s can’t write here: its own tools can’t be turned off for one session.",
			runtimeName(request.RuntimeID))
	}
	id := records.NewUUID()
	d := &draft{id: id, owner: owner, form: request.Form, secrets: secrets, provider: string(deref(request.Provider)),
		runtimeID: request.RuntimeID, runtimeName: runtimeName(request.RuntimeID), redact: NewRedaction(secrets),
		state: "reading", stop: make(chan struct{})}
	// What it starts from: the tools, or the CLI's own help.
	var seed string
	if d.isCommands() {
		cli := d.cli()
		if !cliPattern.MatchString(cli) {
			if cli == "" {
				return ProviderDraftStarted{}, refusal("Give the CLI its commands use.")
			}
			return ProviderDraftStarted{}, refusal("“%s” isn’t a program’s name.", cli)
		}
		program := path.Base(cli)
		if preset, ok := presets[program]; ok {
			return ProviderDraftStarted{Draft: wire.UUID(id), Answered: &DraftAnswered{
				Note: "Agents has a preset for " + program + ": use " + preset[1] + ".", Preset: optional(preset[0])}}, nil
		}
		help := s.hooks.Help(cli, []string{}, secrets)
		if help.NotInstalled() {
			return ProviderDraftStarted{}, refusal("%s isn’t installed where the control plane runs.", cli)
		}
		d.helpSeen = help.Text
		seed = d.redact.Text(cut(help.Text))
		d.steps = append(d.steps, DraftStep{At: *dateOf(time.Now()), Kind: StepHelp, Text: "ran " + cli + " --help"})
	} else {
		connection, err := s.hooks.Connect(draftRecord(d, nil), secrets)
		var tools []any
		if err == nil {
			tools, err = connection.Tools()
			go connection.End()
		}
		if err != nil {
			return ProviderDraftStarted{}, refusal("%s", d.redact.Text(errorWords(err)))
		}
		var names []string
		for _, t := range tools {
			if n, ok := str(get(t, "name")); ok {
				names = append(names, n)
			}
		}
		all := true
		for _, r := range RequiredTools {
			all = all && contains(names, r)
		}
		if all {
			return ProviderDraftStarted{Draft: wire.UUID(id), Answered: &DraftAnswered{Note: "It follows the contract: it needs no map."}}, nil
		}
		if shipped, err := MapFrom(ShippedDigitalOceanMap); err == nil && shipped.Missing(names) == "" {
			return ProviderDraftStarted{Draft: wire.UUID(id), Answered: &DraftAnswered{Note: "Agents ships this map.", Map: jsonValue(ShippedDigitalOceanMap)}}, nil
		}
		d.tools = tools
		seed = toolsText(tools, d.redact)
		plural := "s"
		if len(tools) == 1 {
			plural = ""
		}
		d.steps = append(d.steps, DraftStep{At: *dateOf(time.Now()), Kind: StepRead, Text: fmt.Sprintf("read %d tool%s", len(tools), plural)})
	}
	host := s.hooks.LocalHost()
	if host == nil {
		return ProviderDraftStarted{}, refusal("No host runs where the control plane runs, so no agent can write here.")
	}
	d.host = host.ID
	s.mu.Lock()
	s.drafts[id] = d
	s.mu.Unlock()
	var old *oldDraft
	if existing != nil {
		old = &oldDraft{json: existingJSON(existing.Record), problem: existing.Problem}
	}
	// As ProviderDrafts.start writes it: DaemonAPI.StartRequest with its defaults.
	start := StartRequest{RuntimeID: request.RuntimeID, Cwd: "file:///", Prompt: prompt(d, seed, old),
		Attachments: []wire.Attachment{}, StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}},
		AdditionalDirectories: []wire.URL{}, McpServers: []wire.MCPServer{}, Labels: []string{},
		RequestID: new(wire.UUID(records.NewUUID())), Sandbox: new(wire.SandboxChoiceOn),
		Purpose: &wire.AgentPurpose{ProviderDraft: &wire.AgentPurposeProviderDraft{ID: wire.UUID(id)}}}
	agent, err := s.hooks.StartAgent(host.ID, start, owner)
	if err != nil {
		s.mu.Lock()
		delete(s.drafts, id)
		s.mu.Unlock()
		return ProviderDraftStarted{}, refusal("%s", d.redact.Text(errorWords(err)))
	}
	s.mu.Lock()
	d.agent = uuidOf(agent)
	if d.agent == "" {
		d.agent = agent
	}
	d.state = "writing"
	s.mu.Unlock()
	what := "a tool map"
	if d.isCommands() {
		what = "commands for " + d.cli()
	}
	s.log(fmt.Sprintf("provider draft %s: %s writing %s on %s", shortID(id), d.runtimeName, what, host.Name))
	go s.watch(d)
	s.tell(d)
	return ProviderDraftStarted{Draft: wire.UUID(id)}, nil
}

// Cancel is providers/draftCancel: ×, Back and Cancel.
func (s *Drafts) Cancel(id string, owner Caller) {
	s.mu.Lock()
	d := s.drafts[strings.ToUpper(id)]
	s.mu.Unlock()
	if d == nil || !strings.EqualFold(d.owner.Client, owner.Client) {
		return
	}
	s.end(d, "cancelled", "")
}

// Answer is providers/draftAnswer.
func (s *Drafts) Answer(answer ProviderDraftAnswer, owner Caller) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.drafts[strings.ToUpper(string(answer.Draft))]
	if d == nil || !strings.EqualFold(d.owner.Client, owner.Client) {
		return refusal("That draft has ended.")
	}
	if d.question == nil || !strings.EqualFold(string(d.question.ID), string(answer.Question)) || d.waiter == nil {
		return refusal("That question was answered already.")
	}
	d.waiter <- answer.Yes
	d.waiter = nil
	return nil
}

// Result is ProviderDrafts.result: a done draft's runtime and map or commands, for
// providers/add to mark its record writtenBy.
func (s *Drafts) Result(id string) (string, any, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d := s.drafts[strings.ToUpper(id)]
	if d == nil || d.state != "done" || d.best() == nil {
		return "", nil, false
	}
	return d.runtimeID, d.best(), true
}

// MARK: The writer's tools

// Call is ProviderDrafts.call: a writer's tool, from its host (host/providerDraft).
func (s *Drafts) Call(host string, call MachineProviderDraftCall) (any, error) {
	s.mu.Lock()
	d := s.drafts[strings.ToUpper(string(call.Draft))]
	s.mu.Unlock()
	if d == nil || !strings.EqualFold(d.agent, string(call.AgentID)) || d.host != host {
		return nil, fail(CodeNotPermitted, "%s", NotYoursWords)
	}
	// As the wire gives it: a JSON value (objects map[string]any, arrays []any), however
	// the caller built it.
	arguments := toValue(call.Arguments)
	if arguments == nil {
		arguments = map[string]any{}
	}
	if call.Tool == "turn_ended" {
		s.turnEnded(d, strOr(get(arguments, "reason")))
		return map[string]any{}, nil
	}
	note := s.tool(d, call.Tool, arguments)
	return map[string]any{"note": d.redact.Text(note)}, nil
}

func (s *Drafts) tool(d *draft, name string, arguments any) string {
	s.mu.Lock()
	if d.ended {
		s.mu.Unlock()
		return "This draft has ended."
	}
	d.calls++
	final := name == ToolSendDraft || name == ToolGiveUp
	if d.calls > MaxCalls || (name == ToolCheckDraft && d.checks >= MaxChecks) {
		s.markOverLocked(d)
	}
	over := d.over
	s.mu.Unlock()
	if over && !final {
		return OverWords
	}
	switch name {
	case ToolReadTools:
		if d.isCommands() {
			return "This draft is for a CLI: use read_help."
		}
		return toolsText(d.tools, d.redact)
	case ToolReadHelp:
		return s.readHelp(d, arguments)
	case ToolCheckDraft:
		return s.check(d, get(arguments, "draft"))
	case ToolProveStart, ToolProveStop:
		return s.prove(d, name == ToolProveStart, arguments)
	case ToolSendDraft:
		given := get(arguments, "draft")
		if _, ok := obj(given); !ok {
			return "Send the draft as a JSON object in `draft`."
		}
		if problem := draftProblem(given, d.isCommands()); problem != "" {
			return "Not sent: " + problem
		}
		s.mu.Lock()
		d.sent = given
		s.mu.Unlock()
		note := ""
		if n, ok := str(get(arguments, "note")); ok {
			note = d.redact.Text(lines(n, 3))
		}
		s.end(d, "done", note)
		return "Sent. End your turn now."
	case ToolGiveUp:
		reason := "It gave up."
		if r, ok := str(get(arguments, "reason")); ok {
			reason = lines(r, 3)
		}
		s.end(d, "failed", d.redact.Text(reason))
		return "Ended."
	}
	return "No tool called " + name + "."
}

func (s *Drafts) readHelp(d *draft, arguments any) string {
	if !d.isCommands() {
		return "This draft is for an MCP server: use read_tools."
	}
	words := []string{}
	if given, ok := arr(get(arguments, "words")); ok {
		for _, w := range given {
			if word, ok := str(w); ok {
				words = append(words, word)
			}
		}
	}
	s.mu.Lock()
	seen := d.helpSeen
	s.mu.Unlock()
	if refused := HelpWords(words, seen); refused != "" {
		return "Not run: " + refused
	}
	help := s.hooks.Help(d.cli(), words, d.secrets)
	s.mu.Lock()
	d.helpSeen += "\n" + help.Text
	s.mu.Unlock()
	s.step(d, StepHelp, "ran "+strings.Join(append([]string{d.cli()}, words...), " ")+" --help")
	if help.Text == "" {
		return cut(fmt.Sprintf("(It printed nothing, and exited %d.)", help.Status))
	}
	return cut(help.Text)
}

func (s *Drafts) check(d *draft, given any) string {
	if _, ok := obj(given); !ok {
		return "Give the draft as a JSON object in `draft`."
	}
	if problem := draftProblem(given, d.isCommands()); problem != "" {
		return "Failed: " + problem
	}
	var verdict Verdict
	if d.isCommands() {
		verdict = CommandsVerdict(given, d.cli())
	} else {
		verdict = ListTool(given, d.tools)
	}
	if verdict != Run {
		what, kind := "its list", "map"
		if d.isCommands() {
			kind = "commands"
		} else if tool, ok := str(get(get(given, "list"), "tool")); ok {
			what = tool
		} else {
			what = "its list tool"
		}
		yes := s.ask(d, DraftQuestion{Kind: "check", Yes: "Run Check",
			Text: fmt.Sprintf("%s wants to run %s to check the %s. It isn’t on the safe list because %s.", d.runtimeName, what, kind, verdict.Ask)})
		if !yes {
			s.step(d, StepAsk, "check not run: the person said no")
			return "The person said no to this check (" + verdict.Ask + "). Write a list that is plainly a list, or send the draft unchecked with a note."
		}
	}
	s.mu.Lock()
	d.checks++
	d.state = "checking"
	s.mu.Unlock()
	s.tell(d)
	var checked Checked
	connection, err := s.hooks.Connect(draftRecord(d, given), d.secrets)
	if err == nil {
		checked, err = connection.Check()
		connection.End()
	}
	s.mu.Lock()
	d.state = "writing"
	s.mu.Unlock()
	if err != nil {
		words := d.redact.Text(errorWords(err))
		s.mu.Lock()
		d.check = &DraftCheck{Passed: false, Problem: &words}
		s.mu.Unlock()
		s.step(d, StepCheck, "check failed: "+words)
		return "Failed: " + words
	}
	s.mu.Lock()
	d.passed = given
	d.workspaces = checked.Workspaces
	d.check = &DraftCheck{Passed: true, Workspaces: checked.Workspaces}
	s.mu.Unlock()
	n := len(checked.Workspaces)
	s.step(d, StepCheck, fmt.Sprintf("checked: listed %d", n))
	answer := fmt.Sprintf("Passed: listed %d.\n", n)
	var rows []string
	for _, w := range checked.Workspaces {
		rows = append(rows, workspaceLine(w))
	}
	answer += strings.Join(rows, "\n")
	if checked.Items > n && checked.FirstItem != nil {
		answer += fmt.Sprintf("\n%d of the %d items at list.items have no id or name by this map. The first item:\n", checked.Items-n, checked.Items) +
			d.redact.Text(sample(checked.FirstItem))
	}
	// ssh, which Add as Host… and an ssh start need (#975): tested, or said to be missing.
	resolved := ""
	noSSH := !hasSSH(given, d.isCommands())
	if n > 0 {
		noSSH = true
		for _, w := range checked.Workspaces {
			noSSH = noSSH && deref(w.SSH) == ""
		}
	}
	var withSSH *MachineInfo
	for i := range checked.Workspaces {
		if deref(checked.Workspaces[i].SSH) != "" {
			withSSH = &checked.Workspaces[i]
			break
		}
	}
	if withSSH != nil {
		words := sshResolved(*withSSH.SSH, s.hooks.SSHConfig(SSHDestination(*withSSH.SSH)))
		resolved = d.redact.Text(words)
		s.step(d, StepCheck, words)
		answer += "\n" + words
	} else if noSSH {
		s.step(d, StepCheck, "no ssh destination")
		answer += "\nNo workspace has an ssh destination, so none can be added as a host. " + sshHunt
		if (checked.Items < 0 || checked.Items == n) && checked.FirstItem != nil {
			answer += " The first item:\n" + d.redact.Text(sample(checked.FirstItem))
		}
	}
	c := &DraftCheck{Passed: true, Workspaces: checked.Workspaces, SSH: optional(resolved)}
	if noSSH {
		yes := true
		c.NoSSH = &yes
	}
	s.mu.Lock()
	d.check = c
	s.mu.Unlock()
	s.tell(d)
	return answer
}

func (s *Drafts) prove(d *draft, start bool, arguments any) string {
	given := get(arguments, "draft")
	if _, ok := obj(given); !ok {
		return "Give the draft as a JSON object in `draft`."
	}
	if problem := draftProblem(given, d.isCommands()); problem != "" {
		return "Not asked: " + problem
	}
	named := strOr(get(arguments, "workspace"))
	s.mu.Lock()
	var workspace *MachineInfo
	for i := range d.workspaces {
		if d.workspaces[i].ID == named {
			workspace = &d.workspaces[i]
			break
		}
	}
	if workspace == nil {
		for i := range d.workspaces {
			if strings.EqualFold(d.workspaces[i].Name, named) {
				workspace = &d.workspaces[i]
				break
			}
		}
	}
	s.mu.Unlock()
	if workspace == nil {
		if named == "" {
			return "Not asked: say which workspace. check_draft lists them."
		}
		return "Not asked: " + named + " isn’t in the last list. check_draft lists them."
	}
	w := *workspace
	if !start {
		if busy := s.hooks.BusyHost(d.provider, w.ID); busy != "" {
			return "Not asked: agents are working on " + busy + "."
		}
	}
	provider := d.form.Name
	if provider == "" {
		provider = "the provider"
	}
	verb, kind, yesWords := "stop", "map", "Stop It"
	if start {
		verb, yesWords = "start", "Start It"
	}
	if d.isCommands() {
		kind = "commands"
	}
	text := fmt.Sprintf("%s wants to %s %s on %s to prove the %s.", d.runtimeName, verb, w.Name, provider, kind)
	if start && deref(w.Cost) != "" {
		text += " " + *w.Cost + " while running."
	}
	if start {
		text += " It stays running until you stop it."
	}
	if !s.ask(d, DraftQuestion{Kind: verb, Workspace: &w.Name, Cost: optional(deref(w.Cost)), Text: text, Yes: yesWords}) {
		s.step(d, StepAsk, "asked to "+verb+" "+w.Name+": no")
		return "The person said no."
	}
	s.mu.Lock()
	d.state = "proving"
	d.paused = true
	s.mu.Unlock()
	s.tell(d)
	var after *MachineInfo
	connection, err := s.hooks.Connect(draftRecord(d, given), d.secrets)
	if err == nil {
		if start {
			after, err = connection.Start(w.ID)
		} else {
			after, err = connection.Stop(w.ID)
		}
		connection.End()
	}
	s.mu.Lock()
	d.paused = false
	d.state = "writing"
	s.mu.Unlock()
	past := "Stopped"
	if start {
		past = "Started"
	}
	if err != nil {
		words := d.redact.Text(errorWords(err))
		s.step(d, StepProve, "couldn’t "+verb+" "+w.Name+": "+words)
		return "Failed: " + words
	}
	s.step(d, StepProve, strings.ToLower(past)+" "+w.Name)
	if after != nil {
		return past + " " + w.Name + ": " + after.State
	}
	return past + " " + w.Name + ". check_draft lists its state now."
}

// ask asks the person in the sheet, and waits; no answer in time is a no. The draft's
// clock stops while it waits.
func (s *Drafts) ask(d *draft, question DraftQuestion) bool {
	question.ID = wire.UUID(records.NewUUID())
	waiter := make(chan bool, 1)
	s.mu.Lock()
	if d.ended {
		s.mu.Unlock()
		return false
	}
	d.question = &question
	d.state = "asking"
	d.paused = true
	d.waiter = waiter
	s.mu.Unlock()
	s.step(d, StepAsk, question.Text)
	timer := time.AfterFunc(s.timing.Answer, func() { s.unanswered(d, string(question.ID)) })
	yes := <-waiter
	timer.Stop()
	s.mu.Lock()
	d.question = nil
	d.paused = false
	if !d.ended {
		d.state = "writing"
	}
	ended := d.ended
	s.mu.Unlock()
	s.tell(d)
	return yes && !ended
}

func (s *Drafts) unanswered(d *draft, question string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if d.question == nil || string(d.question.ID) != question || d.waiter == nil {
		return
	}
	d.waiter <- false
	d.waiter = nil
}

// MARK: Its life

// watch is once a tick: the clock, and whether the sheet is still there.
func (s *Drafts) watch(d *draft) {
	last := s.now()
	ticker := time.NewTicker(s.timing.Tick)
	defer ticker.Stop()
	for {
		select {
		case <-d.stop:
			return
		case <-ticker.C:
		}
		now := s.now()
		s.mu.Lock()
		if d.ended {
			s.mu.Unlock()
			return
		}
		if !d.paused {
			d.used += now.Sub(last)
		}
		last = now
		if d.used >= s.timing.Total {
			s.markOverLocked(d)
		}
		lastWord := d.overSince != nil && now.Sub(*d.overSince) >= s.timing.LastWord
		best := d.best() != nil
		s.mu.Unlock()
		if lastWord {
			if best {
				s.end(d, "done", "It ran out of time; this is its last draft.")
			} else {
				what := "a map"
				if d.isCommands() {
					what = "the commands"
				}
				s.end(d, "failed", "Couldn’t write "+what+" in "+durationWords(s.timing.Total)+".")
			}
			return
		}
		here := s.hooks.OwnerHere(d.owner)
		s.mu.Lock()
		gone := false
		switch {
		case here:
			d.ownerGoneSince = nil
		case d.ownerGoneSince != nil:
			gone = now.Sub(*d.ownerGoneSince) >= s.timing.OwnerGone
		default:
			d.ownerGoneSince = &now
		}
		s.mu.Unlock()
		if gone {
			s.end(d, "cancelled", "")
			return
		}
	}
}

func (s *Drafts) markOverLocked(d *draft) {
	if d.over {
		return
	}
	d.over = true
	now := s.now()
	d.overSince = &now
}

func (s *Drafts) turnEnded(d *draft, reason string) {
	s.mu.Lock()
	ended, best, note := d.ended, d.best() != nil, d.note
	s.mu.Unlock()
	if ended {
		return
	}
	if best {
		s.end(d, "done", note)
		return
	}
	what := "a map"
	if d.isCommands() {
		what = "commands"
	}
	if reason != "" {
		s.end(d, "failed", "It ended without sending "+what+": "+reason)
	} else {
		s.end(d, "failed", "It ended without sending "+what+".")
	}
}

// end ends a draft: the agent stops, the sheet is told, and it is dropped a while later.
func (s *Drafts) end(d *draft, state, note string) {
	s.mu.Lock()
	if d.ended {
		s.mu.Unlock()
		return
	}
	d.ended = true
	d.state = state
	d.note = note
	d.question = nil
	close(d.stop)
	if d.waiter != nil {
		d.waiter <- false
		d.waiter = nil
	}
	checks, host, agent := d.checks, d.host, d.agent
	s.mu.Unlock()
	s.tell(d)
	said := ""
	if note != "" {
		said = ": " + d.redact.Text(note)
	}
	plural := "s"
	if checks == 1 {
		plural = ""
	}
	s.log(fmt.Sprintf("provider draft %s: %s%s after %d check%s", shortID(d.id), state, said, checks, plural))
	if host != "" && agent != "" {
		go s.hooks.StopAgent(host, agent, d.owner)
	}
	time.AfterFunc(s.timing.KeptAfter, func() {
		s.mu.Lock()
		if s.drafts[d.id] == d {
			delete(s.drafts, d.id)
		}
		s.mu.Unlock()
	})
}

func (s *Drafts) step(d *draft, kind, text string) {
	s.mu.Lock()
	d.steps = append(d.steps, DraftStep{At: *dateOf(time.Now()), Kind: kind, Text: d.redact.Text(text)})
	if len(d.steps) > maxSteps {
		d.steps = d.steps[len(d.steps)-maxSteps:]
	}
	s.mu.Unlock()
	s.tell(d)
}

// tell tells the sheet where the draft stands, redacted whole: a workspace's name or a
// server's words can hold a secret as well as the agent's draft can.
func (s *Drafts) tell(d *draft) {
	s.mu.Lock()
	update := DraftUpdate{Draft: wire.UUID(d.id), State: d.state, RuntimeName: d.runtimeName,
		Steps: append([]DraftStep{}, d.steps...), Note: optional(d.note)}
	if d.state == "done" {
		update.DraftJSON = jsonValue(d.best())
	} else {
		update.DraftJSON = jsonValue(d.passed)
	}
	if d.check != nil {
		c := *d.check
		update.Check = &c
	}
	if d.question != nil {
		q := *d.question
		update.Question = &q
	}
	s.mu.Unlock()
	if !d.redact.IsEmpty() {
		if redacted, ok := redactUpdate(update, d.redact); ok {
			update = redacted
		} else {
			// A secret that is also one of the update's own words: what cannot be read back
			// redacted is not sent.
			if update.Check != nil {
				update.Check = &DraftCheck{Passed: update.Check.Passed}
			}
			update.DraftJSON = nil
			if update.Question != nil {
				update.Question.Text = d.redact.Text(update.Question.Text)
			}
			update.Note = optional(d.redact.Text(deref(update.Note)))
		}
	}
	s.hooks.Notify(d.owner, update)
}

// redactUpdate is the update with every string redacted, read back as an update; false
// when it no longer reads as one, as Swift's decoder would refuse it.
func redactUpdate(update DraftUpdate, redact Redaction) (DraftUpdate, bool) {
	redacted := redact.Value(toValue(update))
	o, ok := obj(redacted)
	if !ok {
		return update, false
	}
	for _, key := range []string{"draft", "state", "runtimeName", "steps"} {
		if _, ok := o[key]; !ok {
			return update, false
		}
	}
	var out DraftUpdate
	if decodeJSON(rawOf(redacted), &out) != nil || !isUUID(string(out.Draft)) {
		return update, false
	}
	for _, step := range out.Steps {
		if !contains([]string{StepRead, StepHelp, StepCheck, StepAsk, StepProve, StepNote}, step.Kind) {
			return update, false
		}
	}
	if q := out.Question; q != nil && (!isUUID(string(q.ID)) || !contains([]string{"start", "stop", "check"}, q.Kind)) {
		return update, false
	}
	if c := get(o, "check"); c != nil && !has(c, "passed") {
		return update, false
	}
	return out, true
}

// MARK: Helpers

// RunHelp is ProviderDrafts.runHelp: ‹cli› ‹words…› --help where the control plane runs,
// as the command provider runs its commands, in its home, with the secrets as environment,
// cut off after deadline.
func RunHelp(cli string, words []string, secrets map[string]string, folder string, deadline time.Duration) Help {
	ctx, cancel := context.WithTimeout(context.Background(), deadline)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/env", append(append([]string{cli}, words...), "--help")...)
	cmd.Env = os.Environ()
	for k, v := range secrets {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	cmd.Dir = folder
	var out, errOut limitedBuffer
	out.limit, errOut.limit = 256*1024, 256*1024
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err := cmd.Run()
	status := 0
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		status = exit.ExitCode()
	} else if err != nil {
		status = -1
	}
	text := out.String()
	if errOut.Len() > 0 {
		if text != "" {
			text += "\n"
		}
		text += errOut.String()
	}
	if ctx.Err() == context.DeadlineExceeded {
		text += "\n[It didn’t finish in " + durationWords(deadline) + ".]"
	}
	return Help{Status: status, Text: text}
}

// RunSSHConfig is ProviderDrafts.runSSHConfig: ssh -G ‹destination› where the control plane
// runs, what ssh's config makes of it, without connecting (#975).
func RunSSHConfig(destination, folder string) *Help {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "/usr/bin/ssh", "-G", "--", destination)
	cmd.Dir = folder
	var out, errOut limitedBuffer
	out.limit, errOut.limit = 64*1024, 64*1024
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err := cmd.Run()
	status := 0
	var exit *exec.ExitError
	if errors.As(err, &exit) {
		status = exit.ExitCode()
	} else if err != nil {
		status = -1
	}
	if status == 0 {
		return &Help{Status: 0, Text: out.String()}
	}
	return &Help{Status: status, Text: errOut.String()}
}

// limitedBuffer keeps at most limit bytes and drops the rest.
type limitedBuffer struct {
	bytes.Buffer
	limit int
}

func (b *limitedBuffer) Write(p []byte) (int, error) {
	if room := b.limit - b.Len(); room > 0 {
		if len(p) > room {
			b.Buffer.Write(p[:room])
		} else {
			b.Buffer.Write(p)
		}
	}
	return len(p), nil
}

// draftRecord is ProviderDrafts.record: a record for the draft's form, with m as its tool
// map or commands.
func draftRecord(d *draft, m any) ProviderRecord {
	form := d.form
	id := d.provider
	if id == "" {
		id = "draft-" + shortID(d.id)
	}
	name := form.Name
	if name == "" {
		name = "draft"
	}
	names := make([]string, 0, len(d.secrets))
	for k := range d.secrets {
		names = append(names, k)
	}
	sort.Strings(names)
	r := ProviderRecord{ID: id, Name: name, Kind: form.Kind, Command: form.Command, Args: form.Args, URL: form.URL,
		Headers: form.Headers, SecretNames: names, Capabilities: []string{}, Contract: 1}
	if form.Kind == KindCommands {
		r.Commands = m
	} else {
		r.Map = m
	}
	return r
}

// draftProblem is ProviderDrafts.problem: what is wrong with a draft's shape, as Add would
// say it; "" when it parses.
func draftProblem(given any, commands bool) string {
	if commands {
		_, list := str(get(given, "list"))
		_, workspaces := arr(get(given, "workspaces"))
		if !has(given, "preset") && !list && !workspaces {
			return "a config has `list` (with `columns` or `json`), or `workspaces`."
		}
		if has(given, "list") && !has(given, "columns") && !has(given, "json") {
			return "a config with `list` needs `columns` or `json`."
		}
		return ""
	}
	if _, err := MapFrom(given); err != nil {
		return errorWords(err)
	}
	return ""
}

// existingJSON is ProviderDrafts.oldDraft: the map or commands a provider has.
func existingJSON(record ProviderRecord) any {
	if record.Kind == KindCommands {
		return record.Commands
	}
	return record.Map
}

// toolsText is ProviderDrafts.toolsText.
func toolsText(tools []any, redact Redaction) string {
	kept := []any{}
	for _, t := range tools {
		o := map[string]any{}
		for _, key := range []string{"name", "description", "inputSchema", "annotations"} {
			if has(t, key) {
				o[key] = get(t, key)
			}
		}
		kept = append(kept, o)
	}
	return cut(redact.Text(compact(kept)))
}

// sample is ProviderDrafts.sample: one item of a list, as JSON, at most 2 KB.
func sample(item any) string {
	text := compact(item)
	if len(text) <= 2048 {
		return text
	}
	return strings.ToValidUTF8(text[:2048], "�") + " [cut at 2 KB]"
}

// workspaceLine is ProviderDrafts.line.
func workspaceLine(w MachineInfo) string {
	parts := []string{fmt.Sprintf("%s (id %s): %s", w.Name, w.ID, w.State)}
	if deref(w.SSH) != "" {
		parts = append(parts, "ssh "+*w.SSH)
	}
	if deref(w.Cost) != "" {
		parts = append(parts, *w.Cost)
	}
	return "- " + strings.Join(parts, ", ")
}

// hasSSH is ProviderDrafts.hasSSH: whether a draft names an ssh destination (#975).
func hasSSH(given any, commands bool) bool {
	named := func(v any) bool { return strOr(v) != "" }
	if !commands {
		return named(get(get(given, "list"), "ssh"))
	}
	if has(given, "preset") || named(get(given, "ssh")) {
		return true
	}
	ws, _ := arr(get(given, "workspaces"))
	for _, w := range ws {
		if named(get(w, "ssh")) {
			return true
		}
	}
	return false
}

// sshResolved is ProviderDrafts.resolved: what ssh -G resolved a destination to, in one line.
func sshResolved(destination string, output *Help) string {
	if output == nil || output.Status != 0 {
		why := ""
		if output != nil {
			why = lines(output.Text, 2)
		}
		if why != "" {
			why = ": " + why
		}
		return "ssh -G " + destination + " failed" + why + ". Check the destination."
	}
	config := map[string]string{}
	for _, line := range strings.Split(output.Text, "\n") {
		key, value, ok := strings.Cut(line, " ")
		if !ok || key == "" || value == "" {
			continue
		}
		key = strings.ToLower(key)
		if _, seen := config[key]; !seen {
			config[key] = value
		}
	}
	var parts []string
	for _, kv := range [][2]string{{"hostname", "hostname"}, {"user", "user"}, {"port", "port"},
		{"proxycommand", "ProxyCommand"}, {"proxyjump", "ProxyJump"}} {
		if value, ok := config[kv[0]]; ok && value != "none" {
			parts = append(parts, kv[1]+" "+value)
		}
	}
	if len(parts) == 0 {
		return "ssh -G " + destination + ": it printed no hostname."
	}
	return "ssh -G " + destination + ": " + strings.Join(parts, ", ")
}

// sshHunt is ProviderDrafts.sshHunt: where to look for an ssh destination an item does not
// give by name (#975).
const sshHunt = "Look through the whole item for one: a user@host inside IDE or deep-link URLs (ssh-remote+coder@host), " +
	"host= and user= query parameters, a program=ssh argument (arg=coder%40host). Write it as a template over the " +
	"item's own fields, such as \"coder@cws.{name}\", never one workspace's literal. If it can't be written from the " +
	"item's fields, leave ssh out and give the literal you found in send_draft's note."

// cut is ProviderDrafts.cut: at most 16 KB of an output.
func cut(text string) string {
	if len(text) <= cutBytes {
		return text
	}
	return strings.ToValidUTF8(text[:cutBytes], "�") + fmt.Sprintf("\n[Cut at 16 KB of %d KB.]", len(text)/1024)
}

// lines is ProviderDrafts.lines: the first count lines that are not empty.
func lines(text string, count int) string {
	var out []string
	for _, l := range strings.Split(text, "\n") {
		if l != "" && len(out) < count {
			out = append(out, l)
		}
	}
	return strings.Join(out, "\n")
}

// MARK: The prompt (research R7)

type oldDraft struct {
	json    any
	problem string
}

func prompt(d *draft, seed string, existing *oldDraft) string {
	what, goal, tool := "tool map", "Write a tool map, so this MCP server's own tools can list, start and stop the machines Agents runs agents on.", "read_tools"
	if d.isCommands() {
		what, tool = "command-provider config", "read_help"
		goal = "Write a config for Agents' command provider, so the CLI `" + d.cli() + "` can list, start and stop the machines it runs agents on."
	}
	parts := []string{fmt.Sprintf(`You write one %s for Agents' Add Provider sheet. %s A person reads what you send and adds it.

You have only these tools: %s, check_draft, prove_start, prove_stop, send_draft and give_up. You can't run commands, read files or reach the network: the control plane does all of that for you.

Rules:
- Check before you send: check_draft lists the workspaces once with your draft. Change it and check again until it passes. At most %d checks and %d calls; about %s.
- The list must be a plain list. A check that may change something is asked of the person, who may say no.
- Ask with prove_start or prove_stop only when you are not sure of the start or stop. Each costs money and changes a machine, so the person is asked every time. Don't ask more than once for each.
- Give ssh when you can: without it, no workspace can be added as a host, or started over ssh. %s check_draft tests it with `+"`ssh -G`"+`, which resolves it without connecting.
- End with send_draft (the draft that passed, and a short note for the person: what you did not try), or give_up with one sentence. Then end your turn.`,
		what, goal, tool, MaxChecks, MaxCalls, durationWords(StandardDraftTiming.Total), sshHunt)}
	if len(d.secrets) > 0 {
		names := make([]string, 0, len(d.secrets))
		for k := range d.secrets {
			names = append(names, k)
		}
		sort.Strings(names)
		to := "server"
		if d.isCommands() {
			to = "CLI as environment"
		}
		parts = append(parts, "Its secrets are "+strings.Join(names, ", ")+". You never see their values: where one would show, you see ${NAME}. Don't put a secret in a draft: the control plane passes them to the "+to+" itself.")
	}
	if d.isCommands() {
		parts = append(parts, commandFormat)
	} else {
		parts = append(parts, mapFormat)
	}
	if existing != nil {
		if existing.json != nil {
			kind := "map"
			if d.isCommands() {
				kind = "config"
			}
			data, _ := json.Marshal(existing.json)
			parts = append(parts, "It has this "+kind+" now:\n"+d.redact.Text(string(data)))
		}
		if existing.problem != "" {
			parts = append(parts, "Its last list failed: "+d.redact.Text(existing.problem))
		}
	}
	if d.isCommands() {
		parts = append(parts, "`"+d.cli()+" --help` printed:\n"+seed)
	} else {
		parts = append(parts, "The server's tools (read_tools gives them again):\n"+seed)
	}
	return strings.Join(parts, "\n\n")
}

const mapFormat = `The tool map's format (JSON):
{
  "list": { "tool": "droplet-list", "arguments": { "tag_name": "agents" },
            "items": "droplets", "id": "id", "name": "name", "state": "status",
            "ssh": "root@{networks.v4[0].ip_address}", "cost": "${size.price_hourly}/hour",
            "states": { "active": "running", "new": "starting", "off": "stopped" } },
  "start": { "tool": "droplet-power-on", "arguments": { "droplet_id": "{id}" } },
  "stop":  { "tool": "droplet-power-off", "arguments": { "droplet_id": "{id}" } }
}
- list.tool, start.tool and stop.tool are the server's tools, by name; each must be in its tools.
- arguments is a template for the call's arguments. "{id}" is the workspace's id; "{id:number}" sends it as a number.
- A path is dotted keys, with [n] for an index and [] for every element: droplets, networks.v4[0].ip_address.
  It is read in the tool's structuredContent, or its first text parsed as JSON.
- list.items is the path to the array of workspaces; empty for the result itself. id, name and state are paths in
  each item. state's value is looked up in states, which maps the server's words to running, starting, stopping,
  stopped or unknown.
- ssh, tunnel and cost are optional: a path, or a template with {path} in it.
- create, delete and options are optional, the same shape as start.`

const commandFormat = `The command provider's config (JSON). Commands run with /bin/sh where the control plane runs.
One workspace each:
{ "workspaces": [ { "id": "devstack-1", "name": "devstack", "start": "cws start devstack-1",
                    "stop": "cws stop devstack-1", "status": "cws status devstack-1", "ssh": "devstack-1.cws" } ] }
- id defaults to name. status is optional; it prints the state, mapped by "states".
Or many from one list:
{ "list": "cws list --no-header", "columns": ["id", "name", "state", "ip"],
  "start": "cws start ${id}", "stop": "cws stop ${id}", "ssh": "root@${ip}",
  "states": { "up": "running", "down": "stopped" } }
- list prints one workspace per line, split on whitespace into columns; the last column takes the rest.
- Or, instead of columns, "json": {"items": "<path>", "id": "<path>", "name": "<path>", "state": "<path>"}
  reads the output as JSON, with the tool map's paths.
- ${column} in a template is the value from that workspace's row.
- states maps the CLI's words to running, starting, stopping, stopped or unknown.`

// MARK: Wiring

// DraftWiring is what NewDraftsFor needs to wire drafts as ControlService does.
type DraftWiring struct {
	Router  Router
	Records MachineRecords
	// MachineID is this control plane's machine, for the host on it.
	MachineID func() string
	// Home is the control plane's home: where help and ssh -G run.
	Home    string
	Connect func(record ProviderRecord, secrets map[string]string) (Provider, error)
	Timing  DraftTiming
	Log     func(string)
}

// NewDraftsFor is ProviderDrafts wired as ControlService wires it (#858), handed to p: an
// agent on this machine's own host writes the map.
func NewDraftsFor(p *Providers, w DraftWiring) *Drafts {
	router := w.Router
	if w.Timing == (DraftTiming{}) {
		w.Timing = StandardDraftTiming
	}
	hooks := DraftHooks{
		Connect: w.Connect,
		Help: func(cli string, words []string, secrets map[string]string) Help {
			return RunHelp(cli, words, secrets, w.Home, w.Timing.Help)
		},
		LocalHost: func() *LocalHost {
			machine := w.MachineID()
			for _, h := range w.Records.Hosts() {
				if h.Relay == nil && h.MachineID != nil && *h.MachineID == machine &&
					router.Online(h.ID) && router.Holds(h.ID) {
					return &LocalHost{ID: h.ID, Name: h.Name}
				}
			}
			return nil
		},
		StartAgent: func(host string, request StartRequest, owner Caller) (string, error) {
			reply := router.DeliverKept(MethodAgentsStart, rawOf(request), owner.Client, owner.Kind, host, 120*time.Second)
			switch {
			case reply == nil:
				return "", providerFailure("The host on this machine didn’t answer.")
			case reply.Error != nil:
				return "", reply.Error
			}
			var agent string
			if json.Unmarshal(reply.Result, &agent) != nil || !isUUID(agent) {
				return "", providerFailure("The host on this machine didn’t answer.")
			}
			return strings.ToUpper(agent), nil
		},
		StopAgent: func(host, agent string, owner Caller) {
			router.DeliverKept(MethodAgentsStop, rawOf(map[string]string{"agentID": agent}), owner.Client, owner.Kind, host,
				30*time.Second)
		},
		Notify: func(owner Caller, update DraftUpdate) bool {
			return router.TellControl(owner.Session, NoticeProviderDraft, update)
		},
		OwnerHere: func(owner Caller) bool { return router.HasSession(owner.Session) },
		BusyHost:  p.BusyHost,
		SSHConfig: func(destination string) *Help { return RunSSHConfig(destination, w.Home) },
	}
	d := NewDrafts(w.Timing, hooks, w.Log, nil)
	p.DraftWith(d)
	return d
}
