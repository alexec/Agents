package agentsd

import "golang.org/x/sys/unix"

// exchangePaths swaps two paths in one step (renameat2 with RENAME_EXCHANGE, #2710). Only a
// Mac updates itself; Linux has it for the tests.
func exchangePaths(a, b string) error {
	return unix.Renameat2(unix.AT_FDCWD, a, unix.AT_FDCWD, b, unix.RENAME_EXCHANGE)
}
