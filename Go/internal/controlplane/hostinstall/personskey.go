package hostinstall

import (
	"context"
	"encoding/base64"
	"net"
	"os"
	"path/filepath"
	"strings"

	gossh "golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

// personsKey (#1691): the key the server offers, in known_hosts form, when the person's
// own known_hosts trusts it for this server; "" otherwise. An install that trusted the
// person's known_hosts pins it in the tunnel's record, as an install that showed the key
// does, so the tunnel and the ssh start check it whatever address the server has at a
// later start. ssh is the command the install logged in with; config is the ssh config
// alone, to fetch the key with.
func personsKey(ctx context.Context, ssh sshCommand, config []string, folder string) string {
	out, err := ssh.run(ctx, join(ssh.options, ssh.resolveArguments()), "")
	if err != nil || out.status != 0 {
		return ""
	}
	name, files := knownHostsLookup(out.stdout)
	if name == "" || len(files) == 0 {
		return ""
	}
	trusts, err := knownhosts.New(files...)
	if err != nil {
		return ""
	}
	fetching := ssh
	fetching.options = config
	file, _, err := fetchHostKey(ctx, fetching, folder)
	if err != nil {
		return ""
	}
	defer os.Remove(file)
	data, _ := os.ReadFile(file)
	var kept []string
	for _, line := range lines(string(data)) {
		fields := strings.Fields(line)
		if len(fields) < 3 || strings.HasPrefix(fields[0], "@") || strings.HasPrefix(fields[0], "#") {
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(fields[2])
		if err != nil {
			continue
		}
		key, err := gossh.ParsePublicKey(raw)
		if err != nil {
			continue
		}
		if trusts(name, &net.TCPAddr{}, key) == nil {
			kept = append(kept, strings.Join(fields[:3], " "))
		}
	}
	if len(kept) == 0 {
		return ""
	}
	return strings.Join(kept, "\n") + "\n"
}

// knownHostsLookup: from `ssh -G` output, the name ssh looks the server's key up by
// (HostKeyAlias, or host and port, as host:port) and the known_hosts files that exist.
func knownHostsLookup(resolved string) (string, []string) {
	values := map[string]string{}
	for _, line := range lines(resolved) {
		key, value, ok := strings.Cut(line, " ")
		if ok {
			values[strings.ToLower(key)] = strings.TrimSpace(value)
		}
	}
	host, port := values["hostname"], values["port"]
	if port == "" {
		port = "22"
	}
	if alias := values["hostkeyalias"]; alias != "" && alias != "none" {
		host, port = alias, "22"
	}
	if host == "" {
		return "", nil
	}
	home, _ := os.UserHomeDir()
	var files []string
	for _, f := range append(strings.Fields(values["userknownhostsfile"]), strings.Fields(values["globalknownhostsfile"])...) {
		if strings.HasPrefix(f, "~/") && home != "" {
			f = filepath.Join(home, f[2:])
		}
		if info, err := os.Stat(f); err == nil && info.Mode().IsRegular() {
			files = append(files, f)
		}
	}
	return net.JoinHostPort(host, port), files
}
