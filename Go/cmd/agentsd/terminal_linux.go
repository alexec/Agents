package main

import "golang.org/x/sys/unix"

// isTerminalFD is whether fd is a terminal: one that answers a terminal's ioctl (#1388).
// /dev/null, where systemd's StandardOutput=null puts stdout, is not one.
func isTerminalFD(fd int) bool {
	_, err := unix.IoctlGetTermios(fd, unix.TCGETS)
	return err == nil
}
