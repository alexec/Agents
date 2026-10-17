package web

import (
	"errors"
	"fmt"
	"syscall"

	"github.com/alexec/agents/Go/wire"
)

// Status is DaemonAPI.WebRemoteStatus (071 R3): whether the control plane serves the web
// remote on its loopback port. Agents Host's row and the window's Settings show it. Port
// is the port asked for (8792 for Agents Host's copy); Reason is why not, when it is not
// served (ReasonPortInUse, ReasonBuild or ReasonFailed); Detail is the error as the
// control plane met it.
type Status = wire.WebRemoteStatus

// The reasons of WebRemoteStatus.
const (
	ReasonPortInUse = "portInUse"
	ReasonBuild     = "build"
	ReasonFailed    = "failed"
)

// Address is WebRemoteStatus.address.
func Address(s Status) string { return OriginFor(int(s.Port)) }

// Summary is WebRemoteStatus.summary: the status in plain words, for the row that would
// otherwise give the address.
func Summary(s Status) string {
	if s.Served {
		return fmt.Sprintf("At %s, for a browser on this Mac only.", Address(s))
	}
	reason := ""
	if s.Reason != nil {
		reason = *s.Reason
	}
	switch reason {
	case ReasonPortInUse:
		return fmt.Sprintf("Not serving: port %d is in use by another app.", s.Port)
	case ReasonBuild:
		return "Not serving: this copy of Agents Host’s web app is damaged or missing."
	default:
		detail := ""
		if s.Detail != nil && *s.Detail != "" {
			detail = " (" + *s.Detail + ")"
		}
		return fmt.Sprintf("Not serving: port %d couldn’t be opened%s.", s.Port, detail)
	}
}

// StatusOf is the status ControlService.startWeb reports after Start. asked is the port
// in Config. A served listener reports its own port. A build that does not match its
// manifest is ReasonBuild. A port in use (on 127.0.0.1 or ::1) is ReasonPortInUse. Any
// other error is ReasonFailed.
func StatusOf(asked int, l *Listener, err error) Status {
	if err == nil && l != nil {
		return Status{Port: int64(l.Port()), Served: true}
	}
	if err == nil {
		err = errors.New("no listener")
	}
	var files *FilesError
	switch {
	case errors.As(err, &files):
		return Status{Port: int64(asked), Reason: new(ReasonBuild), Detail: new(err.Error())}
	case errors.Is(err, syscall.EADDRINUSE):
		return Status{Port: int64(asked), Reason: new(ReasonPortInUse), Detail: new(err.Error())}
	default:
		return Status{Port: int64(asked), Reason: new(ReasonFailed), Detail: new(err.Error())}
	}
}
