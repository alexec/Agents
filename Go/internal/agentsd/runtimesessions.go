package agentsd

import (
	"context"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/agentsd/acp"
	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

// The conversations a runtime holds that the app did not start (DaemonCore+Runtimes):
// listed for a folder, taken over as an agent of the app's, or deleted from the runtime.

// handshake starts the runtime in the root only to ask it something.
func (d *Daemon) handshake(ctx context.Context, runtimeID string, sink acp.Sink) (*acp.Session, *runtimeDef, error) {
	return d.handshakeAs(ctx, runtimeID, nil, sink)
}

// handshakeAs is handshake on an added account (#840), nil for the runtime's own.
func (d *Daemon) handshakeAs(ctx context.Context, runtimeID string, account *wire.AccountProfile, sink acp.Sink) (*acp.Session, *runtimeDef, error) {
	rt := runtimeByID(runtimeID)
	if rt == nil {
		return nil, nil, &Error{Code: CodeRuntimeNotFound, Message: "There is no runtime called " + runtimeID + "."}
	}
	launch, err := d.launchAs(rt, d.Store.Loc.Root, account)
	if err != nil {
		return nil, nil, err
	}
	s, err := acp.Handshake(ctx, launch, sink)
	if err != nil {
		return nil, nil, &Error{Code: CodeRuntimeWillNotStart, Message: rt.Name + " did not start: " + err.Error()}
	}
	return s, rt, nil
}

// listRuntimeSessions is sessions/list: the runtime's conversations in a folder, each said
// held when an agent here already has it.
func (d *Daemon) listRuntimeSessions(ctx context.Context, r wire.SessionsListRequest) ([]wire.RuntimeSession, error) {
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	s, rt, err := d.handshake(ctx, r.RuntimeID, &probe{commands: make(chan []wire.SlashCommand, 1)})
	if err != nil {
		return nil, err
	}
	defer s.Stop()
	if !s.CanList() {
		return nil, &Error{Code: CodeNotSupported, Message: rt.Name + " cannot list the conversations it holds."}
	}
	path := store.FolderPath(r.Cwd)
	infos, err := s.ListSessions(ctx, path)
	if err != nil {
		return nil, &Error{Code: CodeServer, Message: err.Error()}
	}
	held := map[string]bool{}
	for _, a := range d.Store.Agents() {
		if a.RuntimeID == r.RuntimeID && a.RuntimeSessionID != nil {
			held[*a.RuntimeSessionID] = true
		}
	}
	out := []wire.RuntimeSession{}
	for _, i := range infos {
		cwd := i.Cwd
		if cwd == "" {
			cwd = path
		}
		dirs := []wire.URL{}
		for _, a := range i.AdditionalDirectories {
			dirs = append(dirs, store.FolderURL(a))
		}
		isHeld := held[string(i.SessionId)]
		rs := wire.RuntimeSession{SessionID: string(i.SessionId), Cwd: store.FolderURL(cwd), AdditionalDirectories: dirs,
			Title: i.Title, IsHeld: &isHeld}
		if i.UpdatedAt != nil {
			if t, err := time.Parse(time.RFC3339Nano, *i.UpdatedAt); err == nil {
				at := wire.DateOf(t)
				rs.UpdatedAt = &at
			}
		}
		out = append(out, rs)
	}
	return out, nil
}

// deleteRuntimeSession is sessions/delete, once confirmed: the runtime's copy goes, and
// an agent that had it says so and starts afresh next time.
func (d *Daemon) deleteRuntimeSession(ctx context.Context, r wire.DeleteSessionRequest) error {
	if r.Confirmed == nil || !*r.Confirmed {
		return &Error{Code: wire.FailureNotConfirmed, Message: "Deleting a conversation cannot be undone. Confirm it first."}
	}
	ctx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	s, rt, err := d.handshake(ctx, r.RuntimeID, &probe{commands: make(chan []wire.SlashCommand, 1)})
	if err != nil {
		return err
	}
	defer s.Stop()
	if !s.CanDelete() {
		return &Error{Code: CodeNotSupported, Message: rt.Name + " cannot delete a conversation."}
	}
	if err := s.DeleteSession(ctx, r.SessionID); err != nil {
		return &Error{Code: CodeServer, Message: err.Error()}
	}
	for _, a := range d.Store.Agents() {
		if a.RuntimeID == r.RuntimeID && a.RuntimeSessionID != nil && *a.RuntimeSessionID == r.SessionID {
			d.change(a.ID, func(a *wire.Agent) { a.RuntimeSessionID = nil })
			d.record(a.ID, runtimeNote("The runtime's copy of this conversation was deleted."))
		}
	}
	return nil
}

// adoptSession is sessions/adopt: the conversation becomes an agent of the app's, finished,
// its replay its transcript. One already taken over is the agent that took it.
func (d *Daemon) adoptSession(ctx context.Context, r wire.AdoptRequest) (wire.UUID, error) {
	for _, a := range d.Store.Agents() {
		if a.RuntimeID == r.RuntimeID && a.RuntimeSessionID != nil && *a.RuntimeSessionID == r.SessionID {
			return a.ID, nil
		}
	}
	rt := runtimeByID(r.RuntimeID)
	if rt == nil {
		return "", &Error{Code: CodeRuntimeNotFound, Message: "There is no runtime called " + r.RuntimeID + "."}
	}
	path := store.FolderPath(r.Cwd)
	if !isDir(path) {
		return "", &Error{Code: CodeFolderGone, Message: path + " is not there any more."}
	}
	if err := d.needsSignIn(r.RuntimeID); err != nil {
		return "", err
	}
	launch, err := d.launchFor(rt, path)
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()
	id := store.NewUUID()
	l := d.live(id)
	sink := &replaySink{live: l}
	s, err := acp.Handshake(ctx, launch, sink)
	if err != nil {
		return "", &Error{Code: CodeRuntimeWillNotStart, Message: rt.Name + " did not start: " + err.Error()}
	}
	defer s.Stop()
	if !s.CanLoad() {
		return "", &Error{Code: CodeNotSupported, Message: rt.Name + " cannot hand a conversation over."}
	}
	t := now()
	sid := r.SessionID
	ended := wire.EndedReasonEndTurn
	a := wire.Agent{ID: id, RuntimeID: r.RuntimeID, Cwd: store.FolderURL(path), State: wire.AgentStateFinished,
		EndedReason: &ended, RuntimeSessionID: &sid, StartOptions: wire.StartOptions{Values: map[string]wire.JSONValue{}, ExtraArguments: []string{}},
		AdvertisedOptions: []wire.ConfigOption{}, AvailableCommands: []wire.SlashCommand{},
		CreatedAt: t, LastActivityAt: t, MadeInRoot: &d.Store.RootID}
	if err := d.Store.Save(a); err != nil {
		return "", err
	}
	d.tellChanged(a, nil)
	d.folderChanged(folderPath(&a))
	d.record(id, runtimeNote("Picked up a conversation "+rt.Name+" was already holding."))
	err = s.LoadRecorded(ctx, sid, path, d.sessionMCP(path), sessionMeta(r.RuntimeID))
	l.flushHeld()
	sink.flush()
	d.dropAppTokens(id)
	if err != nil {
		d.record(id, notice("error", rt.Name+" did not hand the conversation over", err.Error()))
		return id, nil
	}
	if opts := configOptions(s.NewResult.ConfigOptions); len(opts) > 0 {
		d.change(id, func(a *wire.Agent) { a.AdvertisedOptions = d.markOptions(a.RuntimeID, withAppOptions(a.RuntimeID, a.StartOptions.Values, opts)) })
	}
	return id, nil
}

// replaySink records a loaded conversation's replay on the agent, the person's words with
// the rest: each run of the person's chunks as one message.
type replaySink struct {
	*live
	user strings.Builder
}

func (r *replaySink) Update(n sdk.SessionNotification) {
	if u := n.Update.UserMessageChunk; u != nil {
		// The reply before it, held back for a token's sake (#1001), goes first.
		r.live.flushHeld()
		if u.Content.Text != nil {
			r.user.WriteString(u.Content.Text.Text)
		}
		return
	}
	r.flush()
	r.live.Update(n)
}

func (r *replaySink) flush() {
	if r.user.Len() == 0 {
		return
	}
	from := wire.PromptOriginPerson
	r.d.record(r.id, wire.TranscriptEntryKind{UserMessage: &wire.TranscriptEntryKindUserMessage{Value: r.user.String(), From: &from}})
	r.user.Reset()
}

func (d *Daemon) registerRuntimeSessions() {
	On(d, wire.CallSessionsList, func(ctx context.Context, c *Client, r wire.SessionsListRequest) ([]wire.RuntimeSession, error) {
		return d.listRuntimeSessions(ctx, r)
	})
	On(d, wire.CallSessionsAdopt, func(ctx context.Context, c *Client, r wire.AdoptRequest) (wire.UUID, error) {
		return d.adoptSession(ctx, r)
	})
	On(d, wire.CallSessionsDelete, func(ctx context.Context, c *Client, r wire.DeleteSessionRequest) (wire.Empty, error) {
		return wire.Empty{}, d.deleteRuntimeSession(ctx, r)
	})
}
