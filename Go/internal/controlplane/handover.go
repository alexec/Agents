package controlplane

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controllink"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// The handover (058, research R16), the copy's side, as Handover.swift has it: a copy
// moved to another machine without anyone pairing again. Agents Host drives it with
// `agents-control handover …` (the Swift tool), which proves itself as a copy named
// handover-<id> and calls these methods; Relay for my devices (#809) goes the same way.

// handoverPrefix is Handover.prefix: the copy name a handover's driver proves.
const handoverPrefix = "handover-"

// longestForwarding is Handover.longestForwarding: never for ever, 30 days at most.
const longestForwarding = 30 * 24 * time.Hour

// Phases, as Handover.Phase says them.
const (
	phaseServing    = "serving"
	phaseReceiving  = "receiving"
	phaseFrozen     = "frozen"
	phaseForwarding = "forwarding"
)

// phaseBox is where this copy is in a handover.
type phaseBox struct {
	mu    sync.Mutex
	phase string
	until time.Time
}

func (p *phaseBox) now() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.phase
}

func (p *phaseBox) set(phase string) {
	p.mu.Lock()
	p.phase = phase
	p.mu.Unlock()
}

func (p *phaseBox) forwardingUntil() time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.until
}

func (p *phaseBox) setUntil(t time.Time) {
	p.mu.Lock()
	p.until = t
	p.mu.Unlock()
}

// handoverSession is Handover.session: one driver's requests, answered in turn.
func (s *Service) handoverSession(conn *Conn) {
	// Not a member: announcing or forwarding leaves it open.
	s.mu.Lock()
	delete(s.sockets, conn)
	s.mu.Unlock()
	defer conn.Close()
	for {
		line, err := conn.Read(context.Background())
		if err != nil {
			return
		}
		m, ok := decode(line)
		if !ok || !m.isRequest() {
			continue
		}
		result, err := s.handoverAnswer(m.Method, m.Params)
		if err != nil {
			conn.Send(replyError(m.ID, err))
		} else {
			conn.Send(reply(m.ID, result))
		}
	}
}

func refuseHandover(words string) error { return fail(invalidRequest, "%s", words) }

const invalidRequest = -32600

func (s *Service) handoverAnswer(method string, params json.RawMessage) (any, error) {
	ctx := context.Background()
	st := s.cfg.Store
	phase := s.phase.now()
	var p map[string]json.RawMessage
	json.Unmarshal(params, &p)
	text := func(k string) string {
		var v string
		json.Unmarshal(p[k], &v)
		return v
	}
	flag := func(k string) bool {
		var v bool
		json.Unmarshal(p[k], &v)
		return v
	}
	switch method {
	case "handover/status":
		return s.handoverStatus(), nil
	case "store/list":
		if phase == phaseServing {
			return nil, refuseHandover("Freeze this copy before reading its store.")
		}
		prefix := text("prefix")
		if prefix == "" {
			prefix = "v1/"
		}
		keys, err := st.List(ctx, prefix)
		if err != nil {
			return nil, err
		}
		out := []map[string]string{}
		for _, k := range keys {
			out = append(out, map[string]string{"key": k.Key, "etag": k.ETag})
		}
		return out, nil
	case "store/get":
		if phase == phaseServing {
			return nil, refuseHandover("Freeze this copy before reading its store.")
		}
		key := text("key")
		if key == "" {
			return nil, refuseHandover("Say which key.")
		}
		object, err := st.Get(ctx, key)
		if err != nil {
			return nil, err
		}
		if object == nil {
			return nil, nil
		}
		return map[string]string{"data": base64.StdEncoding.EncodeToString(object.Data), "etag": object.ETag}, nil
	case "store/put":
		// Create only, and only into a copy that is receiving.
		if phase != phaseReceiving {
			return nil, refuseHandover("Only a receiving copy takes records.")
		}
		key := text("key")
		data, err := base64.StdEncoding.DecodeString(text("data"))
		if !strings.HasPrefix(key, "v1/") || err != nil || p["data"] == nil {
			return nil, refuseHandover("Say the key and the data.")
		}
		return st.Put(ctx, key, data, store.Absent)
	case "handover/mark":
		// A bucket move has no copy to check, only that both read one store.
		if phase == phaseReceiving {
			return nil, refuseHandover("A receiving copy has no store to share.")
		}
		nonce := text("nonce")
		if nonce == "" || strings.IndexFunc(nonce, func(r rune) bool {
			return !(r == '-' || r >= '0' && r <= '9' || r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z')
		}) >= 0 {
			return nil, refuseHandover("Say the mark.")
		}
		key := "handover/mark-" + nonce
		if flag("leave") {
			if _, err := st.Put(ctx, key, []byte(nonce), store.Absent); err != nil {
				return nil, err
			}
			return map[string]bool{"found": true}, nil
		}
		object, err := st.Get(ctx, key)
		if err != nil {
			return nil, err
		}
		if object != nil {
			st.Delete(ctx, key)
		}
		return map[string]bool{"found": object != nil}, nil
	case "handover/announce":
		// The new place goes after the ones members have now (R16 step 2).
		if phase != phaseServing {
			return nil, refuseHandover("Announce from a copy that is serving.")
		}
		var endpoint records.Endpoint
		if json.Unmarshal(p["endpoint"], &endpoint) != nil || !acceptableEndpoint(endpoint) {
			return nil, refuseHandover("Say the new place: https, with a pin or none.")
		}
		// A host on a build from before lists would be left behind for good: named, and
		// refused unless the driver insists (R16, T129).
		if !flag("force") {
			var behind []string
			for _, h := range s.records.Hosts() {
				if h.KnownEpoch == nil {
					behind = append(behind, h.Name+" ("+h.Version+")")
				}
			}
			if len(behind) > 0 {
				return nil, refuseHandover("Not moving: " + strings.Join(behind, ", ") +
					" can't follow a move. Update it first, or remove it and add it again afterwards.")
			}
		}
		current := []records.Endpoint{s.ownEndpoint()}
		if settings := s.records.Settings(); settings != nil && len(settings.Endpoints) > 0 {
			current = settings.Endpoints
		}
		var list []records.Endpoint
		for _, e := range current {
			if e.URL != endpoint.URL {
				list = append(list, e)
			}
		}
		if err := s.changeEndpoints(append(list, endpoint)); err != nil {
			return nil, err
		}
		return s.handoverStatus(), nil
	case "handover/withdraw":
		// Back to answering only here, as if nothing had been announced.
		if phase != phaseServing && phase != phaseFrozen {
			return nil, refuseHandover("Nothing to withdraw here.")
		}
		if err := s.changeEndpoints([]records.Endpoint{s.ownEndpoint()}); err != nil {
			return nil, err
		}
		s.methods.setFrozen(false)
		s.phase.set(phaseServing)
		return s.handoverStatus(), nil
	case "handover/freeze":
		if phase != phaseServing {
			return nil, refuseHandover("Only a serving copy freezes.")
		}
		s.methods.setFrozen(true)
		s.phase.set(phaseFrozen)
		s.log("frozen for a handover: records won't change here")
		return s.handoverStatus(), nil
	case "handover/unfreeze":
		if phase != phaseFrozen {
			return nil, refuseHandover("This copy isn't frozen.")
		}
		s.methods.setFrozen(false)
		s.phase.set(phaseServing)
		s.log("unfrozen: the handover was called off")
		return s.handoverStatus(), nil
	case "handover/stop":
		// Stop Forwarding: anyone still to hear pairs again.
		if phase != phaseForwarding {
			return nil, refuseHandover("This copy isn't forwarding.")
		}
		s.phase.setUntil(time.Now())
		s.markForwarding(time.Now())
		s.log("forwarding stopped")
		return s.handoverStatus(), nil
	case "handover/forward":
		// Handed over (R16 step 5): only the new list, given to whoever still comes.
		if phase != phaseFrozen {
			return nil, refuseHandover("Freeze and copy before forwarding.")
		}
		var list []records.Endpoint
		if json.Unmarshal(p["endpoints"], &list) != nil || len(list) == 0 {
			return nil, refuseHandover("Say where members go now.")
		}
		for _, e := range list {
			if !acceptableEndpoint(e) {
				return nil, refuseHandover("Say where members go now.")
			}
		}
		longest := time.Now().Add(longestForwarding)
		until := longest
		var asked wire.Date
		if p["until"] != nil && json.Unmarshal(p["until"], &asked) == nil && asked.Time().Before(longest) {
			until = asked.Time()
		}
		if err := s.changeEndpoints(list); err != nil {
			return nil, err
		}
		s.phase.setUntil(until)
		s.phase.set(phaseForwarding)
		if err := s.markForwarding(until); err != nil {
			return nil, err
		}
		var urls []string
		for _, e := range list {
			urls = append(urls, e.URL)
		}
		s.log(fmt.Sprintf("forwarding until %s: members are told %s", until.UTC().Format(time.RFC3339), strings.Join(urls, ", ")))
		return s.handoverStatus(), nil
	case "handover/take":
		// The receiving copy takes over what was copied into it (R16 step 5).
		if phase != phaseReceiving {
			return nil, refuseHandover("Only a receiving copy takes over.")
		}
		if object, err := st.Get(ctx, records.SettingsKey); err != nil || object == nil {
			return nil, refuseHandover("Nothing has been copied here yet.")
		}
		if err := s.takeUp(ctx); err != nil {
			return nil, err
		}
		if err := s.setEndpoints([]records.Endpoint{s.ownEndpoint()}); err != nil {
			return nil, err
		}
		s.phase.set(phaseServing)
		if s.mesh != nil {
			s.startMesh()
		}
		s.log("took over the control plane at " + s.cfg.URL)
		return s.handoverStatus(), nil
	case "relay/set":
		if phase != phaseServing {
			return nil, refuseHandover("A relay is switched on or off at a copy that is serving.")
		}
		request, err := require[wire.MachineRelayRequest](params, "MachineRelayRequest")
		if err != nil {
			return nil, refuseHandover("Say the relay host and whether it relays.")
		}
		if err := s.methods.setRelay(ctx, request); err != nil {
			return nil, err
		}
		s.announce("hostEnrolled", string(request.Host), "agents-host")
		return map[string]any{}, nil
	}
	return nil, fail(methodNotFound, "%s is not part of a handover.", method)
}

func (s *Service) ownEndpoint() records.Endpoint {
	e := records.Endpoint{URL: s.cfg.URL}
	if s.cfg.Pin != "" {
		pin := s.cfg.Pin
		e.Pin = &pin
	}
	return e
}

// acceptableEndpoint is ControlEndpoint.isAcceptable: what a code would accept, https,
// or http on this machine only, and a pin that is a SHA-256 in base64url.
func acceptableEndpoint(e records.Endpoint) bool {
	u, err := url.Parse(e.URL)
	if err != nil || u.Hostname() == "" {
		return false
	}
	scheme := strings.ToLower(u.Scheme)
	loopback := u.Hostname() == "127.0.0.1" || u.Hostname() == "localhost" || u.Hostname() == "::1"
	if !(scheme == "https" || scheme == "wss" || scheme == "http" && loopback) {
		return false
	}
	if e.Pin != nil {
		b, err := controllink.FromB64URL(*e.Pin)
		return err == nil && len(b) == 32
	}
	return true
}

// setEndpoints is ControlMethods.setEndpoints: where the control plane answers from now
// on, under a new epoch so each member takes it.
func (s *Service) setEndpoints(list []records.Endpoint) error {
	_, err := s.records.ChangeSettings(context.Background(), func(settings *records.Settings) {
		settings.Endpoints = list
		epoch := 1
		if settings.Epoch != nil {
			epoch = *settings.Epoch + 1
		}
		settings.Epoch = &epoch
	})
	return err
}

// changeEndpoints sets the list, tells every copy, and closes every member's socket so
// each reconnects and is given it in ok.
func (s *Service) changeEndpoints(list []records.Endpoint) error {
	if err := s.setEndpoints(list); err != nil {
		return err
	}
	epoch := 0
	if settings := s.records.Settings(); settings != nil && settings.Epoch != nil {
		epoch = *settings.Epoch
	}
	s.announce("endpointsChanged", fmt.Sprint(epoch), "handover")
	s.closeMembers()
	return nil
}

func (s *Service) closeMembers() {
	s.mu.Lock()
	sockets := s.sockets
	s.sockets = map[*Conn]bool{}
	s.mu.Unlock()
	for c := range sockets {
		c.Close()
	}
}

// handoverStatus is Handover.Status: what this copy says of itself.
func (s *Service) handoverStatus() wire.HandoverStatus {
	phase := s.phase.now()
	object, _ := s.cfg.Store.Get(context.Background(), records.SettingsKey)
	status := wire.HandoverStatus{Phase: phase, ControlKey: s.publicKey(), HasRecords: object != nil,
		Endpoints: []records.Endpoint{}, Members: []wire.HandoverMember{}}
	if phase != phaseReceiving {
		connected := map[string]bool{}
		for _, c := range s.router.ConnectedClients() {
			connected[c] = true
		}
		for _, c := range s.records.Clients() {
			online := connected[c.ID]
			status.Members = append(status.Members, wire.HandoverMember{ID: c.ID, Name: c.Name, Kind: c.Kind,
				KnownEpoch: int64Of(c.KnownEpoch), Online: &online, LastSeen: stampDate(c.LastSeen)})
		}
		for _, h := range s.records.Hosts() {
			kind := "host"
			if h.Relay != nil {
				kind = "relay"
			}
			state, _ := s.router.State(h.ID)
			online := state.online()
			version := h.Version
			status.Members = append(status.Members, wire.HandoverMember{ID: h.ID, Name: h.Name, Kind: kind,
				KnownEpoch: int64Of(h.KnownEpoch), Version: &version, Online: &online})
		}
		if settings := s.records.Settings(); settings != nil {
			status.Endpoints = currentEndpoints(settings)
			status.Epoch = int64Of(settings.Epoch)
		}
	}
	if phase == phaseForwarding {
		status.ForwardingUntil = new(dateOf(s.phase.forwardingUntil()))
	}
	return status
}

// forwardingKey is where a forwarding copy notes until when, so a restart forwards
// again: one per copy's address.
func (s *Service) forwardingKey() string {
	return "handover/forwarding-" + controllink.B64URL([]byte(s.cfg.URL))
}

func (s *Service) markForwarding(until time.Time) error {
	data, err := records.Encode(map[string]records.Stamp{"until": records.At(until)})
	if err != nil {
		return err
	}
	ctx := context.Background()
	held, err := s.cfg.Store.Get(ctx, s.forwardingKey())
	if err != nil {
		return err
	}
	when := store.Absent
	if held != nil {
		when = store.Matching(held.ETag)
	}
	_, err = s.cfg.Store.Put(ctx, s.forwardingKey(), data, when)
	return err
}

// resumeForwardingIfMarked is a copy that was forwarding when it stopped forwarding
// again, unless told to serve (--no-forwarding).
func (s *Service) resumeForwardingIfMarked(ctx context.Context) error {
	object, err := s.cfg.Store.Get(ctx, s.forwardingKey())
	if err != nil || object == nil {
		return err
	}
	var mark struct {
		Until *records.Stamp `json:"until"`
	}
	if s.cfg.NoForwarding || json.Unmarshal(object.Data, &mark) != nil || mark.Until == nil {
		s.cfg.Store.Delete(ctx, s.forwardingKey())
		return nil
	}
	s.methods.setFrozen(true)
	s.phase.setUntil(mark.Until.Time)
	s.phase.set(phaseForwarding)
	s.log("forwarding again until " + mark.Until.UTC().Format(time.RFC3339) + ", as before it stopped")
	return nil
}
