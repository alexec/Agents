package main

import "golang.org/x/sys/unix"

// isTerminalFD is whether fd is a terminal: one that answers a terminal's ioctl (#1388).
// /dev/null, where launchd puts stdout, is a character device but not a terminal.
func isTerminalFD(fd int) bool {
	_, err := unix.IoctlGetTermios(fd, unix.TIOCGETA)
	return err == nil
}
