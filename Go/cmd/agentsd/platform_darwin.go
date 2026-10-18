package main

import "github.com/alexec/agents/Go/internal/agentsd/store"

// standardRoot is ~/Library/Application Support/Agents, as Foundation has it on a Mac.
func standardRoot(home string) string { return store.StandardRoot(home) }
