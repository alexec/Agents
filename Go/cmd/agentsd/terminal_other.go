//go:build !darwin && !linux

package main

// isTerminalFD is false where there is no termios to ask: the log goes to daemon.log.
func isTerminalFD(fd int) bool { return false }
