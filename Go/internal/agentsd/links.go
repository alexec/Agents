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

// allocated is a file's size on disk (totalFileAllocatedSize), its length where the
// system does not say.
func allocated(fi os.FileInfo) int64 {
	if st, ok := fi.Sys().(*syscall.Stat_t); ok {
		return int64(st.Blocks) * 512
	}
	return fi.Size()
}
