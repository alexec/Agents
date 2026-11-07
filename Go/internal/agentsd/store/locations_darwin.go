package store

import "path/filepath"

func folders(root, home string, env func(string) string) Locations {
	return macFolders(root, home)
}

// StandardRoot is the ordinary root on a Mac, StoreLocations.standardRoot:
// ~/Library/Application Support/Agents.
func StandardRoot(home string) string {
	return filepath.Join(home, "Library", "Application Support", "Agents")
}

// macFolders is StoreLocations.platformFolders on a Mac (#1030): a root in a temporary
// folder keeps cache/ and logs/ inside it; the ordinary root's are
// ~/Library/Caches/com.alexecollins.agents and ~/Library/Logs/Agents; any other root has a
// folder of its own under each, roots/<name>-<hash>.
func macFolders(root, home string) Locations {
	if isTemporary(root) {
		return Locations{Root: root, Cache: filepath.Join(root, "cache"), Logs: filepath.Join(root, "logs")}
	}
	if root != StandardRoot(home) {
		roots := macRootsFolders(home)
		return Locations{Root: root, Cache: filepath.Join(roots[0], ownName(root)), Logs: filepath.Join(roots[1], ownName(root))}
	}
	return Locations{Root: root, Cache: macCache(home), Logs: macLogs(home)}
}

func macCache(home string) string { return filepath.Join(home, "Library", "Caches", "com.alexecollins.agents") }
func macLogs(home string) string  { return filepath.Join(home, "Library", "Logs", "Agents") }

// macRootsFolders is where macFolders puts each root's own folders: the cache's, then the
// logs'.
func macRootsFolders(home string) [2]string {
	return [2]string{filepath.Join(macCache(home), "roots"), filepath.Join(macLogs(home), "roots")}
}

func rootsFolders(home string, env func(string) string) [2]string { return macRootsFolders(home) }
