package agentsd

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// The rest of a chat's life, as DaemonCore serves it: prompts on a queue that is the
// daemon's, names and labels, the archive and back, deleting, and what the runtime is
// told to change.

func noSuchAgent() error { return &Error{Code: CodeNoSuchAgent, Message: "That agent is not here."} }

func (d *Daemon) registerAgents() {
	On(d, wire.CallAgentsPrompt, func(ctx context.Context, c *Client, r wire.PromptRequest) (wire.Empty, error) {
		return wire.Empty{}, d.prompt(r)
	})
	On(d, wire.CallAgentsUnqueue, func(ctx context.Context, c *Client, r wire.UnqueueRequest) (wire.Empty, error) {
		if d.change(r.AgentID, func(a *wire.Agent) { a.QueuedPrompts = unqueued(a.QueuedPrompts, r.PromptID) }) == nil {
			return wire.Empty{}, noSuchAgent()
		}
		return wire.Empty{}, nil
	})
	On(d, wire.CallAgentsEditQueued, func(ctx context.Context, c *Client, r wire.EditQueuedRequest) (wire.EditQueuedResult, error) {
		return d.editQueued(r)
	})
	On(d, wire.CallAgentsSaid, func(ctx context.Context, c *Client, r wire.SaidSearchRequest) (wire.SaidSearchResult, error) {
		return d.saidSearch(r), nil
	})
	On(d, wire.CallAgentsFind, func(ctx context.Context, c *Client, r wire.FindRequest) (wire.FindResult, error) {
		return d.find(ctx, c.ID, r)
	})
	On(d, wire.CallAgentsSendNow, func(ctx context.Context, c *Client, r wire.UnqueueRequest) (wire.Empty, error) {
		return wire.Empty{}, d.sendNow(ctx, r)
	})
	On(d, wire.CallAgentsRename, func(ctx context.Context, c *Client, r wire.RenameRequest) (wire.Agent, error) {
		return d.rename(r)
	})
	On(d, wire.CallAgentsSetLabels, func(ctx context.Context, c *Client, r wire.SetLabelsRequest) (wire.Agent, error) {
		return d.setLabels(r)
	})
	On(d, wire.CallAgentsLabelVocabulary, func(ctx context.Context, c *Client, r wire.LabelVocabularyRequest) ([]string, error) {
		out := []string{}
		for _, l := range vocabulary(store.FolderPath(r.Folder), d.Store.Agents()) {
			out = append(out, l.Value)
		}
		return out, nil
	})
	On(d, wire.CallAgentsUnarchive, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.Empty, error) {
		return wire.Empty{}, d.unarchive(r.AgentID)
	})
	On(d, wire.CallAgentsDelete, func(ctx context.Context, c *Client, r wire.AgentRequest) (wire.Empty, error) {
		d.actedOn(r.AgentID, c.actor)
		return wire.Empty{}, d.delete(r.AgentID)
	})
	On(d, wire.CallAgentsSetCeiling, func(ctx context.Context, c *Client, r wire.SetCeilingRequest) (wire.Agent, error) {
		a := d.change(r.AgentID, func(a *wire.Agent) { a.CostCeiling, a.TokenCeiling = r.Ceiling, r.TokenCeiling })
		if a == nil {
			return wire.Agent{}, noSuchAgent()
		}
		// Let go of its hold, with no prompt sent: the person sends when they are ready.
		d.costMu.Lock()
		delete(d.held, r.AgentID)
		d.costMu.Unlock()
		return *a, nil
	})
	On(d, wire.CallAgentsSetOption, func(ctx context.Context, c *Client, r wire.SetOptionRequest) ([]wire.ConfigOption, error) {
		return d.setOption(ctx, r)
	})
	On(d, wire.CallAgentsStopBackground, func(ctx context.Context, c *Client, r wire.StopBackgroundRequest) (wire.JSONValue, error) {
		a := d.Store.Agent(r.AgentID)
		if a == nil {
			return nil, noSuchAgent()
		}
		// What runs in the background (AIR async tasks) is not followed by this host yet,
		// so nothing is: Swift's words for an item it does not have.
		return nil, Invalid("Nothing by that name is running.")
	})
	On(d, wire.CallAgentsTouchedPaths, func(ctx context.Context, c *Client, r wire.AgentRequest) ([]string, error) {
		return d.touchedPaths(r.AgentID), nil
	})
	On(d, wire.CallAgentsResuming, func(ctx context.Context, c *Client, _ wire.Empty) (wire.ResumingResponse, error) {
		return wire.ResumingResponse{AgentIDs: d.resumingNow()}, nil
	})
	On(d, wire.CallAgentsContinueInFolder, func(ctx context.Context, c *Client, r wire.ContinueInFolderRequest) (wire.UUID, error) {
		return d.continueInFolder(r)
	})
	On(d, wire.CallAgentsContinueInNew, func(ctx context.Context, c *Client, r wire.ContinueInNewRequest) (wire.UUID, error) {
		return d.continueInNew(r)
	})
}

func unqueued(queue []wire.QueuedPrompt, id wire.UUID) []wire.QueuedPrompt {
	out := []wire.QueuedPrompt{}
	for _, q := range queue {
		if q.ID != id {
			out = append(out, q)
		}
	}
	return out
}

// editQueued is agents/editQueued (#1552): the person's queued prompt takes new words and
// keeps its place. Edited is false when it is not waiting any more (sent, or taken back),
// so the client keeps the words for the person; another agent's prompt is not theirs to edit.
func (d *Daemon) editQueued(r wire.EditQueuedRequest) (wire.EditQueuedResult, error) {
	edited := false
	if d.change(r.AgentID, func(a *wire.Agent) {
		queue := append([]wire.QueuedPrompt{}, a.QueuedPrompts...)
		for i := range queue {
			if queue[i].ID == r.PromptID && queue[i].From == wire.PromptOriginPerson {
				queue[i].Text = r.Text
				edited = true
			}
		}
		a.QueuedPrompts = queue
	}) == nil {
		return wire.EditQueuedResult{}, noSuchAgent()
	}
	return wire.EditQueuedResult{Edited: edited}, nil
}

// voicePreface is what the runtime reads before words sent from voice mode (#2322): the
// person hears the reply and does not see it. It also says the words were dictated, so a
// word that sounds like another is read as the one that was meant (#2515). The spike's
// text (#1792) took Claude's replies from a median of 138 words to 48, with no markdown
// and no paths.
const voicePreface = "You are in voice mode. The person hears your reply and does not see it. " +
	"The person's words were dictated. A word may be the wrong word that sounds the same. Use the names of this folder. " +
	"Answer in one to three short spoken sentences. Use plain words. " +
	"Do not use markdown, lists, tables, code or file paths. " +
	"If the work changed files, say what changed in one sentence. " +
	"If you need a decision, ask one clear question. " +
	"If the person says they are done talking, say a short goodbye and call hang_up."

// prompt is agents/prompt: the words go on the queue, never refused for the agent being
// busy, and go once the agent is free.
func (d *Daemon) prompt(r wire.PromptRequest) error {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return noSuchAgent()
	}
	if err := d.refuseToRun(a); err != nil {
		return err
	}
	if err := d.promptRefusal(a); err != nil {
		return err
	}
	if err := d.needsSignIn(a.RuntimeID); err != nil {
		return err
	}
	if !d.once(r.SendID) {
		return nil
	}
	if !isDir(store.FolderPath(a.Cwd)) {
		return &Error{Code: wire.FailureFolderGone, Message: store.FolderPath(a.Cwd) + " is not there any more."}
	}
	from := r.From
	if from == "" {
		from = wire.PromptOriginPerson
	}
	var preface *string
	if from == wire.PromptOriginPerson {
		// The person's words take back an archive asked for and a question for after the turn.
		d.change(a.ID, func(a *wire.Agent) { a.ArchiveRequest, a.AfterTurn = nil, nil })
		// The person carries a blocked agent on past its block.
		d.dropBlock(a.ID)
		// And a wait: the runtime is told, ahead of the words.
		if w := d.endWait(a.ID, "prompt", false); w != nil {
			p := "(Your wait for " + waitLabel(w) + " was cancelled by this message. Wait again if you still need to.)"
			preface = &p
		}
	}
	if r.Voice != nil && *r.Voice {
		p := voicePreface
		if preface != nil {
			p = *preface + "\n\n" + p
		}
		preface = &p
	}
	voice := r.Voice != nil && *r.Voice
	// The turn running before the words were queued: the one they talk over.
	l := d.live(a.ID)
	l.mu.Lock()
	busy, seq := l.inTurn, l.turnSeq
	l.mu.Unlock()
	if err := d.enqueue(a.ID, wire.QueuedPrompt{ID: store.NewUUID(), Text: r.Text, Attachments: r.Attachments,
		QueuedAt: now(), From: from, Preface: preface}, voice); err != nil {
		return err
	}
	if voice && busy {
		d.bargeIn(a.ID, seq)
	}
	return nil
}

// bargeIn is words said in voice mode while a turn runs (#2375): the person talked over
// the agent, as over a person, so the turn stops and the words, first in the queue, go
// as soon as it has ended. A stop leaves the queue (run), so it is started again here.
// Only turn seq, the one running when the words came: never the turn that carries them.
func (d *Daemon) bargeIn(id wire.UUID, seq int) {
	l := d.live(id)
	l.mu.Lock()
	still := l.inTurn && l.turnSeq == seq
	l.mu.Unlock()
	if !still {
		return
	}
	l.cancel()
	go func() {
		for range bargeInTries {
			select {
			case <-d.ctx.Done():
				return
			case <-time.After(bargeInEvery):
			}
			l.mu.Lock()
			ended := !l.inTurn && !l.running
			l.mu.Unlock()
			if ended {
				l.kick()
				return
			}
		}
	}()
}

// How often, and how many times, a barge-in looks for the stopped turn to have ended:
// 10 s in all, longer than a runtime takes to answer session/cancel.
var (
	bargeInEvery = 100 * time.Millisecond
	bargeInTries = 100
)

// sendNow is DaemonCore.sendNow: a queued prompt goes at once, into the running turn
// where the runtime takes words mid-turn, or as the next turn when none is running.
func (d *Daemon) sendNow(ctx context.Context, r wire.UnqueueRequest) error {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return noSuchAgent()
	}
	var queued *wire.QueuedPrompt
	for _, q := range a.QueuedPrompts {
		if q.ID == r.PromptID {
			queued = &q
			break
		}
	}
	if queued == nil {
		return nil // gone already: it went out as the turn ended, or was taken back
	}
	l := d.live(a.ID)
	l.mu.Lock()
	s, inTurn := l.session, l.inTurn
	l.mu.Unlock()
	if s == nil && !isDir(store.FolderPath(a.Cwd)) {
		return &Error{Code: wire.FailureFolderGone, Message: store.FolderPath(a.Cwd) + " is not there any more."}
	}
	if !inTurn || s == nil {
		// To the front, so it goes next, with the person's words behind it.
		d.change(a.ID, func(a *wire.Agent) {
			a.QueuedPrompts = append([]wire.QueuedPrompt{*queued}, unqueued(a.QueuedPrompts, queued.ID)...)
		})
		l.kick()
		return nil
	}
	if !s.SupportsSteering() {
		return &Error{Code: wire.FailureNotSupported, Message: "This agent's runtime cannot take words in the middle of a turn."}
	}
	// Off the queue before the wait, so the turn ending in it does not send them twice.
	d.change(a.ID, func(a *wire.Agent) { a.QueuedPrompts = unqueued(a.QueuedPrompts, queued.ID) })
	bs := blocks(*queued)
	outgoing := bs
	if queued.Preface != nil {
		outgoing = append([]wire.ContentBlock{textBlock(*queued.Preface)}, bs...)
	}
	putBack := func() {
		d.change(a.ID, func(a *wire.Agent) { a.QueuedPrompts = append([]wire.QueuedPrompt{*queued}, a.QueuedPrompts...) })
	}
	outcome, err := s.Steer(ctx, acpBlocks(outgoing))
	if err != nil {
		putBack()
		d.record(a.ID, runtimeNote("Could not send that now: "+err.Error()+" It is still waiting."))
		return nil
	}
	switch outcome {
	case "injected", "startedNewTurn":
		from := queued.From
		um := &wire.TranscriptEntryKindUserMessage{Value: queued.Text, From: &from}
		if len(bs) > 1 {
			um.Blocks = bs
		}
		d.record(a.ID, wire.TranscriptEntryKind{UserMessage: um})
	case "promptRequired":
		putBack()
		l.kick()
	default:
		putBack()
		d.record(a.ID, runtimeNote("Could not send that now. It is still waiting."))
	}
	return nil
}

func runtimeNote(text string) wire.TranscriptEntryKind {
	return wire.TranscriptEntryKind{RuntimeNote: &wire.TranscriptEntryKindRuntimeNote{Value: text}}
}

// cleanedTitle is Agent.cleanedTitle: one line, spaces collapsed, at most 80 characters.
func cleanedTitle(raw string) (string, bool) {
	one := strings.Join(strings.Fields(raw), " ")
	if one == "" {
		return "", false
	}
	if utf8.RuneCountInString(one) > 80 {
		one = string([]rune(one)[:79]) + "…"
	}
	return one, true
}

// rename is agents/rename (Agent.rename(to:)): the person's name, with the runtime's kept
// aside; an empty one hands naming back to the runtime.
func (d *Daemon) rename(r wire.RenameRequest) (wire.Agent, error) {
	if d.Store.Agent(r.AgentID) == nil {
		return wire.Agent{}, noSuchAgent()
	}
	title, ok := cleanedTitle(r.Title)
	a := d.change(r.AgentID, func(a *wire.Agent) {
		persons := a.TitleIsPersons != nil && *a.TitleIsPersons
		switch {
		case ok:
			if !persons {
				a.RuntimeTitle = a.Title
			}
			yes := true
			a.Title, a.TitleIsPersons = &title, &yes
		case persons:
			a.Title, a.RuntimeTitle, a.TitleIsPersons = a.RuntimeTitle, nil, nil
		}
	})
	return *a, nil
}

// MARK: labels (SessionLabelPolicy)

const labelLength, labelCount = 24, 5

func labelKey(v string) string { return strings.ToLower(strings.TrimSpace(v)) }

func cleanedLabel(v string) (string, error) {
	v = strings.TrimSpace(v)
	if v == "" {
		return "", Invalid("A label needs at least one non-space character.")
	}
	if utf8.RuneCountInString(v) > labelLength {
		return "", Invalid("A label can be at most 24 characters.")
	}
	return v, nil
}

// changeLabels is SessionLabelPolicy.change for the person.
func changeLabels(current []wire.SessionLabel, add, remove []string, folder []wire.SessionLabel) ([]wire.SessionLabel, error) {
	return changeLabelsAs(wire.SessionLabelOwnerPerson, current, add, remove, folder)
}

// changeLabelsAs is SessionLabelPolicy.change by an actor: an agent cannot change a label
// the person gave.
func changeLabelsAs(actor wire.SessionLabelOwner, current []wire.SessionLabel, add, remove []string, folder []wire.SessionLabel) ([]wire.SessionLabel, error) {
	ownedByPerson := func(v string) error {
		return Invalid("The label %s belongs to the person, so an agent cannot change it.", v)
	}
	var adding, removing []string
	for _, v := range add {
		c, err := cleanedLabel(v)
		if err != nil {
			return nil, err
		}
		adding = append(adding, c)
	}
	addKeys := map[string]bool{}
	for _, v := range adding {
		addKeys[labelKey(v)] = true
	}
	for _, v := range remove {
		c, err := cleanedLabel(v)
		if err != nil {
			return nil, err
		}
		if addKeys[labelKey(c)] {
			return nil, Invalid("The label %s cannot be added and removed in the same change.", c)
		}
		removing = append(removing, c)
	}
	result := append([]wire.SessionLabel{}, current...)
	for _, v := range removing {
		for i, l := range result {
			if labelKey(l.Value) == labelKey(v) {
				if actor == wire.SessionLabelOwnerAgent && l.Owner == wire.SessionLabelOwnerPerson {
					return nil, ownedByPerson(l.Value)
				}
				result = append(result[:i], result[i+1:]...)
				break
			}
		}
	}
	for _, v := range adding {
		found := false
		for i, l := range result {
			if labelKey(l.Value) == labelKey(v) {
				if actor == wire.SessionLabelOwnerAgent && l.Owner == wire.SessionLabelOwnerPerson {
					return nil, ownedByPerson(l.Value)
				}
				if actor == wire.SessionLabelOwnerPerson {
					result[i].Owner = wire.SessionLabelOwnerPerson
				}
				found = true
				break
			}
		}
		if found {
			continue
		}
		if len(result) >= labelCount {
			return nil, Invalid("A session can have at most five labels.")
		}
		canonical := v
		for _, l := range folder {
			if labelKey(l.Value) == labelKey(v) {
				canonical = l.Value
				break
			}
		}
		result = append(result, wire.SessionLabel{Value: canonical, Owner: actor, AddedAt: now()})
	}
	return result, nil
}

// vocabulary is SessionLabelPolicy.vocabulary: every label in the folder, oldest first,
// once each.
func vocabulary(folder string, agents []wire.Agent) []wire.SessionLabel {
	var all []wire.SessionLabel
	for _, a := range agents {
		if folderPath(&a) == folder {
			all = append(all, a.Labels...)
		}
	}
	sort.SliceStable(all, func(i, j int) bool {
		if all[i].AddedAt != all[j].AddedAt {
			return all[i].AddedAt < all[j].AddedAt
		}
		return labelKey(all[i].Value) < labelKey(all[j].Value)
	})
	seen := map[string]bool{}
	var out []wire.SessionLabel
	for _, l := range all {
		if !seen[labelKey(l.Value)] {
			seen[labelKey(l.Value)] = true
			out = append(out, l)
		}
	}
	return out
}

func (d *Daemon) setLabels(r wire.SetLabelsRequest) (wire.Agent, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return wire.Agent{}, &Error{Code: CodeNoSuchAgent, Message: "That session no longer exists."}
	}
	labels, err := changeLabels(a.Labels, r.Add, r.Remove, vocabulary(folderPath(a), d.Store.Agents()))
	if err != nil {
		return wire.Agent{}, err
	}
	return *d.change(a.ID, func(a *wire.Agent) { a.Labels = labels }), nil
}

// unarchive is the move unarchivedByUser: back to how it ended, finished for a turn that
// ended itself and stopped otherwise; from anything but archived, nothing.
func (d *Daemon) unarchive(id wire.UUID) error {
	a := d.Store.Agent(id)
	if a == nil {
		return noSuchAgent()
	}
	if a.State != wire.AgentStateArchived {
		return nil
	}
	next := wire.AgentStateStopped
	if a.EndedReason != nil && *a.EndedReason == wire.EndedReasonEndTurn {
		next = wire.AgentStateFinished
	}
	var said *wire.EndedReason
	d.change(id, func(a *wire.Agent) {
		if a.EndedReason == nil {
			a.EndedReason, said = reason(wire.EndedReasonUnrecognised), reason(wire.EndedReasonUnrecognised)
		}
		if *a.EndedReason != wire.EndedReasonDaemonGone {
			a.RestartPickUps = nil
		}
		unread := next == wire.AgentStateFinished
		a.State, a.ArchivedAt, a.ArchivedReason, a.AfterTurn, a.IsUnread = next, nil, nil, nil, &unread
	})
	d.record(id, stateChanged(next, said))
	return nil
}

// delete is DaemonCore.deleteNow for the person: only an archived agent, and its folder
// and turns go from the disk.
func (d *Daemon) delete(id wire.UUID) error {
	a := d.Store.Agent(id)
	if a == nil {
		return noSuchAgent()
	}
	if a.State != wire.AgentStateArchived {
		return &Error{Code: wire.FailureDeleteRefused, Message: "Only an archived session can be deleted. Archive it first."}
	}
	return d.deleteArchived(a, "person")
}

// deleteArchived removes an archived agent, its folder and its turns; because is who or
// what deleted it ("person", or "retention" for the sweep).
func (d *Daemon) deleteArchived(a *wire.Agent, because string) error {
	return d.deleteArchivedThen(a, because, func(a *wire.Agent) { d.queueErasure(a) })
}

// deleteArchivedThen is deleteArchived, with erase to queue the runtime's copy: a sweep
// collects them, to queue many at once (#2427).
func (d *Daemon) deleteArchivedThen(a *wire.Agent, because string, erase func(*wire.Agent)) error {
	d.mu.Lock()
	l := d.lives[a.ID]
	delete(d.lives, a.ID)
	d.mu.Unlock()
	if l != nil {
		l.halt()
	}
	d.dropAppTokens(a.ID)
	d.dropStandIn(a.ID)
	if err := d.Store.Delete(a.ID); err != nil {
		return &Error{Code: wire.FailureCouldNotSave, Message: "The agent could not be deleted: " + err.Error()}
	}
	// The runtime's own copy goes next, and a backup never brings the agent back (#1001).
	erase(a)
	copyOf := "none"
	if d.mayErase(a, nil) {
		copyOf = "queued"
	}
	Broadcast(d, wire.NotifyAgentRemoved, wire.AgentRemovedNotification{AgentID: a.ID})
	d.raiseAbout(a, "agent.deleted", "was deleted with its conversation.", map[string]string{"because": because, "runtimeCopy": copyOf})
	d.takeActor(a.ID) // a helper's deletion raises nothing to take it
	d.folderChanged(folderPath(a))
	return nil
}

// setOption is agents/setOption: to the live session when there is one, and kept as a
// start option either way, recorded as optionChanged.
func (d *Daemon) setOption(ctx context.Context, r wire.SetOptionRequest) ([]wire.ConfigOption, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return nil, noSuchAgent()
	}
	if err := d.optionRefusal(a, r.OptionID, stringValue(r.Value)); err != nil {
		return nil, err
	}
	l := d.live(a.ID)
	if a.RuntimeID == "claude" && r.OptionID == chromeOptionID {
		return d.setChrome(a, l, r.Value), nil
	}
	l.mu.Lock()
	s := l.session
	l.mu.Unlock()
	options := []wire.ConfigOption{}
	if s != nil {
		var v any
		json.Unmarshal(r.Value, &v)
		cctx, cancel := context.WithTimeout(ctx, 30*time.Second)
		defer cancel()
		got, err := s.SetOption(cctx, r.OptionID, v)
		if err != nil {
			return nil, &Error{Code: CodeServer, Message: err.Error()}
		}
		if opts := configOptions(got); len(opts) > 0 {
			options = opts
		} else {
			options = a.AdvertisedOptions
		}
	}
	d.change(a.ID, func(a *wire.Agent) {
		values := map[string]wire.JSONValue{}
		for k, v := range a.StartOptions.Values {
			values[k] = v
		}
		values[r.OptionID] = r.Value
		a.StartOptions.Values = values
		if s != nil {
			a.AdvertisedOptions = d.markOptions(a.RuntimeID, withAppOptions(a.RuntimeID, values, options))
		}
		a.Levels = d.matchLevels(a)
	})
	known := options
	if s == nil {
		known = a.AdvertisedOptions
	}
	d.rememberMode(a.RuntimeID, r.OptionID, r.Value, known)
	d.record(a.ID, wire.TranscriptEntryKind{OptionChanged: &wire.TranscriptEntryKindOptionChanged{ID: r.OptionID, Value: r.Value}})
	return options, nil
}

// touchedPaths is AgentStore.touchedPaths: every path a tool call named, resolved.
func (d *Daemon) touchedPaths(id wire.UUID) []string {
	entries, _, _ := d.Store.Transcript(id, 0)
	seen := map[string]bool{}
	add := func(p string) {
		if p == "" {
			return
		}
		if r, err := store.Resolve(p); err == nil {
			p = r
		}
		seen[filepath.Clean(p)] = true
	}
	for _, e := range entries {
		var tc *wire.ToolCall
		if e.Kind.ToolCall != nil {
			tc = &e.Kind.ToolCall.Value
		} else if e.Kind.ToolCallUpdate != nil {
			tc = &e.Kind.ToolCallUpdate.Value
		}
		if tc == nil {
			continue
		}
		for _, l := range tc.Locations {
			add(l.Path)
		}
		for _, c := range tc.Content {
			if c.Type == "diff" && c.Path != nil {
				add(*c.Path)
			}
		}
	}
	out := []string{}
	for p := range seen {
		out = append(out, p)
	}
	sort.Strings(out)
	return out
}

// shortPath is MissingFolderWords.shortPath: ~ for the home folder.
func shortPath(path string) string {
	if len(path) > 1 {
		path = strings.TrimSuffix(path, "/")
	}
	if home, _ := os.UserHomeDir(); home != "" && (path == home || strings.HasPrefix(path, home+"/")) {
		return "~" + path[len(home):]
	}
	return path
}

// continueInNew is Continue in New (#999): a successor in the same folder that reads this
// session and carries on, with its runtime, choices and the person's labels, on the account
// asked for, else the runtime's account for new sessions. For a session whose account the
// organisation removed or no longer allows; start applies the policy to the new account.
func (d *Daemon) continueInNew(r wire.ContinueInNewRequest) (wire.UUID, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return "", noSuchAgent()
	}
	cwd := a.Cwd
	if !isDir(store.FolderPath(cwd)) {
		cwd = store.FolderURL(folderPath(a))
	}
	name := string(a.ID)
	if a.Title != nil {
		name = "“" + *a.Title + "” (" + string(a.ID) + ")"
	}
	prompt := "Continue the work of the session " + name + ", which can no longer reach the model on its account. " +
		"Read that session with read_session to see what it did and what is left, then carry on."
	var labels []string
	for _, l := range a.Labels {
		if l.Owner == wire.SessionLabelOwnerPerson {
			labels = append(labels, l.Value)
		}
	}
	id, err := d.start(wire.StartRequest{RuntimeID: a.RuntimeID, Cwd: cwd, Prompt: prompt, Attachments: []wire.Attachment{},
		StartOptions: a.StartOptions, AdditionalDirectories: a.AdditionalDirectories, McpServers: a.McpServers,
		RequestID: r.RequestID, Sandbox: a.SandboxOverride, Labels: labels, AccountID: r.AccountID})
	if err != nil {
		return "", err
	}
	if a.Title != nil {
		d.change(id, func(s *wire.Agent) { s.Title, s.TitleIsPersons = a.Title, a.TitleIsPersons })
	}
	return id, nil
}

// continueInFolder starts a successor in the folder that reads this session and
// carries on (065), with its runtime, choices and the person's labels.
func (d *Daemon) continueInFolder(r wire.ContinueInFolderRequest) (wire.UUID, error) {
	a := d.Store.Agent(r.AgentID)
	if a == nil {
		return "", noSuchAgent()
	}
	folder := folderPath(a)
	if !isDir(folder) {
		return "", &Error{Code: wire.FailureFolderGone, Message: "The folder isn't there either (" + shortPath(folder) + ")."}
	}
	name := string(a.ID)
	if a.Title != nil {
		name = "“" + *a.Title + "” (" + string(a.ID) + ")"
	}
	prompt := "Continue the work of the session " + name + ". Its folder, " + shortPath(store.FolderPath(a.Cwd)) +
		", is not there any more, so you are in the folder, " + shortPath(folder) +
		", instead. Read that session with read_session to see what it did and what is left, then carry on."
	if said := strings.TrimSpace(r.Text); said != "" {
		prompt += "\n\n" + said
	}
	var labels []string
	for _, l := range a.Labels {
		if l.Owner == wire.SessionLabelOwnerPerson {
			labels = append(labels, l.Value)
		}
	}
	id, err := d.start(wire.StartRequest{RuntimeID: a.RuntimeID, Cwd: store.FolderURL(folder), Prompt: prompt,
		Attachments: r.Attachments, StartOptions: a.StartOptions, AdditionalDirectories: a.AdditionalDirectories,
		McpServers: a.McpServers, RequestID: r.RequestID, Sandbox: a.SandboxOverride, Labels: labels, AccountID: a.AccountID})
	if err != nil {
		return "", err
	}
	if a.Title != nil {
		d.change(id, func(s *wire.Agent) { s.Title, s.TitleIsPersons = a.Title, a.TitleIsPersons })
	}
	return id, nil
}
