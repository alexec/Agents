package agentsd

import (
	"context"
	"crypto/subtle"
	"errors"
	"log"
	"sync"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/connections"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// The person's agents' bot (#3858, spec 3856 §4). A client asks this host for the App's
// manifest (connections/bot/start) and posts it to GitHub; GitHub makes the App and sends a code
// to the hand-back page, which gives it to the client; the client gives it here
// (connections/bot/complete). This host, never a client or the control plane, turns the code
// into the App's key at once and keeps it in its own store, beside the GitHub sign-in. A client
// is told the bot's name and where to install it, never its key. Logged: what happened, in a
// word.

// botSetupLimit is how long the person has to make the App on GitHub. GitHub's code lasts an
// hour; the setup does not need that long.
var botSetupLimit = 30 * time.Minute

type botBook struct {
	botMu sync.Mutex
	// botSetups is each setup under way, by its state, with when it ends.
	botSetups map[string]time.Time
	// newBotClient is GitHub's API for the bot; a test gives a fake GitHub's.
	newBotClient func() *connections.BotClient
	// botRound is held while this machine gives the bot's key to the others (githubbotcopy.go).
	botRound sync.Mutex
}

func (d *Daemon) botClient() *connections.BotClient {
	if d.newBotClient != nil {
		return d.newBotClient()
	}
	return connections.NewBotClient()
}

func (d *Daemon) registerGitHubBot() {
	On(d, wire.CallConnectionsBot, func(ctx context.Context, c *Client, _ wire.Empty) (wire.ConnectionBot, error) {
		return d.githubBot(ctx)
	})
	On(d, wire.CallConnectionsBotStart, func(ctx context.Context, c *Client, r wire.ConnectionBotStartRequest) (wire.ConnectionBotStart, error) {
		return d.githubBotStart(deref(r.Origin), r.Public != nil && *r.Public)
	})
	On(d, wire.CallConnectionsBotComplete, func(ctx context.Context, c *Client, r wire.ConnectionBotCompleteRequest) (wire.ConnectionBot, error) {
		return d.githubBotComplete(ctx, r)
	})
	On(d, wire.CallConnectionsBotRemove, func(ctx context.Context, c *Client, _ wire.Empty) (wire.ConnectionBot, error) {
		s, err := d.connectionStore()
		if err != nil {
			return wire.ConnectionBot{}, err
		}
		d.connRenew.Lock()
		held, _, _ := s.Get(connections.GitHubBot)
		err = s.Delete(connections.GitHubBot)
		d.connRenew.Unlock()
		if err != nil {
			log.Printf("connections: github bot not removed")
			return wire.ConnectionBot{}, err
		}
		log.Printf("connections: github bot removed")
		// The person's other machines forget it too (#3950).
		if bot, ok := connections.BotOf(held); ok {
			d.forgetBotEverywhere(bot.AppID)
		}
		return wire.ConnectionBot{Made: false}, nil
	})
}

// githubLogin is the person's GitHub login, from this host's GitHub connection.
func (d *Daemon) githubLogin() (connections.Store, string, error) {
	s, err := d.connectionStore()
	if err != nil {
		return nil, "", err
	}
	c, ok, err := s.Get(connections.GitHub)
	if err != nil {
		return nil, "", err
	}
	if !ok || c.Login == "" || c.SignInAgain {
		return nil, "", invalid("Connect GitHub first: the bot is made for your GitHub account.")
	}
	return s, c.Login, nil
}

func (d *Daemon) githubBotStart(origin string, public bool) (wire.ConnectionBotStart, error) {
	_, login, err := d.githubLogin()
	if err != nil {
		return wire.ConnectionBotStart{}, err
	}
	if origin != "" {
		if origin, err = connections.CleanOrigin(origin); err != nil {
			return wire.ConnectionBotStart{}, invalid("The setup could not start: " + err.Error() + ".")
		}
	}
	start, err := connections.NewBotStart(login, public, origin)
	if err != nil {
		return wire.ConnectionBotStart{}, invalid("The setup could not start: " + err.Error() + ".")
	}
	until := time.Now().Add(botSetupLimit)
	d.botMu.Lock()
	if d.botSetups == nil {
		d.botSetups = map[string]time.Time{}
	}
	for state, end := range d.botSetups {
		if time.Now().After(end) {
			delete(d.botSetups, state)
		}
	}
	d.botSetups[start.State] = until
	d.botMu.Unlock()
	log.Printf("connections: github bot setup started")
	return wire.ConnectionBotStart{Action: start.Action, Manifest: start.Manifest, State: start.State, ExpiresAt: wire.DateOf(until)}, nil
}

// takeBotSetup ends the setup with state, once: a second complete with the same state fails.
func (d *Daemon) takeBotSetup(state string) bool {
	d.botMu.Lock()
	defer d.botMu.Unlock()
	for s, end := range d.botSetups {
		if subtle.ConstantTimeCompare([]byte(s), []byte(state)) == 1 {
			delete(d.botSetups, s)
			return time.Now().Before(end)
		}
	}
	return false
}

func (d *Daemon) githubBotComplete(ctx context.Context, r wire.ConnectionBotCompleteRequest) (wire.ConnectionBot, error) {
	if !d.takeBotSetup(r.State) {
		log.Printf("connections: github bot setup came back with another state")
		return wire.ConnectionBot{}, invalid("The setup came back for another request, or it ended. Make the bot again.")
	}
	if e := deref(r.Error); e != "" || deref(r.Code) == "" {
		log.Printf("connections: github bot setup failed")
		why := "GitHub gave no code."
		if e != "" {
			why = "GitHub said " + e + "."
		}
		return wire.ConnectionBot{Made: false, Message: &why}, nil
	}
	s, login, err := d.githubLogin()
	if err != nil {
		return wire.ConnectionBot{}, err
	}
	ctx, cancel := context.WithTimeout(ctx, time.Minute)
	defer cancel()
	bot, err := d.botClient().Convert(ctx, *r.Code, login)
	if err != nil {
		if errors.Is(err, connections.ErrCodeUsed) {
			log.Printf("connections: github bot code was already used")
		} else {
			log.Printf("connections: github bot code not spent")
		}
		why := err.Error() + "."
		return wire.ConnectionBot{Made: false, Message: &why}, nil
	}
	d.connRenew.Lock()
	err = s.Put(bot.Connection())
	d.connRenew.Unlock()
	if err != nil {
		log.Printf("connections: github bot not kept")
		why := "The bot was made on GitHub, but this machine could not keep its key: " + err.Error() + ". Delete the App on GitHub, then make it again."
		return wire.ConnectionBot{Made: false, Message: &why}, nil
	}
	log.Printf("connections: github bot made")
	// To the person's other machines, sealed to each (#3950).
	d.goShareBotKey(true)
	w := wireBot(bot, nil, nil)
	w.KeyOn = d.botKeyOn(bot.AppID)
	return w, nil
}

// githubBot is the bot this host keeps, with the accounts it is installed on (asked of GitHub).
func (d *Daemon) githubBot(ctx context.Context) (wire.ConnectionBot, error) {
	s, err := d.connectionStore()
	if err != nil {
		return wire.ConnectionBot{}, err
	}
	c, ok, err := s.Get(connections.GitHubBot)
	if err != nil {
		return wire.ConnectionBot{}, err
	}
	bot, made := connections.BotOf(c)
	if !ok || !made {
		return wire.ConnectionBot{Made: false}, nil
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	list, err := d.botClient().Installations(ctx, bot)
	var w wire.ConnectionBot
	if err != nil {
		why := err.Error() + "."
		w = wireBot(bot, nil, &why)
	} else {
		w = wireBot(bot, list, nil)
	}
	w.KeyOn = d.botKeyOn(bot.AppID)
	return w, nil
}

func wireBot(b connections.Bot, list []connections.Installation, message *string) wire.ConnectionBot {
	name, slug, owner, install := b.Name(), b.Slug, b.Owner, b.InstallURL()
	app := "https://github.com/settings/apps/" + slug
	if owner != "" && owner != b.Person {
		app = "https://github.com/organizations/" + owner + "/settings/apps/" + slug
	}
	w := wire.ConnectionBot{Made: true, Name: &name, Slug: &slug, InstallURL: &install, AppURL: &app, Message: message}
	if owner != "" {
		w.Owner = &owner
	}
	if list != nil {
		w.Installations = []wire.ConnectionBotInstallation{}
		for _, i := range list {
			u := i.SettingsURL()
			w.Installations = append(w.Installations, wire.ConnectionBotInstallation{Account: i.Account, All: i.All, SettingsURL: &u})
		}
	}
	return w
}
