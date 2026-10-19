package rolllog

import "syscall"

func dupTo(from, to int) error { return syscall.Dup2(from, to) }
