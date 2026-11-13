package agentsd

import (
	"bytes"
	"context"
	"fmt"
	"log"
	"os/exec"
	"regexp"
	goruntime "runtime"
	"sort"
	"strings"
	"time"
)

// The old sign-up passwords (#5043). The accounts made before 2026-11-09 (the sign-up skill's
// "Older accounts (0.7)") keep their passwords in the login Keychain, in generic-password
// items named agents-signup:<domain>. fill_secret types only from Settings ▸ Secrets, and an
// agent must never read a Keychain password into a command or its context. So agentsd, at
// each start on a Mac, copies each such item into the store as <PROVIDER>_PASSWORD, with Ask
// before use on (an agent's write, #4014), and with a description that names the item. The
// value goes from /usr/bin/security to the store in agentsd's memory only: never to a log,
// a file of its own, an agent or a reply.
//
// A name that is set already keeps its value: it is the newer one (a reset, #4303's), or the
// same one copied by hand. The Keychain items stay: the store is a copy, not a move.
// The items were made by /usr/bin/security, which their access list names, so its read
// raises no prompt; a read that does wait on one is stopped after ten seconds (#207), and
// that item is tried again at the next start.

const signupKeychainPrefix = "agents-signup:"

// signupKeychain lists and reads the items. Tests replace it.
var signupKeychain keychainItems = securityKeychain{}

type keychainItems interface {
	// services is each item's service that starts with signupKeychainPrefix. It reads no
	// value.
	services() ([]string, error)
	// password is one item's value.
	password(service string) (string, error)
}

// signupSecretNames are the domains whose first label is not the provider's name.
var signupSecretNames = map[string]string{
	"aws.amazon.com":       "AWS_PASSWORD",
	"workspace.google.com": "GOOGLE_WORKSPACE_PASSWORD",
}

var trailingNumber = regexp.MustCompile(`_[0-9]+$`)

// signupSecretName is the secret's name for an item's domain: its first label, upper case,
// with a trailing number left out (okta-integrator-3285196 is OKTA_INTEGRATOR_PASSWORD).
func signupSecretName(domain string) string {
	domain = strings.ToLower(strings.TrimSpace(domain))
	if name, ok := signupSecretNames[domain]; ok {
		return name
	}
	label, _, _ := strings.Cut(domain, ".")
	label = strings.ToUpper(strings.NewReplacer("-", "_", "+", "_").Replace(label))
	label = trailingNumber.ReplaceAllString(label, "")
	if label == "" || !secretNamePattern.MatchString(label+"_PASSWORD") {
		return ""
	}
	return label + "_PASSWORD"
}

var secretNamePattern = regexp.MustCompile(`^[A-Z][A-Z0-9_]*$`)

// MoveSignupKeychain copies the old sign-up passwords into the store, on a Mac (#5043).
func (d *Daemon) MoveSignupKeychain() {
	if goruntime.GOOS != "darwin" {
		return
	}
	n, err := d.moveSignupKeychain()
	if err != nil {
		log.Printf("sign-up passwords: %v", err)
	}
	if n > 0 {
		log.Printf("sign-up passwords: copied %d from the Keychain into the store", n)
	}
}

func (d *Daemon) moveSignupKeychain() (int, error) {
	home := d.personalHome()
	if home == "" {
		return 0, nil
	}
	services, err := signupKeychain.services()
	if err != nil {
		return 0, fmt.Errorf("the Keychain was not listed: %w", err)
	}
	copied := 0
	for _, service := range services {
		domain := strings.TrimPrefix(service, signupKeychainPrefix)
		name := signupSecretName(domain)
		if name == "" {
			log.Printf("sign-up passwords: %s has no secret name, and was left", service)
			continue
		}
		if secretIsSet(home, name) {
			continue
		}
		value, err := signupKeychain.password(service)
		if err != nil || value == "" {
			log.Printf("sign-up passwords: %s was not read, and is tried again at the next start", service)
			continue
		}
		if err := d.saveSecret(name, value, true); err != nil {
			log.Printf("sign-up passwords: %s was not saved: %v", name, err)
			continue
		}
		description := fmt.Sprintf("Password of the agents' %s account, from the Keychain item %s (#5043). Not Alex's account.", domain, service)
		if err := setSecretDescription(home, name, description); err != nil {
			log.Printf("sign-up passwords: %s's description: %v", name, err)
		}
		log.Printf("sign-up passwords: copied %s into %s", service, name)
		copied++
	}
	return copied, nil
}

// securityKeychain is /usr/bin/security on the login Keychain.
type securityKeychain struct{}

var keychainService = regexp.MustCompile(`"svce"<blob>="` + regexp.QuoteMeta(signupKeychainPrefix) + `([^"]+)"`)

func (securityKeychain) services() ([]string, error) {
	// dump-keychain with no -d prints each item's attributes and never a value.
	out, err := runSecurity("dump-keychain")
	if err != nil {
		return nil, err
	}
	return signupServices(out), nil
}

// signupServices is each agents-signup: service in dump-keychain's text, once, in order.
func signupServices(dump []byte) []string {
	seen := map[string]bool{}
	for _, m := range keychainService.FindAllSubmatch(dump, -1) {
		seen[signupKeychainPrefix+string(m[1])] = true
	}
	out := make([]string, 0, len(seen))
	for s := range seen {
		out = append(out, s)
	}
	sort.Strings(out)
	return out
}

func (securityKeychain) password(service string) (string, error) {
	out, err := runSecurity("find-generic-password", "-s", service, "-w")
	if err != nil {
		return "", err
	}
	return strings.TrimSuffix(string(out), "\n"), nil
}

// runSecurity runs /usr/bin/security for ten seconds at most: a read waiting on a prompt
// nobody answers must not hang (#207). Its error never has the output in it.
func runSecurity(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	var out bytes.Buffer
	cmd := exec.CommandContext(ctx, "/usr/bin/security", args...)
	cmd.Stdout = &out
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("security %s: %w", args[0], err)
	}
	return out.Bytes(), nil
}
