package controlplane

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/controlplane/hostinstall"
	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// A provider gives its ssh as a person types it, agents@127.0.0.1 -p 2224 (the Docker
// preset's ssh field). The start over ssh hands ssh one word for it (#857): as three, ssh
// said "hostname contains invalid characters" and the host never came back.
func TestAStartOverSSHTakesAProvidersDestinationWithAPort(t *testing.T) {
	folder := t.TempDir()
	said := filepath.Join(folder, "said")
	ssh := filepath.Join(folder, "ssh")
	script := "#!/bin/sh\nfor word in \"$@\"; do printf '%s\\n' \"$word\"; done >> '" + said + "'\n"
	if err := os.WriteFile(ssh, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	s := &Service{installer: &hostinstall.Installer{SSH: ssh}}
	if err := s.sshStart(records.HostRecord{ID: "box", Name: "w857-box"}, "agents@127.0.0.1 -p 2224"); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(said)
	if err != nil {
		t.Fatal(err)
	}
	words := strings.Split(string(data), "\n")
	found := false
	for _, w := range words {
		found = found || w == "ssh://agents@127.0.0.1:2224"
		if w == "agents@127.0.0.1 -p 2224" || w == "agents@127.0.0.1" {
			t.Errorf("ssh was given %q", w)
		}
	}
	if !found {
		t.Errorf("ssh was not given ssh://agents@127.0.0.1:2224: %q", words)
	}
}
