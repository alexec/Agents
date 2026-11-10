package agentsd

import (
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// pushNotices is the host's notices that the App may not push.
func pushNotices(d *Daemon) []postedNotice {
	d.attentionMu.Lock()
	defer d.attentionMu.Unlock()
	var out []postedNotice
	for _, n := range d.notices {
		if strings.HasPrefix(n.id, pushNoticePrefix) {
			out = append(out, n)
		}
	}
	return out
}

// Before a session gets the App's token, the host checks that it can write code (#4079): an
// install with no Contents write is read again once, then the person gets one notice for the
// owner, not one per lane, with the permission to grant, and each session's brief says it.
// When the install may write again, the notice goes and a new session's brief says nothing.
func TestTheHostChecksTheAppCanPushBeforeASessionGetsItsToken(t *testing.T) {
	t.Setenv("AGENTS_PERSONAL_HOME", t.TempDir())
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	file := &connections.File{Path: filepath.Join(t.TempDir(), ".agents-secrets", connections.FileName)}
	d.connStoreFor = func() (connections.Store, error) { return file, nil }
	gh := &fakeSetupGitHub{readOnly: true}
	d.newSetupReader = func(string) setupReader { return gh }
	file.Put(connections.Connection{Provider: connections.GitHub, Login: "alexec", Access: "ghu_secret",
		AccessExpiresAt: time.Now().Add(time.Hour), ConnectedAt: time.Now()})
	d.credentialSelf = filepath.Join(t.TempDir(), "agentsd")
	folder := gitFolder(t, "https://github.com/alexec/agents-walk.git")
	base := []string{"PATH=/usr/bin:/bin"}

	running := func(a *wire.Agent) { a.State, a.EndedReason = wire.AgentStateRunning, nil }
	one, two := seeded(t, d, folder, running).ID, seeded(t, d, folder, running).ID
	d.withGitHubCredential(base, one, folder)
	d.withGitHubCredential(base, two, folder)
	notices := pushNotices(d)
	if len(notices) != 1 || notices[0].agentID != one {
		t.Fatalf("want one notice, for the first session: %+v", notices)
	}
	h3 := notices[0].h3
	if !strings.Contains(h3, "Contents and Pull requests: Read and write") ||
		!strings.Contains(h3, "github.com/settings/installations") || strings.Contains(h3, "ghu_secret") {
		t.Fatalf("the notice: %q", h3)
	}
	for _, a := range []wire.UUID{one, two} {
		brief := d.pushBrief(a)
		if !strings.Contains(brief, "may not write code on alexec") || strings.Contains(brief, "ghu_secret") {
			t.Fatalf("%s's brief line: %q", a, brief)
		}
	}
	if b := d.brief(d.Store.Agent(two)); !strings.Contains(b, "may not write code on alexec") {
		t.Fatalf("the brief has no line on the push")
	}

	// The install may write again: the next session reads it again, the notice goes and its
	// brief says nothing.
	gh.mu.Lock()
	gh.readOnly = false
	gh.mu.Unlock()
	three := seeded(t, d, folder, running).ID
	d.withGitHubCredential(base, three, folder)
	if n := pushNotices(d); len(n) != 0 || d.pushBrief(three) != "" {
		t.Fatalf("after the grant: %+v %q", n, d.pushBrief(three))
	}
	d.dropCredentialGrants(one)
	if d.pushBrief(one) != "" {
		t.Fatalf("an ended runtime keeps its brief line")
	}
}

func TestTheGrantSaysWhereForAnOrg(t *testing.T) {
	got := appGrantWords("acme", "alexec", []string{"Contents"})
	if got != "give agents-loops Contents: Read and write at github.com/organizations/acme/settings/installations, then accept the new permissions" {
		t.Fatalf("%q", got)
	}
}
