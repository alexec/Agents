package sandbox

import (
	"fmt"
	"os"
	"strings"
	"syscall"
)

// Exec on macOS: sandbox-exec with a profile made from the policy (stage 5). The whole
// filesystem readable, writes only under the policy's paths, network open.
func Exec(args []string) error {
	var write []string
	i := 0
	for ; i < len(args); i++ {
		if args[i] == "--" {
			i++
			break
		}
		if args[i] == "--write" && i+1 < len(args) {
			write = append(write, args[i+1])
			i++
		}
	}
	argv := args[i:]
	if len(argv) == 0 {
		return fmt.Errorf("sandbox-exec: nothing to run")
	}
	var b strings.Builder
	b.WriteString("(version 1)\n(allow default)\n(deny file-write*)\n(allow file-write*\n")
	for _, p := range append(write, "/dev", "/private/var/folders") {
		if real, err := evalSymlinks(p); err == nil {
			p = real
		}
		fmt.Fprintf(&b, "  (subpath %q)\n", p)
	}
	b.WriteString(")\n")
	return syscall.Exec("/usr/bin/sandbox-exec", append([]string{"sandbox-exec", "-p", b.String()}, argv...), os.Environ())
}

func Available() (bool, string) { return true, "sandbox-exec" }
