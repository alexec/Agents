package web

import (
	"errors"
	"fmt"
	"syscall"
)

// Status is DaemonAPI.WebRemoteStatus (071 R3): whether the control plane serves the web
// remote on its loopback port. Agents Host's row and the window's Settings show it. The
// JSON is the Swift's: reason and detail are left out when empty.
type Status struct {
	// Port is the port asked for: 8792 for Agents Host's copy.
	Port   int  `json:"port"`
	Served bool `json:"served"`
	// Reason is why not, when it is not served: ReasonPortInUse, ReasonBuild or ReasonFailed.
	Reason string `json:"reason,omitempty"`
	// Detail is the error as the control plane met it.
	Detail string `json:"detail,omitempty"`
}

// The reasons of WebRemoteStatus.
const (
	ReasonPortInUse = "portInUse"
	ReasonBuild     = "build"
	ReasonFailed    = "failed"
)

// Address is WebRemoteStatus.address.
func (s Status) Address() string { return OriginFor(s.Port) }

// Summary is WebRemoteStatus.summary: the status in plain words, for the row that would
// otherwise give the address.
func (s Status) Summary() string {
	if s.Served {
		return fmt.Sprintf("At %s, for a browser on this Mac only.", s.Address())
	}
	switch s.Reason {
	case ReasonPortInUse:
		return fmt.Sprintf("Not serving: port %d is in use by another app.", s.Port)
	case ReasonBuild:
		return "Not serving: this copy of Agents Host’s web app is damaged or missing."
	default:
		detail := ""
		if s.Detail != "" {
			detail = " (" + s.Detail + ")"
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
		return Status{Port: l.Port(), Served: true}
	}
	if err == nil {
		err = errors.New("no listener")
	}
	var files *FilesError
	switch {
	case errors.As(err, &files):
		return Status{Port: asked, Reason: ReasonBuild, Detail: err.Error()}
	case errors.Is(err, syscall.EADDRINUSE):
		return Status{Port: asked, Reason: ReasonPortInUse, Detail: err.Error()}
	default:
		return Status{Port: asked, Reason: ReasonFailed, Detail: err.Error()}
	}
}
