package agentsd

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"
)

// CredentialCommand is `agentsd credential` (#3926), run by an agent's git and gh:
//
//	agentsd credential get     git's credential helper: reads git's request on in, writes the
//	                           App's token for https://github.com, or nothing
//	agentsd credential store   (and erase) git's other two actions: nothing to do
//	agentsd credential token   the token alone
//	agentsd credential gh GH …  the gh that Agents puts on PATH: runs the real gh, GH, with the
//	                           token, and again with the person's own login when GitHub
//	                           refuses the App (#4077)
//
// It asks the host that started the agent (credentialURLEnv, credentialGrantEnv) at each call,
// so the token is the one that is good now, and keeps nothing.
func CredentialCommand(args []string, getenv func(string) string, in io.Reader, out io.Writer) int {
	if len(args) >= 2 && args[0] == "gh" {
		return runGH(args[1], args[2:], getenv, os.Stdin, os.Stdout, os.Stderr)
	}
	if len(args) != 1 {
		fmt.Fprintln(os.Stderr, "usage: agentsd credential get|store|erase|token")
		return 2
	}
	switch args[0] {
	case "token":
		token, err := askCredential(getenv, "", "")
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
		// Nothing written is git's "no answer": git asks the next helper, the person's own gh
		// (#4077), as when the App cannot push there.
		if token, err := askCredential(getenv, owner, "git"); err == nil && token != "" {
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
// folder's), or "" when it has none. use "git" asks for a token that can push.
func askCredential(getenv func(string) string, owner, use string) (string, error) {
	base, grant := getenv(credentialURLEnv), getenv(credentialGrantEnv)
	if base == "" || grant == "" {
		return "", fmt.Errorf("%s is not set: this was not started by Agent Loops", credentialURLEnv)
	}
	u, err := url.Parse(base)
	if err != nil {
		return "", err
	}
	q := url.Values{}
	if owner != "" {
		q.Set("owner", owner)
	}
	if use != "" {
		q.Set("use", use)
	}
	u.RawQuery = q.Encode()
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

// runGH runs gh with the App's token in GH_TOKEN, and when GitHub refuses the App a thing the
// person may do (#4077: a job's rerun needs Actions write, which the App may not have), runs it
// once more with the person's own login, as before #3926. It runs it again only when the first
// run wrote nothing on stdout (so nothing was made) and read nothing from stdin.
func runGH(gh string, args []string, getenv func(string) string, stdin io.Reader, stdout, stderr io.Writer) int {
	token, err := askCredential(getenv, "", "")
	if err != nil || token == "" {
		return runGHOnce(gh, args, nil, stdin, stdout, stderr)
	}
	var said bytes.Buffer
	wrote := &countingWriter{w: stdout}
	code := runGHOnce(gh, args, []string{"GH_TOKEN=" + token}, stdin, wrote, io.MultiWriter(stderr, &ghErrTail{b: &said}))
	if code == 0 || wrote.n > 0 || readsStdin(args) || !refusedTheApp(said.String()) {
		return code
	}
	fmt.Fprintln(stderr, "agents: GitHub refused the GitHub App this; running it again with your own gh login")
	return runGHOnce(gh, args, nil, stdin, stdout, stderr)
}

func runGHOnce(gh string, args, env []string, stdin io.Reader, stdout, stderr io.Writer) int {
	cmd := exec.Command(gh, args...)
	cmd.Env = append(without(os.Environ(), "GH_TOKEN", "GITHUB_TOKEN"), env...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = stdin, stdout, stderr
	err := cmd.Run()
	var exit *exec.ExitError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &exit):
		return exit.ExitCode()
	}
	fmt.Fprintln(stderr, err)
	return 1
}

// refusedTheApp is whether gh's error is GitHub refusing the App's token for a permission
// the App lacks, as GitHub says it in REST and GraphQL, and in a push of a pull request's
// branch.
func refusedTheApp(said string) bool {
	return strings.Contains(said, "Resource not accessible by integration") ||
		strings.Contains(said, "have permission to update head repository")
}

// readsStdin is whether gh's arguments read stdin ("-", "@-"), which a second run would not get.
func readsStdin(args []string) bool {
	for _, a := range args {
		if a == "-" || strings.HasSuffix(a, "@-") {
			return true
		}
	}
	return false
}

type countingWriter struct {
	w io.Writer
	n int
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	c.n += n
	return n, err
}

// ghErrTail keeps the last 64 KiB written, enough for gh's error.
type ghErrTail struct{ b *bytes.Buffer }

func (t *ghErrTail) Write(p []byte) (int, error) {
	t.b.Write(p)
	if over := t.b.Len() - 64<<10; over > 0 {
		t.b.Next(over)
	}
	return len(p), nil
}
