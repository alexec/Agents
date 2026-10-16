package channels

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"
)

// SlackChannelTests.theRoundTripThroughAControlPlaneAndAHost, with the service's hooks
// faked: settings in memory, a host that holds one question, and a fake Slack.

type fakeService struct {
	mu       sync.Mutex
	settings *ChannelSettings
	told     []ChannelsState
}

func (s *fakeService) hooks(slack *fakeSlack) Hooks {
	return Hooks{
		Settings: func() *ChannelSettings {
			s.mu.Lock()
			defer s.mu.Unlock()
			return s.settings
		},
		Save: func(c ChannelSettings) error {
			s.mu.Lock()
			defer s.mu.Unlock()
			s.settings = &c
			return nil
		},
		Changed: func(state ChannelsState) {
			s.mu.Lock()
			defer s.mu.Unlock()
			s.told = append(s.told, state)
		},
		Slack: func(tokens SlackTokens, memberID string) NeedsChannel {
			return NewSlackChannel(tokens, memberID, slack, func(int) time.Duration { return 10 * time.Millisecond }, nil)
		},
	}
}

func mode(t *testing.T, path string) os.FileMode {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info.Mode().Perm()
}

func TestTheRoundTripThroughChannelsAndAHost(t *testing.T) {
	home := t.TempDir()
	slack := newFakeSlack()
	service := &fakeService{}
	request := form([]Property{drink}, ptr("Tea or coffee?"))
	host := &fakeHost{pending: []ElicitationRequest{request}}
	c := New(home, NewDesk(host.hooks(), nil), service.hooks(slack))
	c.Apply()
	t.Cleanup(c.Stop)

	off := c.State()
	if off.Slack.Status != StatusOff || !off.Slack.Available || off.Slack.AppTokenSet {
		t.Fatalf("off %+v", off)
	}
	// A member ID refused.
	_, err := c.Set(ChannelsSet{Slack: &SlackSet{MemberID: ptr("alex")}})
	var refused *RPCError
	if !errors.As(err, &refused) || refused.Code != CodeInvalidParams || !strings.Contains(refused.Message, "isn’t a Slack member ID") {
		t.Fatalf("err %v", err)
	}
	// A bot token in the app token's place.
	_, err = c.Set(ChannelsSet{Slack: &SlackSet{AppToken: ptr("xoxb-1")}})
	if !errors.As(err, &refused) || refused.Message != "A Slack app token starts with xapp-." {
		t.Fatalf("err %v", err)
	}
	set, err := c.Set(ChannelsSet{Slack: &SlackSet{Enabled: ptr(true), MemberID: ptr(" " + member + " "),
		AppToken: ptr("xapp-secret"), BotToken: ptr(" xoxb-secret\n")}})
	if err != nil {
		t.Fatal(err)
	}
	if !set.Slack.Enabled || !set.Slack.AppTokenSet || !set.Slack.BotTokenSet || set.Slack.MemberID != member {
		t.Fatalf("set %+v", set)
	}
	// Written to the secrets folder only, 0600 in 0700, and never sent back.
	file := filepath.Join(home, ".agents-secrets", "channels.env")
	data, err := os.ReadFile(file)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != "SLACK_APP_TOKEN=xapp-secret\nSLACK_BOT_TOKEN=xoxb-secret\n" {
		t.Fatalf("channels.env %q", data)
	}
	if m := mode(t, file); m != 0o600 {
		t.Fatalf("file mode %o", m)
	}
	if m := mode(t, filepath.Dir(file)); m != 0o700 {
		t.Fatalf("folder mode %o", m)
	}
	wire, _ := json.Marshal(c.State())
	if strings.Contains(string(wire), "secret") {
		t.Fatalf("a token was sent: %s", wire)
	}
	if got := service.settings; got == nil || !reflect.DeepEqual(*got.Slack, SlackChannelSettings{Enabled: true, MemberID: member}) {
		t.Fatalf("settings %+v", got)
	}
	eventually(t, "connected", func() bool { return c.State().Slack.Status == StatusConnected })
	if got := slack.made("apps.connections.open"); got[0].token != "xapp-secret" {
		t.Fatalf("token %v", got[0].token)
	}
	// The same settings again leave the connection alone.
	if _, err := c.Set(ChannelsSet{Slack: &SlackSet{Enabled: ptr(true)}}); err != nil {
		t.Fatal(err)
	}
	if n := slack.connections(); n != 1 {
		t.Fatalf("%d connections", n)
	}

	// The host offers its question; Slack shows it; the member presses Tea.
	c.Desk.Post("h1", offer(request))
	eventually(t, "posted", func() bool { return len(slack.made("chat.postMessage")) > 0 })
	actions := actionsOf(blocksOf(t, slack.made("chat.postMessage")[0].body))
	slack.press("tea", actions["block_id"].(string), member)
	eventually(t, "answered", func() bool { return len(host.answered()) > 0 })
	answer := host.answered()[0]
	if answer.RequestID != request.ID || !reflect.DeepEqual(answer.Content, map[string]any{"drink": "tea"}) {
		t.Fatalf("answer %+v", answer)
	}
	eventually(t, "updated", func() bool { return len(slack.made("chat.update")) > 0 })

	// Turned off, it stops.
	if _, err := c.Set(ChannelsSet{Slack: &SlackSet{Enabled: ptr(false)}}); err != nil {
		t.Fatal(err)
	}
	if s := c.State().Slack.Status; s != StatusOff {
		t.Fatalf("status %s", s)
	}
	// An empty token is taken away.
	state, err := c.Set(ChannelsSet{Slack: &SlackSet{AppToken: ptr("")}})
	if err != nil || state.Slack.AppTokenSet || !state.Slack.BotTokenSet {
		t.Fatalf("state %+v %v", state, err)
	}
	service.mu.Lock()
	told := len(service.told)
	service.mu.Unlock()
	if told == 0 {
		t.Fatal("no client was told")
	}
}

func TestEnabledWithoutTokensOrMemberSaysWhatIsMissing(t *testing.T) {
	home := t.TempDir()
	service := &fakeService{}
	c := New(home, NewDesk(DeskHooks{}, nil), service.hooks(newFakeSlack()))
	state, err := c.Set(ChannelsSet{Slack: &SlackSet{Enabled: ptr(true)}})
	if err != nil || state.Slack.Status != StatusFailed || *state.Slack.Detail != "Set both Slack tokens." {
		t.Fatalf("state %+v %v", state, err)
	}
	state, err = c.Set(ChannelsSet{Slack: &SlackSet{AppToken: ptr("xapp-1"), BotToken: ptr("xoxb-1")}})
	if err != nil || *state.Slack.Detail != "Set your Slack member ID." {
		t.Fatalf("state %+v %v", state, err)
	}
}

func TestAnUnreadableSecretsFileIsNotWrittenOver(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root reads every file")
	}
	home := t.TempDir()
	file := SecretsPath(home, FileName)
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(file, []byte("SLACK_APP_TOKEN=xapp-kept\n"), 0o000); err != nil {
		t.Fatal(err)
	}
	c := New(home, NewDesk(DeskHooks{}, nil), (&fakeService{}).hooks(newFakeSlack()))
	_, err := c.Set(ChannelsSet{Slack: &SlackSet{BotToken: ptr("xoxb-1")}})
	var refused *RPCError
	if !errors.As(err, &refused) || refused.Code != CodeNotPermitted ||
		refused.Message != file+" could not be read, so nothing was written to it. Check its permissions." {
		t.Fatalf("err %v", err)
	}
}
