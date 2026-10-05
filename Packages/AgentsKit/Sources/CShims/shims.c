#define _GNU_SOURCE
#include "CShims.h"
#include <errno.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <string.h>
#include <termios.h>

int agents_set_winsize(int fd, unsigned short rows, unsigned short cols) {
    struct winsize size;
    memset(&size, 0, sizeof size);
    size.ws_row = rows;
    size.ws_col = cols;
    return ioctl(fd, TIOCSWINSZ, &size);
}

int agents_output_queued(int fd) {
    int queued = -1;
    if (ioctl(fd, TIOCOUTQ, &queued) != 0) return -1;
    return queued;
}

int agents_has_exited(pid_t pid) {
    siginfo_t info;
    memset(&info, 0, sizeof info);
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) != 0) return -1;
    return info.si_pid == pid ? 1 : 0;
}

int agents_spawn_chdir(posix_spawn_file_actions_t *actions, const char *path) {
    return posix_spawn_file_actions_addchdir_np(actions, path);
}

int agents_wait_for_exit(pid_t pid) {
    siginfo_t info;
    for (;;) {
        memset(&info, 0, sizeof info);
        if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOWAIT) == 0) return 0;
        if (errno != EINTR) return -1;
    }
}
