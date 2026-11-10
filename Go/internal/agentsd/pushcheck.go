package agentsd

import (
	"context"
	"strings"

	"github.com/alexec/agents/Go/internal/connections"
	"github.com/alexec/agents/Go/wire"
)

// The check before a session gets the App's token (#4079): can the token write code to the
// session's repository? A lane found out only at push time, each lane on its own (#4077).
// Now the host reads the install's permissions once, when the runtime starts (kept 10
// minutes, appWrites). When they are short, it reads them once more, with the token the host
// has now: a user token of the App has the install's permissions, so a new token gives no
// more, but the install may have been changed since the read that is kept. When they are
// still short, the person gets one notice for the owner, with the permission to grant, and
// the session's brief says it, so the lane knows before it pushes. The token is never in
// the notice, the brief or the log.

// pushNoticePrefix starts the notice's id; the rest is the owner, in lower case.
const pushNoticePrefix = "github-push:"

// appNeeds is the install's permissions that a lane needs to write: its push, then its pull
// request. GitHub's name for each is the key; the name in the App's settings page is name.
var appNeeds = []struct{ key, name string }{
	{"contents", "Contents"},
	{"pull_requests", "Pull requests"},
}

// checkAppPush is the check for agent's runtime, whose repository is on owner, with token the
// person's user token of the App.
func (d *Daemon) checkAppPush(ctx context.Context, agent wire.UUID, owner, token string) {
	pushes, missing := d.appWrites(ctx, owner, token, false)
	if !pushes {
		if t, bot := d.githubTokenFor(ctx, owner); t != "" && !bot {
			token = t
		}
		pushes, missing = d.appWrites(ctx, owner, token, true)
	}
	key := strings.ToLower(owner)
	if pushes {
		d.credMu.Lock()
		told := d.pushTold[key]
		delete(d.pushTold, key)
		d.credMu.Unlock()
		if told {
			d.withdrawPushNotice(key)
		}
		return
	}
	login := ""
	if c, ok := d.githubConnection(); ok {
		login = c.Login
	}
	grant := appGrantWords(owner, login, missing)
	d.credMu.Lock()
	if d.pushBriefs == nil {
		d.pushBriefs = map[wire.UUID]string{}
	}
	d.pushBriefs[agent] = "The GitHub App " + connections.GitHubAppSlug + " may not write code on " + owner +
		", so your git push goes as my own gh login, without the App's badge, and may be refused. " +
		"I have a notice to " + grant + "; do not look for another way to push."
	told := d.pushTold[key]
	d.credMu.Unlock()
	if told || d.muted(&agent) {
		return
	}
	d.credMu.Lock()
	if d.pushTold == nil {
		d.pushTold = map[string]bool{}
	}
	d.pushTold[key] = true
	d.credMu.Unlock()
	d.attentionMu.Lock()
	d.notices = append(d.notices, postedNotice{id: pushNoticePrefix + key, agentID: agent, raised: now(),
		h3: "Agents cannot push to " + owner + " as the App. To fix it, " + grant + "."})
	d.attentionMu.Unlock()
	d.reconsider()
}

// appGrantWords says what the person grants: each permission missing, Read and write, on
// the App's install on owner, from the settings of login (the person) or of owner's org.
func appGrantWords(owner, login string, missing []string) string {
	if len(missing) == 0 {
		missing = []string{appNeeds[0].name}
	}
	where := "github.com/organizations/" + owner + "/settings/installations"
	if strings.EqualFold(owner, login) {
		where = "github.com/settings/installations"
	}
	return "give " + connections.GitHubAppSlug + " " + strings.Join(missing, " and ") +
		": Read and write at " + where + ", then accept the new permissions"
}

// pushBrief is the brief's line for agent, "" when its App may push.
func (d *Daemon) pushBrief(agent wire.UUID) string {
	d.credMu.Lock()
	defer d.credMu.Unlock()
	return d.pushBriefs[agent]
}

// withdrawPushNotice takes back owner's notice: the App may push there again.
func (d *Daemon) withdrawPushNotice(owner string) {
	id := pushNoticePrefix + owner
	d.attentionMu.Lock()
	kept := d.notices[:0]
	gone := false
	for _, n := range d.notices {
		if n.id == id {
			gone = true
			continue
		}
		kept = append(kept, n)
	}
	d.notices = kept
	d.attentionMu.Unlock()
	if gone {
		d.reconsider()
	}
}
