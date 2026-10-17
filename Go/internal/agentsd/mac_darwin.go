package agentsd

import (
	"context"
	"os"
	"os/exec"

	"github.com/alexec/agents/Go/wire"
)

// The window's Finder, other apps and Terminal, done by this Mac's host for a sandboxed
// window (058, R12): DaemonCore+Mac.swift. Each is /usr/bin/open, started and not waited
// for.
func (d *Daemon) registerMacVerbs() {
	On(d, wire.CallMacReveal, func(ctx context.Context, c *Client, r wire.MacPathRequest) (wire.Empty, error) {
		if _, err := os.Stat(r.Path); err != nil {
			return wire.Empty{}, &Error{Code: CodeFolderGone, Message: r.Path + " is not there any more."}
		}
		return wire.Empty{}, macOpen("-R", r.Path)
	})
	On(d, wire.CallMacOpen, func(ctx context.Context, c *Client, r wire.MacPathRequest) (wire.Empty, error) {
		if _, err := os.Stat(r.Path); err != nil {
			return wire.Empty{}, &Error{Code: CodeFolderGone, Message: r.Path + " is not there any more."}
		}
		if r.App != nil && *r.App != "" {
			return wire.Empty{}, macOpen("-a", *r.App, r.Path)
		}
		return wire.Empty{}, macOpen(r.Path)
	})
	On(d, wire.CallMacTerminal, func(ctx context.Context, c *Client, r wire.MacTerminalRequest) (wire.Empty, error) {
		if r.Path != nil {
			return wire.Empty{}, macOpen("-a", "Terminal", *r.Path)
		}
		return wire.Empty{}, macOpen("-a", "Terminal")
	})
}

// macOpenCommand runs open; a test puts a stand-in here.
var macOpenCommand = "/usr/bin/open"

func macOpen(args ...string) error {
	cmd := exec.Command(macOpenCommand, args...)
	if err := cmd.Start(); err != nil {
		return &Error{Code: CodeNotSupported, Message: "This Mac could not open that: " + err.Error()}
	}
	go cmd.Wait()
	return nil
}
