package sandbox

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"syscall"

	"github.com/landlock-lsm/go-landlock/landlock"
	ll "github.com/landlock-lsm/go-landlock/landlock/syscall"
)

// Exec is `agentsd sandbox-exec --write P … -- argv`: the whole filesystem readable and
// executable, writes only where the policy says, then exec. BestEffort: on a kernel
// without Landlock (or an older ABI) it confines what it can and says so.
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
	// Files Landlock is to let the runtime write must exist: it grants rights on what is there.
	var dirs, files []string
	for _, w := range write {
		fi, err := os.Stat(w)
		if os.IsNotExist(err) && strings.HasSuffix(w, ".json") || os.IsNotExist(err) && strings.HasSuffix(w, ".backup") {
			if f, err := os.OpenFile(w, os.O_CREATE|os.O_WRONLY, 0o600); err == nil {
				f.Close()
				files = append(files, w)
			}
			continue
		}
		if err != nil {
			os.MkdirAll(w, 0o700)
			dirs = append(dirs, w)
			continue
		}
		if fi.IsDir() {
			dirs = append(dirs, w)
		} else {
			files = append(files, w)
		}
	}
	rules := []landlock.Rule{
		landlock.RODirs("/"),
		landlock.RWDirs(dirs...).IgnoreIfMissing(),
		landlock.RWFiles(append(files, "/dev/null", "/dev/tty", "/dev/zero", "/dev/urandom", "/dev/random")...).IgnoreIfMissing(),
		landlock.RWDirs("/dev/pts").IgnoreIfMissing(),
	}
	if err := landlock.V5.BestEffort().RestrictPaths(rules...); err != nil {
		return fmt.Errorf("sandbox-exec: landlock: %w", err)
	}
	path, err := exec.LookPath(argv[0])
	if err != nil {
		return err
	}
	return syscall.Exec(path, argv, os.Environ())
}

// Available says whether this kernel has Landlock, and its ABI.
func Available() (bool, string) {
	v, err := ll.LandlockGetABIVersion()
	if err != nil || v <= 0 {
		return false, "no Landlock on this kernel"
	}
	return true, fmt.Sprintf("Landlock ABI %d", v)
}
