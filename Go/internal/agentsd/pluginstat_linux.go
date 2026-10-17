package agentsd

import "syscall"

// statTimes is a stat's modified and changed times.
func statTimes(st *syscall.Stat_t) (m, c syscall.Timespec) { return st.Mtim, st.Ctim }
