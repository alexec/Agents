package agentsd

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/alexec/agents/Go/wire"
	sdk "github.com/coder/acp-go-sdk"
)

// Ports RuntimeAccountTests: a runtime signed in by a method it offers, a method that
// needs a terminal handed back as its command, a refusal that leaves it needing a sign-in,
// signing out, and choosing and turning off its providers.

// The fake signs in with "browser", refuses "wrong", and names a terminal for "cli". Its
// providers are "main" (required, routing), "bedrock" (routing) and "openai" (no address).
func fakeAuthMethods() []sdk.AuthMethod {
	return []sdk.AuthMethod{
		{Agent: &sdk.AuthMethodAgent{Id: "browser", Name: "Sign in with a browser"}},
		{Agent: &sdk.AuthMethodAgent{Id: "wrong", Name: "Refused"}},
		{Agent: &sdk.AuthMethodAgent{Id: "cli", Name: "In a terminal", Meta: map[string]any{
			"terminal-auth": map[string]any{"command": "/Applications/My Tool/copilot", "args": []string{"login"}}}}},
	}
}

func (f *fakeRuntime) Authenticate(_ context.Context, r sdk.AuthenticateRequest) (sdk.AuthenticateResponse, error) {
	if r.MethodId == "wrong" {
		return sdk.AuthenticateResponse{}, &sdk.RequestError{Code: -32000, Message: "no such account"}
	}
	return sdk.AuthenticateResponse{}, nil
}

func (f *fakeRuntime) Logout(context.Context, sdk.LogoutRequest) (sdk.LogoutResponse, error) {
	return sdk.LogoutResponse{}, nil
}

func (f *fakeRuntime) UnstableListProviders(context.Context, sdk.UnstableListProvidersRequest) (sdk.UnstableListProvidersResponse, error) {
	return sdk.UnstableListProvidersResponse{Providers: []sdk.UnstableProviderInfo{
		{Id: "main", Required: true, Current: &sdk.UnstableProviderCurrentConfig{ApiType: sdk.UnstableLlmProtocolAnthropic, BaseUrl: "https://api.anthropic.com"},
			Supported: []sdk.UnstableLlmProtocol{sdk.UnstableLlmProtocolAnthropic}},
		{Id: "bedrock", Current: &sdk.UnstableProviderCurrentConfig{ApiType: sdk.UnstableLlmProtocolBedrock, BaseUrl: "https://bedrock.example"},
			Supported: []sdk.UnstableLlmProtocol{sdk.UnstableLlmProtocolBedrock}},
		{Id: "openai", Supported: []sdk.UnstableLlmProtocol{sdk.UnstableLlmProtocolOpenai}},
	}}, nil
}

func (f *fakeRuntime) UnstableSetProvider(_ context.Context, r sdk.UnstableSetProviderRequest) (sdk.UnstableSetProviderResponse, error) {
	if r.Id != "bedrock" || r.ApiType != sdk.UnstableLlmProtocolBedrock || r.BaseUrl != "https://bedrock.example" {
		return sdk.UnstableSetProviderResponse{}, &sdk.RequestError{Code: -32602, Message: "not that one"}
	}
	return sdk.UnstableSetProviderResponse{}, nil
}

func (f *fakeRuntime) UnstableDisableProvider(context.Context, sdk.UnstableDisableProviderRequest) (sdk.UnstableDisableProviderResponse, error) {
	return sdk.UnstableDisableProviderResponse{}, nil
}

func TestSigningARuntimeInAndOut(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()

	var a wire.RuntimeAccount
	json.Unmarshal(c.call(t, 1, "runtimes/authenticate", map[string]any{"runtimeID": "claude", "methodID": "browser"}), &a)
	if a.State != wire.RuntimeAccountStateReady || len(a.AuthMethods) != 3 || a.AuthMethods[0].ID != "browser" || !a.CanLogOut {
		t.Fatalf("%+v", a)
	}

	e := c.callError(t, 2, "runtimes/authenticate", map[string]any{"runtimeID": "claude", "methodID": "cli"})
	if e.Code != wire.FailureNeedsSignIn || e.Message != "Run this in a terminal: '/Applications/My Tool/copilot' login" {
		t.Fatalf("%+v", e)
	}

	e = c.callError(t, 3, "runtimes/authenticate", map[string]any{"runtimeID": "claude", "methodID": "wrong"})
	if e.Code != wire.FailureNeedsSignIn || e.Message != "That did not sign in: no such account" {
		t.Fatalf("%+v", e)
	}
	if a := accountOf(t, c, "claude"); a.State != wire.RuntimeAccountStateNeedsSignIn {
		t.Fatalf("%+v", a)
	}

	// Signing out stops the agents using the runtime, and says which.
	running := seeded(t, d, t.TempDir(), func(a *wire.Agent) { a.State = wire.AgentStateRunning })
	var stopped []wire.UUID
	json.Unmarshal(c.call(t, 4, "runtimes/logout", map[string]any{"runtimeID": "claude"}), &stopped)
	if len(stopped) != 1 || stopped[0] != running.ID {
		t.Fatal(stopped)
	}
	if a := accountOf(t, c, "claude"); a.State != wire.RuntimeAccountStateNeedsSignIn || a.SignedInAs != nil {
		t.Fatalf("%+v", a)
	}
	if e := c.callError(t, 5, "runtimes/logout", map[string]any{"runtimeID": "nobody"}); e.Code != CodeRuntimeNotFound {
		t.Fatalf("%+v", e)
	}
}

func TestChoosingARuntimesProvider(t *testing.T) {
	fakeRuntimes(t)
	d, c := start(t, t.TempDir())
	defer d.Shutdown()

	var a wire.RuntimeAccount
	json.Unmarshal(c.call(t, 1, "runtimes/setProvider", map[string]any{"runtimeID": "claude", "providerID": "bedrock"}), &a)
	if a.CurrentProviderID == nil || *a.CurrentProviderID != "bedrock" || len(a.Providers) != 3 ||
		a.Providers[0].ID != "main" || !*a.Providers[0].Configured || *a.Providers[2].Configured || *a.Providers[2].Protocol != "openai" {
		t.Fatalf("%+v", a)
	}
	if e := c.callError(t, 2, "runtimes/setProvider", map[string]any{"runtimeID": "claude", "providerID": "nobody"}); e.Code != CodeInvalidParams {
		t.Fatalf("%+v", e)
	}
	if e := c.callError(t, 5, "runtimes/setProvider", map[string]any{"runtimeID": "claude", "providerID": "openai"}); e.Code != CodeInvalidParams ||
		e.Message != "openai has no address set up for Claude yet. Set it up in Claude first." {
		t.Fatalf("%+v", e)
	}
	if e := c.callError(t, 3, "runtimes/disableProvider", map[string]any{"runtimeID": "claude", "providerID": "main"}); e.Code != CodeInvalidParams ||
		e.Message != "main is required by this runtime and cannot be turned off." {
		t.Fatalf("%+v", e)
	}
	a = wire.RuntimeAccount{}
	json.Unmarshal(c.call(t, 4, "runtimes/disableProvider", map[string]any{"runtimeID": "claude", "providerID": "openai"}), &a)
	// The runtime's own list after: two route, so which is current is not known.
	if a.CurrentProviderID != nil || len(a.Providers) != 3 {
		t.Fatalf("%+v", a)
	}
}

func accountOf(t *testing.T, c *conn, runtimeID string) wire.RuntimeAccount {
	t.Helper()
	var all []wire.RuntimeAccount
	json.Unmarshal(c.call(t, 99, "runtimes/accounts", nil), &all)
	for _, a := range all {
		if a.RuntimeID == runtimeID {
			return a
		}
	}
	t.Fatalf("no account for %s", runtimeID)
	return wire.RuntimeAccount{}
}
