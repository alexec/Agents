//go:build !darwin

package main

import "path/filepath"

// standardRoot is ~/.local/share/Agents, Application Support/Agents as Foundation has it
// on Linux.
func standardRoot(home string) string { return filepath.Join(home, ".local", "share", "Agents") }
