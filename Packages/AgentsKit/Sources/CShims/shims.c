#include "CShims.h"
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
