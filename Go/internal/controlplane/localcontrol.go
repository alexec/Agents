package controlplane

import (
	"context"
	"encoding/json"

	"github.com/agentloops-dev/agent-loops/Go/internal/controlplane/web"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The controls of a control plane that runs on a person's Mac (#4252): the web page's
// Settings ▸ Control plane ▸ Overview has them as the Mac window has them. An admin's.

// localMethod is control/restart, control/retryWeb and control/setWeb.
func (m *Methods) localMethod(ctx context.Context, method string, params json.RawMessage, from Caller) (any, error) {
	if !m.s.isAdmin(m.s.actorFor(from.Client).User) {
		return nil, fail(notPermitted, "Only an admin can do this to the control plane.")
	}
	switch method {
	case "control/restart":
		if m.s.cfg.Restart == nil {
			return nil, fail(notSupported, "Nothing would start this control plane again, so it can't restart itself. Restart it where it runs.")
		}
		// After the answer has gone: every client and host connects again.
		go m.s.cfg.Restart()
		return wire.Empty{}, nil
	case "control/retryWeb":
		if m.s.cfg.Web == nil {
			return nil, fail(notSupported, "This control plane serves no page to browsers on its machine.")
		}
		m.s.RetryWeb()
		return m.s.webStatus(), nil
	case "control/setWeb":
		request, err := require[wire.WebServe](params, "WebServe")
		if err != nil {
			return nil, err
		}
		if m.s.cfg.Web == nil {
			return nil, fail(notSupported, "This control plane serves no page to browsers on its machine.")
		}
		return m.s.setWeb(request.On)
	}
	return nil, fail(methodNotFound, "%s", method)
}

// webIsOff says the person turned the listener off.
func (s *Service) webIsOff() bool {
	status := s.webStatus()
	return status.Reason != nil && *status.Reason == web.ReasonOff
}

// webStatus is how the listener stands, as control/status says it.
func (s *Service) webStatus() web.Status {
	s.methods.mu.Lock()
	defer s.methods.mu.Unlock()
	if s.methods.web == nil {
		return web.Status{}
	}
	return *s.methods.web
}

// setWeb turns the listener on or off and keeps that (071 FR-002). Off closes the
// listener only: a page open through it stays connected, so it can turn it on again.
func (s *Service) setWeb(on bool) (web.Status, error) {
	s.webSwitch.Lock()
	defer s.webSwitch.Unlock()
	if s.cfg.WebSwitched != nil {
		if err := s.cfg.WebSwitched(on); err != nil {
			return web.Status{}, fail(internalError, "The control plane couldn’t keep that: %v", err)
		}
	}
	s.mu.Lock()
	listener := s.loopback
	if !on {
		s.loopback = nil
	}
	s.mu.Unlock()
	switch {
	case !on:
		if listener != nil {
			listener.Stop()
		}
		s.sayWeb(web.Off(s.cfg.Web.Port))
	case listener == nil:
		s.startWeb()
	}
	return s.webStatus(), nil
}
