package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/kms"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// The audit's sinks (#1001, T8 slice d2), as an admin sets them: syslog or HTTP places
// that get each audit entry as it is written (audit.Sinks). They are kept in the store,
// in auditSinksKey, an HTTP sink's token sealed with the keeper for secrets, so every copy
// of the control plane sends to the same sinks: each reads the record again every
// auditSinksEvery and sends what it writes itself.
//
// Decided: the sinks are a record of their own, not part of control.json, because a token
// is sealed and control.json is read by every copy for everything else.

const (
	auditSinksKey   = "v1/audit-sinks.json"
	auditSinksEvery = 30 * time.Second
)

// auditSinksRecord is the record: the sinks with no token, and the tokens sealed as one
// envelope of {address: token}.
type auditSinksRecord struct {
	Sinks  []wire.AuditSink `json:"sinks"`
	Tokens *kms.Sealed      `json:"tokens,omitempty"`
}

// auditSinkState is this copy's sinks and the record's tag they were set from.
type auditSinkState struct {
	audit.Sinks
	mu  sync.Mutex
	tag string
}

func newAuditSinkState(name, copyID string) *auditSinkState {
	return &auditSinkState{Sinks: audit.Sinks{From: audit.SinkFrom{Host: name, ProcID: copyID}}}
}

// followAuditSinks sets this copy's sinks from the record now, and again whenever it
// changes, until the service stops.
func (s *Service) followAuditSinks() {
	t := time.NewTicker(auditSinksEvery)
	defer t.Stop()
	defer s.auditSinks.Stop()
	for {
		if err := s.loadAuditSinks(context.Background()); err != nil {
			s.log("audit: could not read the sinks: " + err.Error())
		}
		select {
		case <-s.stop:
			return
		case <-t.C:
		}
	}
}

// loadAuditSinks sets the sinks from the record when it changed since the last time.
func (s *Service) loadAuditSinks(ctx context.Context) error {
	object, err := s.cfg.Store.Get(ctx, auditSinksKey)
	if err != nil {
		return err
	}
	tag := ""
	if object != nil {
		tag = object.ETag
	}
	s.auditSinks.mu.Lock()
	defer s.auditSinks.mu.Unlock()
	if tag == s.auditSinks.tag {
		return nil
	}
	sinks, err := s.openAuditSinks(ctx, object)
	if err != nil {
		return err
	}
	s.auditSinks.Set(sinks)
	s.auditSinks.tag = tag
	return nil
}

// openAuditSinks is the record's sinks with their tokens.
func (s *Service) openAuditSinks(ctx context.Context, object *store.Object) ([]wire.AuditSink, error) {
	if object == nil {
		return nil, nil
	}
	var r auditSinksRecord
	if err := json.Unmarshal(object.Data, &r); err != nil {
		return nil, err
	}
	tokens := map[string]string{}
	if r.Tokens != nil {
		plain, err := s.users.OpenFor(ctx, r.Tokens, []byte(auditSinksKey))
		if err != nil {
			return nil, err
		}
		if err := json.Unmarshal(plain, &tokens); err != nil {
			return nil, err
		}
	}
	for i, sink := range r.Sinks {
		if token, ok := tokens[strings.TrimSpace(sink.Address)]; ok {
			r.Sinks[i].Token = &token
		}
	}
	return r.Sinks, nil
}

// auditSinksMethod answers audit/sinks and audit/setSinks: an admin's only.
func (m *Methods) auditSinksMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	if !m.s.isAdmin(m.s.actorFor(from.Client).User) {
		return nil, fail(notPermitted, "Only an admin can see or set the audit's sinks.")
	}
	if method == "audit/setSinks" {
		request, err := require[wire.AuditSinks](params, "AuditSinks")
		if err != nil {
			return nil, err
		}
		if err := m.s.setAuditSinks(ctx, request.Sinks); err != nil {
			return nil, err
		}
	}
	return wire.AuditSinksState{Sinks: m.s.auditSinks.State()}, nil
}

// setAuditSinks checks and keeps the sinks, then sends to them from this copy at once.
// A sink given with no token keeps the one it had at the same address.
func (s *Service) setAuditSinks(ctx context.Context, sinks []wire.AuditSink) error {
	if len(sinks) > audit.SinksMost {
		return fail(invalidParams, "Set %d sinks at most.", audit.SinksMost)
	}
	object, err := s.cfg.Store.Get(ctx, auditSinksKey)
	if err != nil {
		return fail(storeUnavailable, "The sinks could not be read: %v", err)
	}
	before, err := s.openAuditSinks(ctx, object)
	if err != nil {
		return fail(storeUnavailable, "The sinks could not be read: %v", err)
	}
	had := map[string]string{}
	for _, b := range before {
		if b.Token != nil {
			had[strings.TrimSpace(b.Address)] = *b.Token
		}
	}
	r := auditSinksRecord{Sinks: []wire.AuditSink{}}
	tokens := map[string]string{}
	seen := map[string]bool{}
	for _, sink := range sinks {
		sink.Address, sink.HasToken = strings.TrimSpace(sink.Address), nil
		if err := audit.CheckSink(sink); err != nil {
			return fail(invalidParams, "%s.", capitalised(err.Error()))
		}
		if seen[sink.Address] {
			return fail(invalidParams, "%s is there twice.", sink.Address)
		}
		seen[sink.Address] = true
		if sink.Token != nil && *sink.Token != "" {
			tokens[sink.Address] = *sink.Token
		} else if token, ok := had[sink.Address]; ok && sink.Kind == wire.AuditSinkKindHttp {
			tokens[sink.Address] = token
		}
		sink.Token = nil
		r.Sinks = append(r.Sinks, sink)
	}
	if len(tokens) > 0 {
		plain, _ := json.Marshal(tokens)
		if r.Tokens, err = s.users.SealFor(ctx, plain, []byte(auditSinksKey)); err != nil {
			return fail(storeUnavailable, "The token could not be sealed: %v", err)
		}
	}
	data, _ := json.Marshal(r)
	if _, err := s.cfg.Store.Put(ctx, auditSinksKey, data, store.Always); err != nil {
		return fail(storeUnavailable, "The sinks could not be kept: %v", err)
	}
	if err := s.loadAuditSinks(ctx); err != nil {
		return fail(storeUnavailable, "The sinks could not be read back: %v", err)
	}
	return nil
}

func capitalised(s string) string {
	if s == "" {
		return s
	}
	return strings.ToUpper(s[:1]) + s[1:]
}
