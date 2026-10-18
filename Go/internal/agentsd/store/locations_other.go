//go:build !darwin

package store

import "path/filepath"

// StandardRoot is the ordinary root on Linux, Application Support/Agents as Foundation
// has it there: ~/.local/share/Agents.
func StandardRoot(home string) string { return filepath.Join(home, ".local", "share", "Agents") }

func folders(root, home string, env func(string) string) Locations {
	return platformFolders(root, home, env)
}
