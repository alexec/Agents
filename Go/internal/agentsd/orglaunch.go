package agentsd

import (
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"strconv"

	"github.com/alexec/agents/Go/wire"
)

// A runtime's launch on an org account (#999, FR-013, research R2): first every variable
// the person's pass-through and login environment bring for the runtime is taken out, then
// the relay's address, the stand-in, the gateway's switches and its settings that are not
// secret are set. Where the runtime keeps its way to the model in a file (Codex, OpenCode),
// the file is in an account folder of the route's own under
// <root>/runtimes/org/<runtime>/<route id>, with the person's settings linked in (#840),
// and the stand-in still comes from the environment, so the file holds no secret and is
// the same for every session. Measured against each CLI with a fake provider, 2026-10-22.

// orgStandInVariable is the variable Codex and OpenCode read the stand-in from.
const orgStandInVariable = "AGENTS_ORG_STAND_IN"

// orgShared is what is linked into an org account's folder from the runtime's own, beside
// #840's accountKinds: never its settings or sign-in.
var orgShared = map[string]struct {
	folder string
	names  []string
}{}

// orgAccountFolder is an org account's folder for a runtime, made with the person's
// settings linked in.
func (d *Daemon) orgAccountFolder(runtimeID, route string) (string, error) {
	folder := filepath.Join(d.Store.Loc.Root, "runtimes", "org", runtimeID, route)
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return "", err
	}
	home := d.personalHome()
	link := func(from, into string, names []string) {
		for _, name := range names {
			src, dst := filepath.Join(from, name), filepath.Join(into, name)
			if _, err := os.Stat(src); err != nil {
				continue
			}
			if _, err := os.Lstat(dst); err == nil {
				continue
			}
			os.Symlink(src, dst)
		}
	}
	if kind, ok := accountKinds[runtimeID]; ok && home != "" {
		var names []string
		for _, n := range kind.shared {
			// Codex's config.toml is the route's own.
			if !(runtimeID == "codex" && n == "config.toml") {
				names = append(names, n)
			}
		}
		link(filepath.Join(home, kind.defaultFolder), folder, names)
	}
	if s, ok := orgShared[runtimeID]; ok && home != "" {
		into := filepath.Join(folder, s.folder)
		if err := os.MkdirAll(into, 0o700); err != nil {
			return "", err
		}
		link(filepath.Join(home, s.folder), into, s.names)
	}
	return folder, nil
}

func writeOrgFile(file string, contents []byte) error {
	if err := os.MkdirAll(filepath.Dir(file), 0o700); err != nil {
		return err
	}
	if b, err := os.ReadFile(file); err == nil && string(b) == string(contents) {
		return nil
	}
	return os.WriteFile(file, contents, 0o600)
}

// tomlString is a TOML basic string.
func tomlString(s string) string { return strconv.Quote(s) }

// withOrgAccount is the launch environment of a session on an org account. agent names the
// session whose turns the relay's tokens go to; "" for a handshake.
func (d *Daemon) withOrgAccount(env []string, runtimeID string, account *wire.AccountProfile, agent wire.UUID) ([]string, error) {
	routeID := accountRoute(account)
	r, ok := d.heldOrgRoute(routeID)
	if !ok || !routeServes(r, runtimeID) {
		return nil, &Error{Code: wire.FailureOrgRouteRemoved,
			Message: "Your organisation removed " + account.Name + ". Continue in New to move this session to another account."}
	}
	rl, err := d.relay()
	if err != nil {
		return nil, err
	}
	token := rl.standInFor(standIn{route: r.ID, runtime: runtimeID, account: account.ID, agent: agent})
	base := "https://127.0.0.1:" + strconv.Itoa(rl.port) + "/" + r.ID
	// For a runtime told to skip its own auth, the stand-in is in the path (Claude sends a
	// fixed word in its header then).
	pathBase := base + "/~" + token
	st := wire.OrgRouteSettings{}
	if r.Settings != nil {
		st = *r.Settings
	}
	str := func(p *string) string {
		if p == nil {
			return ""
		}
		return *p
	}
	env = withoutRuntimeVariables(env)
	set := func(kv ...string) { env = append(env, kv...) }
	switch runtimeID {
	case "claude":
		folder, err := d.orgAccountFolder(runtimeID, r.ID)
		if err != nil {
			return nil, err
		}
		set("CLAUDE_CONFIG_DIR="+folder, "NODE_EXTRA_CA_CERTS="+rl.caFile)
		switch r.Kind {
		case wire.OrgRouteKindBedrock:
			set("CLAUDE_CODE_USE_BEDROCK=1", "ANTHROPIC_BEDROCK_BASE_URL="+pathBase, "CLAUDE_CODE_SKIP_BEDROCK_AUTH=1")
			if region := str(st.Region); region != "" {
				set("AWS_REGION=" + region)
			}
		case wire.OrgRouteKindVertex:
			set("CLAUDE_CODE_USE_VERTEX=1", "ANTHROPIC_VERTEX_BASE_URL="+pathBase, "CLAUDE_CODE_SKIP_VERTEX_AUTH=1")
			if p := str(st.Project); p != "" {
				set("ANTHROPIC_VERTEX_PROJECT_ID=" + p)
			}
			if l := str(st.Location); l != "" {
				set("CLOUD_ML_REGION=" + l)
			}
		case wire.OrgRouteKindAzure:
			set("CLAUDE_CODE_USE_FOUNDRY=1", "ANTHROPIC_FOUNDRY_BASE_URL="+pathBase, "CLAUDE_CODE_SKIP_FOUNDRY_AUTH=1")
		default:
			set("ANTHROPIC_BASE_URL="+base, "ANTHROPIC_AUTH_TOKEN="+token)
		}
	case "codex":
		folder, err := d.orgAccountFolder(runtimeID, r.ID)
		if err != nil {
			return nil, err
		}
		config := "# Written by the Agents app for an org account. Do not edit: rebuilt on every launch.\n" +
			"model_provider = \"org\"\n\n[model_providers.org]\nname = " + tomlString(r.Name) + "\nbase_url = " +
			tomlString(base+"/v1") + "\nenv_key = " + tomlString(orgStandInVariable) + "\nwire_api = \"responses\"\n"
		if err := writeOrgFile(filepath.Join(folder, "config.toml"), []byte(config)); err != nil {
			return nil, err
		}
		set("CODEX_HOME="+folder, "CODEX_CA_CERTIFICATE="+rl.caFile, orgStandInVariable+"="+token)
	case "opencode":
		folder, err := d.orgAccountFolder(runtimeID, r.ID)
		if err != nil {
			return nil, err
		}
		provider := "openai"
		if r.Vendor != nil && *r.Vendor == wire.OrgRouteVendorAnthropic {
			provider = "anthropic"
		}
		config, _ := json.MarshalIndent(map[string]any{"$schema": "https://opencode.ai/config.json",
			"provider": map[string]any{provider: map[string]any{"options": map[string]any{
				"baseURL": base + "/v1", "apiKey": "{env:" + orgStandInVariable + "}"}}}}, "", "  ")
		if err := writeOrgFile(filepath.Join(folder, "opencode.json"), config); err != nil {
			return nil, err
		}
		set("OPENCODE_CONFIG="+filepath.Join(folder, "opencode.json"), "NODE_EXTRA_CA_CERTS="+rl.caFile, orgStandInVariable+"="+token)
	default:
		return nil, Invalid("%s cannot reach the model through an organisation's route.", runtimeName(runtimeID))
	}
	return env, nil
}

// signInRefusedHere says the policy refuses the runtime's own sign-in, so nothing of the
// person's own way to the model may reach it (D9).
func (d *Daemon) signInRefusedHere(runtimeID string) bool {
	return !reachAllows(d.orgPolicy(), runtimeID, wire.PolicyReachSignIn)
}

// orgFoldersRoot is where each org account's folders are, a folder per runtime.
func (d *Daemon) orgFoldersRoot() string { return filepath.Join(d.Store.Loc.Root, "runtimes", "org") }

// sweepOrgAccountFolders removes each org account's folder whose route this machine no
// longer keeps, with the runtime's state and sessions in it (#3127): when a delivery takes
// a route away, when a session's runtime ends, and at start. A route is kept while its
// file is in org-routes, so the sweep opens no secret. A folder that a session still runs
// in stays until that runtime ends.
func (d *Daemon) sweepOrgAccountFolders() {
	runtimes, err := os.ReadDir(d.orgFoldersRoot())
	if err != nil {
		return
	}
	for _, rt := range runtimes {
		if !rt.IsDir() {
			continue
		}
		routes, err := os.ReadDir(filepath.Join(d.orgFoldersRoot(), rt.Name()))
		if err != nil {
			continue
		}
		for _, route := range routes {
			name := route.Name()
			if _, err := os.Stat(filepath.Join(d.orgRoutesDir(), name+".json")); err == nil {
				continue
			}
			if d.orgRouteInUse(name) {
				continue
			}
			log.Printf("org routes: %s's folder for %s has no route; removed", name, rt.Name())
			os.RemoveAll(filepath.Join(d.orgFoldersRoot(), rt.Name(), name))
		}
	}
}

// orgRouteInUse says a session on a route's account holds its runtime, or a runtime of it
// is still running.
func (d *Daemon) orgRouteInUse(route string) bool {
	for _, a := range d.Store.Agents() {
		if orgRouteOf(a.AccountID) != route {
			continue
		}
		if holdsRuntime(a.State) {
			return true
		}
		d.mu.Lock()
		l := d.lives[a.ID]
		d.mu.Unlock()
		if l == nil {
			continue
		}
		l.mu.Lock()
		running := l.session != nil
		l.mu.Unlock()
		if running {
			return true
		}
	}
	return false
}
