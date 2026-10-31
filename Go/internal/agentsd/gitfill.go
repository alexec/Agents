package agentsd

import (
	"context"
	"encoding/json"
	"os/exec"
	"strings"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// git/fill is asked on the control-plane channel only (#1122). It is not a window method:
// a window can call every method, and this one would hand it the git password. The
// password is never logged.

// fillGitCredential runs `git credential fill`. A test replaces it. The returned text
// holds the password, so a caller must not log it.
var fillGitCredential = func(attributes string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", "credential", "fill")
	cmd.Stdin = strings.NewReader(attributes)
	out, err := cmd.Output()
	if err != nil {
		return "", err
	}
	return string(out), nil
}

// fillGit answers git/fill. A request that is not https, or a fill that finds nothing,
// comes back empty so the borrower is told there is no access, rather than waiting.
func (d *Daemon) fillGit(params json.RawMessage) wire.GitCredential {
	var req wire.GitCredentialRequest
	if json.Unmarshal(params, &req) != nil || req.Protocol != "https" || !gitServerName(req.Host) {
		return wire.GitCredential{}
	}
	text, err := fillGitCredential("protocol=https\nhost=" + req.Host + "\n\n")
	if err != nil {
		return wire.GitCredential{}
	}
	user, pass, ok := gitCredentialLines(text)
	if !ok {
		return wire.GitCredential{}
	}
	return wire.GitCredential{Username: user, Password: pass}
}

// gitServerName is GitCredentialRequest.isServer: a server name, and nothing else.
func gitServerName(host string) bool {
	if host == "" || len(host) >= 256 {
		return false
	}
	for _, c := range host {
		if c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' {
			continue
		}
		switch c {
		case '-', '.', ':', '[', ']', '_':
		default:
			return false
		}
	}
	return true
}

func gitCredentialLines(text string) (user, pass string, ok bool) {
	for _, line := range strings.Split(text, "\n") {
		if v, found := strings.CutPrefix(line, "username="); found {
			user = v
		}
		if v, found := strings.CutPrefix(line, "password="); found {
			pass = v
		}
	}
	if user == "" || pass == "" || strings.ContainsAny(user+pass, "\r\n") {
		return "", "", false
	}
	return user, pass, true
}
