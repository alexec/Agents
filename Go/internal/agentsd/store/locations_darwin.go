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
	cache := filepath.Join(home, "Library", "Caches", "com.alexecollins.agents")
	logs := filepath.Join(home, "Library", "Logs", "Agents")
	if root != StandardRoot(home) {
		own := filepath.Join("roots", filepath.Base(root)+"-"+PathHash(root))
		cache, logs = filepath.Join(cache, own), filepath.Join(logs, own)
	}
	return Locations{Root: root, Cache: cache, Logs: logs}
}
