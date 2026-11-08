package agentsd

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// CredentialCommand is `agentsd credential` (#3926), run by an agent's git and gh:
//
//	agentsd credential get     git's credential helper: reads git's request on in, writes the
//	                           App's token for https://github.com, or nothing
//	agentsd credential store   (and erase) git's other two actions: nothing to do
//	agentsd credential token   the token alone, for the gh that Agents puts on PATH
//
// It asks the host that started the agent (credentialURLEnv, credentialGrantEnv) at each call,
// so the token is the one that is good now, and keeps nothing.
func CredentialCommand(args []string, getenv func(string) string, in io.Reader, out io.Writer) int {
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: agentsd credential get|store|erase|token")
		return 2
	}
	switch args[0] {
	case "token":
		token, err := askCredential(getenv, "")
		if err != nil || token == "" {
			return 1
		}
		fmt.Fprintln(out, token)
		return 0
	case "get":
		attrs := map[string]string{}
		sc := bufio.NewScanner(in)
		for sc.Scan() {
			if k, v, ok := strings.Cut(sc.Text(), "="); ok {
				attrs[k] = v
			}
		}
		if attrs["protocol"] != "https" || !strings.EqualFold(attrs["host"], "github.com") {
			return 0
		}
		owner, _, _ := strings.Cut(strings.TrimPrefix(attrs["path"], "/"), "/")
		// Nothing written is git's "no answer": the push fails and says why, as it would with
		// no helper.
		if token, err := askCredential(getenv, owner); err == nil && token != "" {
			fmt.Fprintf(out, "username=x-access-token\npassword=%s\n", token)
		}
		return 0
	case "store", "erase":
		_, _ = io.Copy(io.Discard, in)
		return 0
	}
	fmt.Fprintln(os.Stderr, "usage: agentsd credential get|store|erase|token")
	return 2
}

// askCredential is the host's current token for owner's repositories ("" for the agent's own
// folder's), or "" when it has none.
func askCredential(getenv func(string) string, owner string) (string, error) {
	base, grant := getenv(credentialURLEnv), getenv(credentialGrantEnv)
	if base == "" || grant == "" {
		return "", fmt.Errorf("%s is not set: this was not started by Agents", credentialURLEnv)
	}
	u, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	if owner != "" {
		u.RawQuery = url.Values{"owner": {owner}}.Encode()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, u.String(), nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Authorization", "Bearer "+grant)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	switch resp.StatusCode {
	case http.StatusOK:
		b, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
		return strings.TrimSpace(string(b)), err
	case http.StatusNoContent:
		return "", nil
	}
	return "", fmt.Errorf("the host said %s", resp.Status)
}
