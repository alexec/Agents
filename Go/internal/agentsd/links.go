package agentsd

import (
	"os"
	"syscall"
)

// links is a file's count of hard links, 1 where the system does not say.
func links(fi os.FileInfo) uint64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return uint64(st.Nlink)
	}
	return 1
}
