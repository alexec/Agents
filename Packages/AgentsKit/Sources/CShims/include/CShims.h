// The few C calls Swift cannot make on Linux (037).
//
// `ioctl` is variadic, and Swift imports no variadic C function on Linux; the Mac has an
// overlay that hides this. Everything here is a one-line wrapper, and nothing here makes
// a decision.
#ifndef AGENTS_CSHIMS_H
#define AGENTS_CSHIMS_H

#include <sys/types.h>

/// Set a terminal's size. 0 on success, -1 with errno set otherwise.
int agents_set_winsize(int fd, unsigned short rows, unsigned short cols);

/// Bytes still queued for output on a terminal, or -1.
int agents_output_queued(int fd);

/// 1 if `pid` has exited and is waiting to be reaped, 0 if it is still running, -1 on
/// error. Never reaps it: the caller that waits is elsewhere, and a second waiter would
/// take its exit status away from it.
int agents_has_exited(pid_t pid);

#endif
