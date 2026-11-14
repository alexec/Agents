package agentsd

import (
	"sort"
	"strings"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// notCommittedLimit is how many paths folders/notCommitted sends at most; more says the rest.
const notCommittedLimit = 500

// notCommitted is folders/notCommitted (#3448): what in the folder's .agents Git ignores.
// It stays on this machine, so the project's other folders do not get it. A folder that
// Git ignores whole is one path, with a slash at its end, as git ls-files --directory says it.
func notCommitted(folder string) (wire.NotCommittedResponse, error) {
	out := wire.NotCommittedResponse{Paths: []string{}}
	if !isDir(folder) {
		return out, &Error{Code: wire.FailureFolderGone, Message: shortPath(folder) + " is not there any more."}
	}
	if inside, err := git(folder, "rev-parse", "--is-inside-work-tree"); err != nil || inside != "true" {
		return out, nil
	}
	out.IsRepository = true
	raw, err := gitRaw(folder, nil, "ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory", "--", ".agents")
	if err != nil {
		return out, err
	}
	var paths []string
	for _, p := range strings.Split(string(raw), "\x00") {
		if p != "" {
			paths = append(paths, p)
		}
	}
	sort.Strings(paths)
	if len(paths) > notCommittedLimit {
		out.More = int64(len(paths) - notCommittedLimit)
		paths = paths[:notCommittedLimit]
	}
	out.Paths = append(out.Paths, paths...)
	return out, nil
}
