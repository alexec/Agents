package controlplane

import (
	"context"
	"encoding/json"
	"strings"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
	"github.com/alexec/agents/Go/internal/controlplane/records"
	"github.com/alexec/agents/Go/wire"
)

// Who did what (#996, spec 736 US8): the actor the control plane knows each client by,
// written on each channel it opens and on each entry the audit keeps, never taken from
// the client. Each client is its person's (#994).

// actorFor is who a client is: its person (#994) and the client. A name that is not a
// client's (a code, a host) is the local owner alone.
func (s *Service) actorFor(client string) wire.AuditActor {
	owner := s.localOwner()
	actor := wire.AuditActor{User: owner}
	if c := s.records.Client(strings.ToUpper(client)); c != nil {
		actor.User = s.PersonOf(c.ID)
		id, name := wire.UUID(c.ID), c.Name
		actor.Client, actor.ClientName = &id, &name
	}
	if actor.User == owner {
		name := audit.LocalOwnerName
		actor.UserName = &name
	} else if name := s.personName(actor.User); name != "" {
		actor.UserName = &name
	}
	return actor
}

func (s *Service) auditLog() *audit.Log { return &audit.Log{Store: s.cfg.Store} }

// audited keeps a call the audit keeps, on its own goroutine: the router holds its lock.
func (s *Service) audited(from Caller, host, method string, params json.RawMessage) {
	action, ok := audit.Action(method, host != "")
	if !ok {
		return
	}
	actor, target := s.actorFor(from.Client), audit.Target(params)
	go func() {
		if err := s.auditLog().Write(context.Background(), actor, method, action, host, target); err != nil {
			s.log("audit: could not keep " + method + ": " + err.Error())
		}
	}()
}

func (s *Service) startAudit() {
	s.router.SetAudit(func(from Caller) *wire.AuditActor {
		actor := s.actorFor(from.Client)
		return &actor
	}, s.audited)
}

// auditMethod answers audit/list, audit/export and control/setAuditDays (contracts/
// control-api.md). A member sees only their own entries; only an admin exports or sets
// the days.
func (m *Methods) auditMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	actor := m.s.actorFor(from.Client)
	admin := m.s.isAdmin(actor.User)
	days := audit.Days(m.records.Settings())
	switch method {
	case "control/setAuditDays":
		request, err := require[wire.AuditDays](params, "AuditDays")
		if err != nil {
			return nil, err
		}
		if !admin {
			return nil, fail(notPermitted, "Only an admin can change how long the audit is kept.")
		}
		if request.Days < 1 || request.Days > audit.MostDays {
			return nil, fail(invalidParams, "Keep the audit for 1 to %d days.", audit.MostDays)
		}
		n, now := int(request.Days), time.Now()
		if _, err := m.records.ChangeSettings(ctx, func(s *records.Settings) { audit.SetDays(s, n, now) }); err != nil {
			return nil, err
		}
		return request, nil
	case "audit/export":
		if !admin {
			return nil, fail(notPermitted, "Only an admin can export the audit.")
		}
	}
	var request wire.AuditQuery
	if len(params) > 0 && string(params) != "null" {
		var err error
		if request, err = require[wire.AuditQuery](params, "AuditQuery"); err != nil {
			return nil, err
		}
	}
	q := audit.NewQuery(request, days, time.Now(), method == "audit/export")
	if !admin {
		q.User = actor.User
	}
	entries, more, err := m.s.auditLog().List(ctx, q, m.s.actorFor)
	if err != nil {
		return nil, fail(storeUnavailable, "The audit could not be read: %v", err)
	}
	if method == "audit/export" {
		return wire.AuditExport{Lines: audit.Lines(entries), Count: int64(len(entries))}, nil
	}
	return wire.AuditList{Entries: entries, Days: int64(days), More: more, Admin: admin}, nil
}
