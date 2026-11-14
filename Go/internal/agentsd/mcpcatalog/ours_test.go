package mcpcatalog

import (
	"reflect"
	"strings"
	"testing"

	"github.com/agentloops-dev/agents/Go/internal/azureboardsmcp"
	"github.com/agentloops-dev/agents/Go/internal/azuredevopsmcp"
	"github.com/agentloops-dev/agents/Go/internal/betterstackmcp"
	"github.com/agentloops-dev/agents/Go/internal/bitbucketmcp"
	"github.com/agentloops-dev/agents/Go/internal/emailmcp"
	"github.com/agentloops-dev/agents/Go/internal/forgejomcp"
	"github.com/agentloops-dev/agents/Go/internal/githubmcp"
	"github.com/agentloops-dev/agents/Go/internal/gitlabmcp"
	"github.com/agentloops-dev/agents/Go/internal/googlechatmcp"
	"github.com/agentloops-dev/agents/Go/internal/jiramcp"
	"github.com/agentloops-dev/agents/Go/internal/linearmcp"
	"github.com/agentloops-dev/agents/Go/internal/sentrymcp"
	"github.com/agentloops-dev/agents/Go/internal/slackmcp"
	"github.com/agentloops-dev/agents/Go/internal/whatsappmcp"
	"github.com/agentloops-dev/agents/Go/wire"
)

// What ours are written to declare is what they declare: the catalogue shows it before a
// host has checked a copy (#1428).
func TestOursDeclareWhatTheirServersDeclare(t *testing.T) {
	github, _ := OursByID("agents/github")
	linear, _ := OursByID("agents/linear")
	if !reflect.DeepEqual(github.Declares.Events, githubmcp.EventNames()) {
		t.Fatalf("github events: %v, the server's %v", github.Declares.Events, githubmcp.EventNames())
	}
	if !reflect.DeepEqual(linear.Declares.Events, linearmcp.EventNames()) {
		t.Fatalf("linear events: %v, the server's %v", linear.Declares.Events, linearmcp.EventNames())
	}
	gitlab, _ := OursByID("agents/gitlab")
	if !reflect.DeepEqual(gitlab.Declares.Events, gitlabmcp.EventNames()) || !gitlab.Declares.Tools {
		t.Fatalf("gitlab: %v, the server's %v", gitlab.Declares, gitlabmcp.EventNames())
	}
	email, _ := OursByID("agents/email")
	if !reflect.DeepEqual(email.Declares.Events, emailmcp.EventNames()) || !email.Declares.Tools || !email.Declares.Views {
		t.Fatalf("email: %v, the server's %v", email.Declares, emailmcp.EventNames())
	}
	jira, _ := OursByID("agents/jira")
	if !reflect.DeepEqual(jira.Declares.Events, jiramcp.EventNames()) || !jira.Declares.Tools || !jira.Declares.Views {
		t.Fatalf("jira: %v, the server's %v", jira.Declares, jiramcp.EventNames())
	}
	slack, _ := OursByID("agents/slack")
	if !reflect.DeepEqual(slack.Declares.Events, slackmcp.EventNames()) || !slack.Declares.Tools || slack.Declares.Views {
		t.Fatalf("slack: %v, the server's %v", slack.Declares, slackmcp.EventNames())
	}
	// linear-mcp has show_issues (TestTheViewListsOpenIssues); github-mcp has the official ones.
	if !linear.Declares.Tools || !linear.Declares.Views || !github.Declares.Tools {
		t.Fatalf("tools: github %v, linear %v", github.Declares.Tools, linear.Declares.Tools)
	}
}

func TestLevelsComeFromWhatAServerDeclares(t *testing.T) {
	saved := ReadyMadeEvents
	defer func() { ReadyMadeEvents = saved }()

	ReadyMadeEvents = nil
	got := Levels(Declared{Tools: true, HasEvents: true, Events: []string{"pr.opened"}}, false)
	if got != (wire.MCPLevels{Tools: true, Events: true}) {
		t.Fatalf("no ready-made workflows: %+v", got)
	}
	// A workflow names an event, never a server: any server that declares it reaches Workflows.
	ReadyMadeEvents = []string{"pr.opened"}
	got = Levels(Declared{HasEvents: true, Events: []string{"pr.opened"}, Views: true}, true)
	if got != (wire.MCPLevels{Events: true, Views: true, Workflows: true, Tested: true}) {
		t.Fatalf("a ready-made workflow's event: %+v", got)
	}
	if got := Levels(Declared{Tools: true}, false); got != (wire.MCPLevels{Tools: true}) {
		t.Fatalf("tools only: %+v", got)
	}
}

func TestOursAreAddedHostedWithNoSecretToAsk(t *testing.T) {
	// Linear reads the person's connection (#1343), as GitHub does: no key to ask for.
	linear, _ := OursByID("agents/linear")
	built := BuildOurs(linear, func(string) bool { return false })
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != `{"command":"linear-mcp","hosted":true}` {
		t.Fatalf("entry: %s", got)
	}
	if built.NameHere != "linear" || built.ChosenRun != wire.MCPRunKindCommand || len(built.Variables) != 0 {
		t.Fatalf("built: %+v", built)
	}
	if o, ok := OursByCommand("/usr/local/bin/github-mcp"); !ok || o.ID != "agents/github" {
		t.Fatalf("by command: %+v %v", o, ok)
	}
	if _, ok := OursByCommand("npx"); ok {
		t.Fatal("npx is not ours")
	}
	// GitLab reads the person's connection (#1630), as Linear does: no secret to ask for.
	gitlab, _ := OursByID("agents/gitlab")
	built = BuildOurs(gitlab, func(string) bool { return false })
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != `{"command":"gitlab-mcp","hosted":true}` {
		t.Fatalf("gitlab entry: %s", got)
	}
	if built.NameHere != "gitlab" || len(built.Variables) != 0 {
		t.Fatalf("gitlab built: %+v", built)
	}
	// Email reads the person's email connection (#1780): no secret to ask for.
	email, _ := OursByID("agents/email")
	built = BuildOurs(email, func(string) bool { return false })
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != `{"command":"email-mcp","hosted":true}` {
		t.Fatalf("email entry: %s", got)
	}
	if built.NameHere != "email" || len(built.Variables) != 0 {
		t.Fatalf("email built: %+v", built)
	}
	r := OursResult(linear, linear.Declares)
	if r.Marketplace == nil || *r.Marketplace != AgentsMarketplace || r.Levels == nil || !r.Levels.Tools || !r.Levels.Views || !r.Levels.Events {
		t.Fatalf("result: %+v", r)
	}
}

// Jira reads the person's Atlassian connection (#3304), as Linear does: it asks for no secret.
func TestJiraAsksForNoSecret(t *testing.T) {
	jira, ok := OursByID("agents/jira")
	if !ok || jira.Command != "jira-mcp" {
		t.Fatalf("jira: %+v %v", jira, ok)
	}
	built := BuildOurs(jira, func(string) bool { return false })
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != `{"command":"jira-mcp","hosted":true}` {
		t.Fatalf("entry: %s", got)
	}
	if len(built.Variables) != 0 || built.NameHere != "jira" {
		t.Fatalf("built: %+v", built)
	}
	r := OursResult(jira, jira.Declares)
	if r.Levels == nil || !r.Levels.Workflows || r.Levels.Tested {
		t.Fatalf("issue.labelled reaches Workflows; untested: %+v", r.Levels)
	}
	if r.Marketplace == nil || *r.Marketplace != AgentsMarketplace || r.Levels == nil || !r.Levels.Tools || !r.Levels.Views || !r.Levels.Events {
		t.Fatalf("result: %+v", r)
	}
}

// Slack has no connection to read (#3475): it asks for the Slack app's two tokens, kept in
// the person's secrets.env and named in its entry.
func TestSlackAsksForItsTwoTokens(t *testing.T) {
	slack, ok := OursByID("agents/slack")
	if !ok || slack.Command != "slack-mcp" {
		t.Fatalf("slack: %+v %v", slack, ok)
	}
	if o, ok := OursByCommand("slack-mcp"); !ok || o.ID != "agents/slack" {
		t.Fatalf("by command: %+v %v", o, ok)
	}
	built := BuildOurs(slack, func(name string) bool { return name == "SLACK_BOT_TOKEN" })
	want := `{"command":"slack-mcp","hosted":true,"env":{"SLACK_BOT_TOKEN":"${SLACK_BOT_TOKEN}","SLACK_APP_TOKEN":"${SLACK_APP_TOKEN}"}}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if built.NameHere != "slack" || len(built.Variables) != 2 {
		t.Fatalf("built: %+v", built)
	}
	bot, app := built.Variables[0], built.Variables[1]
	if bot.Name != "SLACK_BOT_TOKEN" || bot.Kind != wire.MCPVariableKindSecret || !bot.Required || !bot.AlreadySet ||
		app.Name != "SLACK_APP_TOKEN" || app.Kind != wire.MCPVariableKindSecret || !app.Required || app.AlreadySet {
		t.Fatalf("variables: %+v", built.Variables)
	}
	r := OursResult(slack, slack.Declares)
	if r.Levels == nil || !r.Levels.Tools || !r.Levels.Events || r.Levels.Views || r.Levels.Workflows || r.Levels.Tested {
		t.Fatalf("levels: %+v", r.Levels)
	}
}

// Google Chat (#1016) has no connection to read: it asks for the Chat app's key, kept in the
// person's secrets, and declares the events its server raises.
func TestGoogleChatAsksForItsKey(t *testing.T) {
	chat, ok := OursByID("agents/googlechat")
	if !ok || chat.Command != "googlechat-mcp" || !chat.Declares.Tools || chat.Declares.Views ||
		!reflect.DeepEqual(chat.Declares.Events, googlechatmcp.EventNames()) {
		t.Fatalf("googlechat: %+v %v, the server's %v", chat, ok, googlechatmcp.EventNames())
	}
	built := BuildOurs(chat, func(name string) bool { return name == "GOOGLE_CHAT_SUBSCRIPTION" })
	want := `{"command":"googlechat-mcp","hosted":true,"env":{"GOOGLE_CHAT_CREDENTIALS":"${GOOGLE_CHAT_CREDENTIALS}","GOOGLE_CHAT_SUBSCRIPTION":"${GOOGLE_CHAT_SUBSCRIPTION}"}}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if len(built.Variables) != 2 || !built.Variables[0].Required || built.Variables[0].AlreadySet ||
		built.Variables[1].Required || !built.Variables[1].AlreadySet || built.Variables[0].Kind != wire.MCPVariableKindSecret {
		t.Fatalf("variables: %+v", built.Variables)
	}
}

// WhatsApp (#1352) asks for the Cloud API's four values, kept in the person's secrets, and
// declares the events its server raises.
func TestWhatsAppAsksForItsSecrets(t *testing.T) {
	wa, ok := OursByID("agents/whatsapp")
	if !ok || wa.Command != "whatsapp-mcp" || !wa.Declares.Tools || wa.Declares.Views ||
		!reflect.DeepEqual(wa.Declares.Events, whatsappmcp.EventNames()) {
		t.Fatalf("whatsapp: %+v %v, the server's %v", wa, ok, whatsappmcp.EventNames())
	}
	built := BuildOurs(wa, func(name string) bool { return name == "WHATSAPP_TOKEN" })
	want := `{"command":"whatsapp-mcp","hosted":true,"env":{"WHATSAPP_TOKEN":"${WHATSAPP_TOKEN}","WHATSAPP_PHONE_NUMBER_ID":"${WHATSAPP_PHONE_NUMBER_ID}",` +
		`"WHATSAPP_APP_SECRET":"${WHATSAPP_APP_SECRET}","WHATSAPP_VERIFY_TOKEN":"${WHATSAPP_VERIFY_TOKEN}","WHATSAPP_WEBHOOK_ADDR":"${WHATSAPP_WEBHOOK_ADDR}"}}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if len(built.Variables) != 5 || !built.Variables[0].Required || !built.Variables[0].AlreadySet || built.Variables[1].AlreadySet ||
		built.Variables[4].Required || built.Variables[0].Kind != wire.MCPVariableKindSecret {
		t.Fatalf("variables: %+v", built.Variables)
	}
}

// Sentry's events (#3583) ask for a token and the organization, kept in the person's
// secrets, declare the events their server raises and no tools: Sentry's own server has them.
func TestSentryEventsAskForItsToken(t *testing.T) {
	sentry, ok := OursByID("agents/sentry")
	if !ok || sentry.Command != "sentry-mcp" || sentry.Declares.Tools || sentry.Declares.Views ||
		!reflect.DeepEqual(sentry.Declares.Events, sentrymcp.EventNames()) {
		t.Fatalf("sentry: %+v %v, the server's %v", sentry, ok, sentrymcp.EventNames())
	}
	if sentry.NameHere() != "sentry-events" {
		t.Fatalf("name: %s", sentry.NameHere())
	}
	built := BuildOurs(sentry, func(name string) bool { return name == "SENTRY_ORG" })
	want := `{"command":"sentry-mcp","hosted":true,"env":{"SENTRY_AUTH_TOKEN":"${SENTRY_AUTH_TOKEN}","SENTRY_ORG":"${SENTRY_ORG}","SENTRY_URL":"${SENTRY_URL}"}}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if len(built.Variables) != 3 || !built.Variables[0].Required || built.Variables[0].AlreadySet || !built.Variables[1].AlreadySet ||
		built.Variables[2].Required || built.Variables[0].Kind != wire.MCPVariableKindSecret {
		t.Fatalf("variables: %+v", built.Variables)
	}
}

// Better Stack's events (#3655) ask for a token, kept in the person's secrets, declare the
// events their server raises and no tools: Better Stack's own server has them.
func TestBetterStackEventsAskForItsToken(t *testing.T) {
	bs, ok := OursByID("agents/betterstack")
	if !ok || bs.Command != "betterstack-mcp" || bs.Declares.Tools || bs.Declares.Views ||
		!reflect.DeepEqual(bs.Declares.Events, betterstackmcp.EventNames()) {
		t.Fatalf("betterstack: %+v %v, the server's %v", bs, ok, betterstackmcp.EventNames())
	}
	if bs.NameHere() != "better-stack-events" {
		t.Fatalf("name: %s", bs.NameHere())
	}
	built := BuildOurs(bs, func(string) bool { return false })
	want := `{"command":"betterstack-mcp","hosted":true,"env":{"BETTERSTACK_API_TOKEN":"${BETTERSTACK_API_TOKEN}","BETTERSTACK_TEAM":"${BETTERSTACK_TEAM}","BETTERSTACK_URL":"${BETTERSTACK_URL}"}}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if len(built.Variables) != 3 || !built.Variables[0].Required || built.Variables[1].Required || built.Variables[2].Required {
		t.Fatalf("variables: %+v", built.Variables)
	}
}

// Forgejo (#1753) asks for no secret: it reads the Forgejo connection (#3752), as the gitlab
// server does, and FORGEJO_TOKEN only when the person names it by hand. It declares the
// events its server raises: the gitlab server's.
func TestForgejoReadsItsConnection(t *testing.T) {
	forgejo, ok := OursByID("agents/forgejo")
	if !ok || forgejo.Command != "forgejo-mcp" || !forgejo.Declares.Tools || !forgejo.Declares.Views ||
		!reflect.DeepEqual(forgejo.Declares.Events, forgejomcp.EventNames()) {
		t.Fatalf("forgejo: %+v %v, the server's %v", forgejo, ok, forgejomcp.EventNames())
	}
	built := BuildOurs(forgejo, func(string) bool { return false })
	want := `{"command":"forgejo-mcp","hosted":true}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if built.NameHere != "forgejo" || len(built.Variables) != 0 {
		t.Fatalf("built: %+v", built)
	}
}

// Bitbucket (#2828) asks for no secret: it reads the Bitbucket connection (#3785), as the
// forgejo server does, and BITBUCKET_TOKEN (with BITBUCKET_EMAIL) only when the person names
// it by hand. It declares the events its server raises: the gitlab server's.
func TestBitbucketReadsItsConnection(t *testing.T) {
	bitbucket, ok := OursByID("agents/bitbucket")
	if !ok || bitbucket.Command != "bitbucket-mcp" || !bitbucket.Declares.Tools || !bitbucket.Declares.Views ||
		!reflect.DeepEqual(bitbucket.Declares.Events, bitbucketmcp.EventNames()) {
		t.Fatalf("bitbucket: %+v %v, the server's %v", bitbucket, ok, bitbucketmcp.EventNames())
	}
	built := BuildOurs(bitbucket, func(string) bool { return false })
	want := `{"command":"bitbucket-mcp","hosted":true}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if built.NameHere != "bitbucket" || len(built.Variables) != 0 {
		t.Fatalf("built: %+v", built)
	}
}

// Azure DevOps (#2829) asks for no secret: it reads the Azure DevOps connection (#3802), as the
// bitbucket server does, and AZURE_DEVOPS_TOKEN (with AZURE_DEVOPS_URL) only when the person
// names it by hand. It declares the events its server raises: the gitlab server's pull
// request events.
func TestAzureDevOpsReadsItsConnection(t *testing.T) {
	ado, ok := OursByID("agents/azuredevops")
	if !ok || ado.Command != "azuredevops-mcp" || !ado.Declares.Tools || !ado.Declares.Views ||
		!reflect.DeepEqual(ado.Declares.Events, azuredevopsmcp.EventNames()) {
		t.Fatalf("azuredevops: %+v %v, the server's %v", ado, ok, azuredevopsmcp.EventNames())
	}
	built := BuildOurs(ado, func(string) bool { return false })
	want := `{"command":"azuredevops-mcp","hosted":true}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if built.NameHere != "azure-devops" || len(built.Variables) != 0 {
		t.Fatalf("built: %+v", built)
	}
}

// Azure Boards (#3804) is the tracker's: it reads the Azure DevOps connection (#3802), asks
// only for the project, and declares the jira and linear servers' issue events.
func TestAzureBoardsReadsItsConnectionAndAsksForItsProject(t *testing.T) {
	boards, ok := OursByID("agents/azureboards")
	if !ok || boards.Command != "azureboards-mcp" || !boards.Declares.Tools || !boards.Declares.Views ||
		!reflect.DeepEqual(boards.Declares.Events, azureboardsmcp.EventNames()) {
		t.Fatalf("azureboards: %+v %v, the server's %v", boards, ok, azureboardsmcp.EventNames())
	}
	built := BuildOurs(boards, func(string) bool { return false })
	want := `{"command":"azureboards-mcp","hosted":true,"env":{"AZURE_BOARDS_PROJECT":"${AZURE_BOARDS_PROJECT}"}}`
	if got := strings.Join(strings.Fields(built.Entry.Stringified()), ""); got != want {
		t.Fatalf("entry: %s", got)
	}
	if built.NameHere != "azure-boards" || len(built.Variables) != 1 || built.Variables[0].Required {
		t.Fatalf("built: %+v", built)
	}
}
