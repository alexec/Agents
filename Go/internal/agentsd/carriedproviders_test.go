package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"

	"github.com/alexec/agents/Go/internal/codespacessh"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/wire"
)

func carriedDaemon(t *testing.T) (*Daemon, string) {
	t.Setenv("AGENTS_PERSONAL_HOME", "")
	home := t.TempDir()
	d := &Daemon{}
	d.PersonalHome = home
	return d, home
}

// A host says it can carry a provider, so the control plane asks it (#3398).
func TestAHostSaysItCarriesProviders(t *testing.T) {
	d, _ := carriedDaemon(t)
	d.handlers = map[string]Handler{}
	if !slices.Contains(d.Capabilities(), wire.CapProvidersCarry1) {
		t.Fatalf("%v", d.Capabilities())
	}
}

func ask(t *testing.T, d *Daemon, method string, params any) wire.ProviderCarried {
	t.Helper()
	raw, _ := json.Marshal(params)
	out, ok := d.Asked(method, raw)
	if !ok {
		t.Fatalf("%s was not answered", method)
	}
	return out.(wire.ProviderCarried)
}

// A carried provider's secrets are kept on its machine, readable by its user only, and go
// when the control plane says it was removed (#3398).
func TestACarriedProvidersSecretsAreKeptHereAndForgotten(t *testing.T) {
	d, home := carriedDaemon(t)
	file := filepath.Join(home, ".agents-secrets", providers.SecretsFileName)
	if out := ask(t, d, wire.CallProvidersKeepSecrets.Name, wire.ProviderSecretsKeep{Provider: "p1",
		Secrets: map[string]string{"GITHUB_TOKEN": "ghp_kept"}}); out.Error != nil {
		t.Fatal(*out.Error)
	}
	info, err := os.Stat(file)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("%v %v", info, err)
	}
	if got := d.carried().store.Values("p1"); got["GITHUB_TOKEN"] != "ghp_kept" {
		t.Fatalf("%v", got)
	}
	if out := ask(t, d, wire.CallProvidersForget.Name, wire.ProviderForget{Provider: "p1"}); out.Error != nil {
		t.Fatal(*out.Error)
	}
	data, _ := os.ReadFile(file)
	if strings.Contains(string(data), "ghp_kept") {
		t.Fatal("a removed provider's secret is still here")
	}
}

// A call whose record is not the provider's is refused, and a provider that can't be
// reached says so, with no secret's value in its words.
func TestACarryIsRefusedOrFailsInWords(t *testing.T) {
	d, _ := carriedDaemon(t)
	record, _ := json.Marshal(providers.ProviderRecord{ID: "p2", Name: "Gone", Kind: providers.KindStdio,
		Command: new("/no/such/provider")})
	out := ask(t, d, wire.CallProvidersCarry.Name, wire.ProviderCarry{Provider: "other", Record: record, Call: "list"})
	if out.Error == nil || !strings.Contains(*out.Error, "record") {
		t.Fatalf("%+v", out)
	}
	out = ask(t, d, wire.CallProvidersCarry.Name, wire.ProviderCarry{Provider: "p2", Record: record, Call: "list",
		Secrets: map[string]string{"TOKEN": "draft-secret-value"}})
	if out.Error == nil || strings.Contains(*out.Error, "draft-secret-value") {
		t.Fatalf("%+v", out)
	}
}

// What a provider answers goes back with every secret's value said as its name.
func TestACarriedAnswerHoldsNoSecret(t *testing.T) {
	r := providers.NewRedaction(map[string]string{"TOKEN": "s3cr3t-value"})
	words := "refused s3cr3t-value"
	out := redacted(r, wire.ProviderCarried{Result: json.RawMessage(`{"note":"s3cr3t-value"}`), Error: &words})
	if strings.Contains(string(out.Result), "s3cr3t-value") || strings.Contains(*out.Error, "s3cr3t-value") {
		t.Fatalf("%s %s", out.Result, *out.Error)
	}
	if !json.Valid(out.Result) {
		t.Fatalf("%s", out.Result)
	}
}

// A deleted codespace's ssh block goes from the ssh config here (#3746).
func TestADeletedCodespaceLeavesNoSSHBlock(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config")
	t.Setenv("AGENTS_SSH_CONFIG", path)
	for _, name := range []string{"gone-cs", "kept-cs"} {
		if err := codespacessh.Merge(path, name, []byte("Host cs."+name+".main")); err != nil {
			t.Fatal(err)
		}
	}
	forgetCodespaceSSH("gone-cs")
	forgetCodespaceSSH("")
	if codespacessh.Has(path, "gone-cs", "cs.gone-cs.main") || !codespacessh.Has(path, "kept-cs", "cs.kept-cs.main") {
		data, _ := os.ReadFile(path)
		t.Fatalf("%s", data)
	}
}
