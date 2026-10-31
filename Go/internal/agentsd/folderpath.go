package agentsd

import (
	"os"
	"path/filepath"
	"strings"
)

// ownFolders is whether each folder of rel under folder (".agents", then
// ".agents/workflows") is a folder of its own and not a link, as far as they exist. The
// daemon writes there for agents whose sandbox keeps them in the folder, so a link such
// as .agents/workflows -> ~/.claude must not take its writes, reads or removes outside.
// A folder not made yet is fine: the daemon makes it, as a folder.
func ownFolders(folder, rel string) bool {
	p := folder
	for _, part := range strings.Split(filepath.ToSlash(filepath.Clean(rel)), "/") {
		if part == "." || part == "" {
			continue
		}
		p = filepath.Join(p, part)
		fi, err := os.Lstat(p)
		if os.IsNotExist(err) {
			return true
		}
		if err != nil || !fi.IsDir() {
			return false
		}
	}
	return true
}

func linkedFolder(rel, folder string) *Error {
	return Invalid("Nothing was changed: %s in %s is a link or a file, and the app reads and writes only in a folder of its own there. Make it a folder, then try again.", rel, folder)
}
