package hostinstall

import (
	"os"
	"path"
	"path/filepath"
	"strings"
	"unicode"
)

// The servers named in an ssh config (#429): SSHConfigHosts. Only the names are read
// here. What each name means is asked of `ssh -G`, which is OpenSSH's own reading of the
// same files, Match and Include too.

// Aliases is SSHConfigHosts.aliases: the concrete Host names in file and every file it
// includes, each once, in the order they appear. Wildcard and negated patterns are
// defaults, not servers. A relative Include is in sshFolder ("" for file's folder).
func Aliases(file, sshFolder, home string) []string {
	if sshFolder == "" {
		sshFolder = filepath.Dir(file)
	}
	seen := map[string]bool{}
	visited := map[string]bool{}
	names := []string{}
	readConfig(file, sshFolder, home, 0, visited, func(name string) {
		if !seen[strings.ToLower(name)] {
			seen[strings.ToLower(name)] = true
			names = append(names, name)
		}
	})
	return names
}

func readConfig(file, folder, home string, depth int, visited map[string]bool, found func(string)) {
	// ssh gives up at 16 levels of Include; so does this, and never reads a file twice.
	clean := filepath.Clean(file)
	if depth >= 16 || visited[clean] {
		return
	}
	visited[clean] = true
	data, err := os.ReadFile(file)
	if err != nil {
		return
	}
	for _, line := range lines(string(data)) {
		w := configWords(line)
		if len(w) == 0 {
			continue
		}
		switch strings.ToLower(w[0]) {
		case "host":
			for _, pattern := range w[1:] {
				if isConcrete(pattern) {
					found(pattern)
				}
			}
		case "include":
			for _, pattern := range w[1:] {
				for _, included := range expandInclude(pattern, folder, home) {
					readConfig(included, folder, home, depth+1, visited, found)
				}
			}
		}
	}
}

// isConcrete is SSHConfigHosts.isConcrete: a name a person would ssh to, with no * or
// ? and not negated.
func isConcrete(pattern string) bool {
	return pattern != "" && !strings.HasPrefix(pattern, "!") && !strings.ContainsAny(pattern, "*?")
}

// configWords is SSHConfigHosts.words: a config line's keyword and arguments. # starts
// a comment, = may follow the keyword, and double quotes hold spaces.
func configWords(line string) []string {
	var words []string
	var current strings.Builder
	quoted, inWord := false, false
	for _, c := range line {
		if c == '"' {
			quoted = !quoted
			inWord = true
			continue
		}
		if !quoted && c == '#' {
			break
		}
		// Keyword=value and Keyword = value: the one = after the keyword is a space.
		equals := c == '=' && (len(words) == 0 || (len(words) == 1 && !inWord))
		if !quoted && (unicode.IsSpace(c) || equals) {
			if inWord {
				words = append(words, current.String())
			}
			current.Reset()
			inWord = false
			continue
		}
		current.WriteRune(c)
		inWord = true
	}
	if inWord {
		words = append(words, current.String())
	}
	return words
}

// expandInclude is SSHConfigHosts.expand: an Include argument as files. ~ is the home
// folder, a relative path is in the ssh folder, and a glob matches what is there, in
// order.
func expandInclude(pattern, folder, home string) []string {
	p := pattern
	if p == "~" {
		p = home
	} else if strings.HasPrefix(p, "~/") {
		p = home + "/" + p[2:]
	}
	if !strings.HasPrefix(p, "/") {
		p = folder + "/" + p
	}
	matched, err := filepath.Glob(p)
	if err != nil {
		return nil
	}
	return matched
}

// Resolved is SSHConfigHosts.Resolved: one name as `ssh -G` resolved it, lowercase
// keywords to their first value.
type Resolved struct {
	Alias   string
	Options map[string]string
}

// ParseResolved is SSHConfigHosts.Resolved(alias:output:): `ssh -G` output, a
// "keyword value" per line.
func ParseResolved(alias, output string) Resolved {
	options := map[string]string{}
	for _, line := range lines(output) {
		line = strings.TrimLeft(line, " ")
		key, value, _ := strings.Cut(line, " ")
		key = strings.ToLower(key)
		if key == "" {
			continue
		}
		if _, ok := options[key]; !ok {
			options[key] = value
		}
	}
	return Resolved{Alias: alias, Options: options}
}

// HostName is the hostname ssh resolved, or the alias.
func (r Resolved) HostName() string {
	if h, ok := r.Options["hostname"]; ok {
		return h
	}
	return r.Alias
}

// Display is user@hostname:port, the port left out when it is 22.
func (r Resolved) Display() string {
	user := ""
	if u, ok := r.Options["user"]; ok {
		user = u + "@"
	}
	port := ""
	if p, ok := r.Options["port"]; ok && p != "22" {
		port = ":" + p
	}
	return user + r.HostName() + port
}

// JumpHosts are the hosts this one is reached through: each hop of ProxyJump, and the
// host an `ssh … bastion` ProxyCommand goes to.
func (r Resolved) JumpHosts() []string {
	var hosts []string
	if jump, ok := r.Options["proxyjump"]; ok && strings.ToLower(jump) != "none" {
		for _, hop := range strings.Split(jump, ",") {
			hosts = append(hosts, hostPart(hop))
		}
	}
	if command, ok := r.Options["proxycommand"]; ok && strings.ToLower(command) != "none" {
		hosts = append(hosts, proxyCommandHosts(command)...)
	}
	var kept []string
	for _, h := range hosts {
		if h != "" {
			kept = append(kept, h)
		}
	}
	return kept
}

// Bastions is SSHConfigHosts.bastions: the names that are a way in for another, never
// servers themselves, even when they answer. Lower case.
func Bastions(resolved []Resolved) map[string]bool {
	set := map[string]bool{}
	for _, r := range resolved {
		for _, h := range r.JumpHosts() {
			set[strings.ToLower(h)] = true
		}
	}
	return set
}

// IsBastion is SSHConfigHosts.isBastion: the host by its alias or its hostname.
func IsBastion(host Resolved, bastions map[string]bool) bool {
	return bastions[strings.ToLower(host.Alias)] || bastions[strings.ToLower(host.HostName())]
}

// hostPart is SSHConfigHosts.hostPart: ssh://user@host:port is host.
func hostPart(hop string) string {
	host := strings.TrimFunc(hop, func(r rune) bool { return r == ' ' || r == '\t' })
	host = strings.TrimPrefix(host, "ssh://")
	if at := strings.LastIndex(host, "@"); at >= 0 {
		host = host[at+1:]
	}
	if strings.HasPrefix(host, "[") {
		if end := strings.Index(host, "]"); end >= 0 {
			return host[1:end]
		}
	}
	if colon := strings.Index(host, ":"); colon >= 0 {
		host = host[:colon]
	}
	return host
}

// valued are ssh's options that take a value, so the value is not read as the
// destination.
const valued = "BbcDEeFIiJLlmOopQRSWw"

// proxyCommandHosts is SSHConfigHosts.proxyCommandHosts: the host a ProxyCommand of the
// `ssh [options] bastion [command]` kind goes to, and any -J hop it names. Another
// program (nc, cloudflared) names none.
func proxyCommandHosts(command string) []string {
	words := strings.Fields(command)
	start := -1
	for i, w := range words {
		if path.Base(w) == "ssh" {
			start = i
			break
		}
	}
	if start < 0 {
		return nil
	}
	var hosts []string
	for i := start + 1; i < len(words); {
		word := words[i]
		if word == "--" {
			if i+1 < len(words) {
				hosts = append(hosts, hostPart(words[i+1]))
			}
			break
		}
		if strings.HasPrefix(word, "-") && len(word) >= 2 {
			flag := word[1]
			if strings.IndexByte(valued, flag) >= 0 {
				// -J hop or -Jhop; any other value is skipped.
				value := ""
				if len(word) > 2 {
					value = word[2:]
				} else if i+1 < len(words) {
					value = words[i+1]
				}
				if flag == 'J' {
					for _, hop := range strings.Split(value, ",") {
						hosts = append(hosts, hostPart(hop))
					}
				}
				if len(word) > 2 {
					i++
				} else {
					i += 2
				}
			} else {
				i++
			}
			continue
		}
		if !strings.Contains(word, "%h") {
			hosts = append(hosts, hostPart(word))
		}
		break
	}
	return hosts
}
