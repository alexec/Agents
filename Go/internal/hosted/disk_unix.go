//go:build unix

package hosted

import "golang.org/x/sys/unix"

// DiskOf reads the disk that holds path.
func DiskOf(path string) func() (Space, error) {
	return func() (Space, error) {
		var st unix.Statfs_t
		if err := unix.Statfs(path, &st); err != nil {
			return Space{}, err
		}
		block := int64(st.Bsize) //nolint:unconvert // uint32 on Darwin, int64 on Linux
		return Space{Total: int64(st.Blocks) * block, Free: int64(st.Bavail) * block}, nil
	}
}
