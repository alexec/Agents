package agentsd

import "syscall"

// prSetDumpable is prctl's PR_SET_DUMPABLE.
const prSetDumpable = 4

// keepMemoryPrivate makes agentsd not dumpable (#4058): no other process of the user reads
// its memory through /proc or ptrace, so a value it opened stays its own.
func keepMemoryPrivate() error {
	if _, _, e := syscall.RawSyscall(syscall.SYS_PRCTL, prSetDumpable, 0, 0); e != 0 {
		return e
	}
	return nil
}
