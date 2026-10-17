//go:build !darwin

package main

import "github.com/alexec/agents/Go/internal/agentsd"

// door is open off a Mac: a Linux host has no signatures (RolePolicy.sshSessions is not
// ported yet).
func door(string) agentsd.SocketDoor { return nil }
