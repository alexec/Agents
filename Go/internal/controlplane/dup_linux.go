package controlplane

import "syscall"

func dupTo(from, to int) error { return syscall.Dup3(from, to, 0) }
