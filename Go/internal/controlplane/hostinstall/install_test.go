package hostinstall

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/controlplane/records"
)

// Ports HostInstallTests: how hosts/install runs ssh, with a key and without one (#413).

const knownHostsPath = "/tmp/agents-install-x/known_hosts"

func TestAGivenKeyIsTheOnlyOneTried(t *testing.T) {
	got := options("/tmp/agents-install-x/key", knownHostsPath)
	want := []string{"-i", "/tmp/agents-install-x/key", "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none"}
	if !reflect.DeepEqual(got[:6], want) {
		t.Fatalf("options start %q", got)
	}
	if !contains(got, "UserKnownHostsFile="+knownHostsPath) {
		t.Fatalf("no known_hosts in %q", got)
	}
	env := environment(false, []string{"SSH_AUTH_SOCK=/tmp/agent", "HOME=/Users/a"})
	if !reflect.DeepEqual(env, []string{"HOME=/Users/a"}) {
		t.Fatalf("environment %q", env)
	}
}

func TestWithoutAKeySSHChoosesAsItWouldForThePerson(t *testing.T) {
	got := options("", knownHostsPath)
	// The host key is still confirmed, and still kept out of the person's known_hosts.
	want := []string{"-o", "UserKnownHostsFile=" + knownHostsPath, "-o", "GlobalKnownHostsFile=/dev/null",
		"-o", "StrictHostKeyChecking=yes", "-o", "LogLevel=error"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("options %q", got)
	}
	env := environment(true, []string{"SSH_AUTH_SOCK=/tmp/agent", "AGENTS_ROOT=/r", "CLAUDE_X=1", "DISPLAY=:0"})
	if !reflect.DeepEqual(env, []string{"SSH_AUTH_SOCK=/tmp/agent"}) {
		t.Fatalf("environment %q", env)
	}
}

// #964: gh's codespace entry says LogLevel quiet, which hid "Host key verification
// failed"; ssh takes the command line's over the config's. Needs a real ssh.
func TestSSHsErrorsAreSaidOverAQuietConfig(t *testing.T) {
	if _, err := exec.LookPath(DefaultSSH); err != nil {
		t.Skip("no ssh here")
	}
	config := filepath.Join(t.TempDir(), "config")
	os.WriteFile(config, []byte("Host cs.*\n  LogLevel quiet\n  StrictHostKeyChecking no\n  UserKnownHostsFile /dev/null\n"), 0o600)
	ssh := sshCommand{executable: DefaultSSH, name: "cs.w857.main", env: os.Environ()}
	out, err := ssh.run(context.Background(), join([]string{"-F", config}, options("", ""), ssh.resolveArguments()), "")
	if err != nil || out.status != 0 {
		t.Fatalf("%v %q", err, out.stderr)
	}
	got := lines(out.stdout)
	if !contains(got, "loglevel ERROR") || !contains(got, "stricthostkeychecking true") {
		t.Fatalf("resolved %q", out.stdout)
	}
}

func TestARefusalSaysWhichKeysWereTried(t *testing.T) {
	if got := Say(problem(LoginRefused), true); got != "The server refused that key." {
		t.Fatal(got)
	}
	if got := Say(problem(LoginRefused), false); !strings.Contains(got, "every key ssh offered") {
		t.Fatal(got)
	}
	if got := Say(problem(KeyLocked), false); !strings.Contains(got, "ssh-add") {
		t.Fatal(got)
	}
	if got := Say(problem(KeyLocked), true); !strings.Contains(got, "has a passphrase") {
		t.Fatal(got)
	}
}

// #514: a generated config's UserKnownHostsFile /dev/null is replaced by ssh's own
// files, so StrictHostKeyChecking=yes checks the person's known_hosts; real files stay.
func TestAKnownHostsOfDevNullIsTheDefaultFilesInstead(t *testing.T) {
	devNull := "hostname 10.0.0.5\nuserknownhostsfile /dev/null\nstricthostkeychecking false\n"
	want := []string{"-o", "UserKnownHostsFile=~/.ssh/known_hosts ~/.ssh/known_hosts2"}
	if got := knownHostsOverride(devNull); !reflect.DeepEqual(got, want) {
		t.Fatalf("%q", got)
	}
	if got := knownHostsOverride("userknownhostsfile /Users/a/.ssh/known_hosts /Users/a/.ssh/known_hosts2\n"); got != nil {
		t.Fatalf("%q", got)
	}
	if got := knownHostsOverride("hostname devbox\n"); got != nil {
		t.Fatalf("%q", got)
	}
}

func TestAFailureIsASentence(t *testing.T) {
	if got := Say(problem(HostKeyChanged), false); !strings.Contains(got, "known_hosts") {
		t.Fatal(got)
	}
	if got := Say(installFailed(""), false); got != "ssh failed without saying why." {
		t.Fatal(got)
	}
	if got := Say(installFailed("kex_exchange_identification: closed"), false); got != "kex_exchange_identification: closed" {
		t.Fatal(got)
	}
	if got := Say(timedOut("connect"), false); strings.Contains(got, "timedOut") {
		t.Fatal(got)
	}
	if got := Say(&Problem{Kind: DiskFull}, false); got != "diskFull(freeBytes: 0)" {
		t.Fatal(got)
	}
}

func TestARequestNeedNotCarryAKey(t *testing.T) {
	var r Request
	if err := json.Unmarshal([]byte(`{"destination":"agents@devbox.lan"}`), &r); err != nil {
		t.Fatal(err)
	}
	if r.Destination != "agents@devbox.lan" || r.Key != nil {
		t.Fatalf("%+v", r)
	}
}

// #610: whether to tunnel is the sheet's to say; left out, a bastion decides.
func TestARequestMaySayWhetherToTunnel(t *testing.T) {
	var asked, left Request
	json.Unmarshal([]byte(`{"destination":"ws","tunnel":true}`), &asked)
	json.Unmarshal([]byte(`{"destination":"ws"}`), &left)
	if asked.Tunnel == nil || !*asked.Tunnel || left.Tunnel != nil {
		t.Fatalf("%+v %+v", asked, left)
	}
}

func TestAnUnknownKeyIsNotAChangedOne(t *testing.T) {
	if got := Say(problem(HostKeyUnknown), false); !strings.Contains(got, "isn’t in your known_hosts") {
		t.Fatal(got)
	}
	if got := Say(problem(HostKeyChanged), false); !strings.Contains(got, "has changed") {
		t.Fatal(got)
	}
}

// SSHCommand.classify, on ssh's own words (contracts/ssh.md § Errors).
func TestSSHsWordsAreClassified(t *testing.T) {
	for name, want := range map[string]ProblemKind{
		"unknownHost": UnknownHost, "timedOut": TimedOut, "refused": TimedOut, "loginRefused": LoginRefused,
		"hostKeyUnknown": HostKeyUnknown, "hostKeyChanged": HostKeyChanged,
		"noStreamLocalForwarding": NoStreamLocalForwarding, "diskFull": DiskFull,
	} {
		if got := classify(255, stderrFixtures[name], true); got == nil || got.Kind != want {
			t.Errorf("%s: %v", name, got)
		}
	}
	if got := classify(255, stderrFixtures["loginRefused"], false); got.Kind != KeyLocked {
		t.Errorf("no keys in the agent: %v", got)
	}
	if got := classify(0, "Permission denied", true); got != nil {
		t.Errorf("success: %v", got)
	}
	if got := classify(1, "a\nb\nc\nd\n", true); got.Kind != InstallFailed || got.Words != "b\nc\nd" {
		t.Errorf("the last three lines: %q", got.Words)
	}
}

func TestADestinationWithAPortIsWrittenForSSH(t *testing.T) {
	for typed, want := range map[string]string{
		"agents@devbox.lan:2222": "ssh://agents@devbox.lan:2222",
		"devbox":                 "devbox",
		"ssh://a@b:22":           "ssh://a@b:22",
		"fe80::1":                "fe80::1",
		"devbox:http":            "devbox:http",
	} {
		if got := (sshCommand{name: typed}).destination(); got != want {
			t.Errorf("%s: %s", typed, got)
		}
	}
	for destination, want := range map[string]string{
		"agents@devbox.lan:2222": "devbox.lan", "ssh://a@b:22": "b", "devbox": "devbox",
	} {
		if got := label(destination); got != want {
			t.Errorf("label %s: %s", destination, got)
		}
	}
}

func TestTheFingerprintIsSSHKeygens(t *testing.T) {
	got, ok := knownHostsFingerprint("# a comment\ndevbox " + hostKey + "\n")
	if !ok || got != hostKeyFingerprint {
		t.Fatalf("%s", got)
	}
	if _, ok := knownHostsFingerprint("\n"); ok {
		t.Fatal("a fingerprint of nothing")
	}
}

func TestATunnelRecordIsStoredAsSwiftStoresIt(t *testing.T) {
	made := records.At(time.Date(2026, 10, 16, 12, 0, 0, 0, time.UTC))
	data, err := json.Marshal(TunnelRecord{ID: "a", Destination: "ws", Name: "ws", Port: 8443, Code: "c", Made: made})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"id":"a","destination":"ws","name":"ws","port":8443,"code":"c","knownHosts":"","made":"2026-10-16T12:00:00.000Z"}`
	if string(data) != want {
		t.Fatalf("%s", data)
	}
}

// The whole of hosts/install, on the fake ssh.

func reply(t *testing.T) func(any, error) map[string]any {
	return func(got any, err error) map[string]any {
		t.Helper()
		if err != nil {
			t.Fatal(err)
		}
		return got.(map[string]any)
	}
}

func failure(t *testing.T, err error) *Failure {
	t.Helper()
	var f *Failure
	if !errors.As(err, &f) {
		t.Fatalf("not a Failure: %v", err)
	}
	return f
}

func TestSayWhichServer(t *testing.T) {
	f := newFake(t)
	var steps []string
	i := f.installer(&fakeCodes{}, &steps)
	for _, params := range []string{``, `null`, `{}`, `{"destination":"  "}`, `{"destination":3}`} {
		_, err := i.Install(context.Background(), json.RawMessage(params))
		if got := failure(t, err); got.Code != InvalidParams || got.Message != "Say which server." {
			t.Errorf("%s: %v", params, got)
		}
	}
}

func TestAKeyNotInKnownHostsIsShownFirst(t *testing.T) {
	f := newFake(t)
	var steps []string
	codes := &fakeCodes{}
	got := reply(t)(f.installer(codes, &steps).Install(context.Background(),
		json.RawMessage(`{"destination":"agents@devbox.lan:2222"}`)))
	if got["needsTrust"] != hostKeyFingerprint || got["name"] != "devbox.lan" || len(got) != 2 {
		t.Fatalf("%v", got)
	}
	if _, err := os.Stat(f.server("")); !os.IsNotExist(err) {
		t.Fatal("something was installed")
	}
	if len(codes.urls) != 0 {
		t.Fatal("a code was issued")
	}
	if !strings.Contains(f.logged(), "-- ssh://agents@devbox.lan:2222") {
		t.Fatalf("the port was not written for ssh: %s", f.logged())
	}
	if left := f.leftInstallFolders(); len(left) != 0 {
		t.Fatalf("left %v", left)
	}
}

func TestATrustedKeyInstallsAndStartsTheHost(t *testing.T) {
	f := newFake(t)
	var steps []string
	codes := &fakeCodes{}
	got := reply(t)(f.installer(codes, &steps).Install(context.Background(),
		json.RawMessage(`{"destination":"agents@devbox.lan","name":"Dev box","trust":"`+hostKeyFingerprint+`"}`)))
	want := map[string]any{"started": true, "name": "Dev box", "platform": "Linux ARM64", "tunnel": false}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("%v", got)
	}
	wantSteps := []string{"Dev box:connect", "Dev box:checkSystem", "Dev box:setUp", "Dev box:started"}
	if !reflect.DeepEqual(steps, wantSteps) {
		t.Fatalf("steps %v", steps)
	}
	if !reflect.DeepEqual(codes.urls, []string{""}) {
		t.Fatalf("codes %q", codes.urls)
	}
	current, err := os.Readlink(f.server("bin/current"))
	if err != nil || current != binaryName(f.sha) {
		t.Fatalf("current %s %v", current, err)
	}
	installed, _ := os.ReadFile(f.server("bin/" + binaryName(f.sha)))
	shipped, _ := os.ReadFile(filepath.Join(f.servers, "agentsd-linux-aarch64"))
	if string(installed) != string(shipped) {
		t.Fatal("the copy is not the same bytes")
	}
	info, _ := os.Stat(f.server(""))
	if info == nil || info.Mode().Perm() != 0o700 {
		t.Fatalf("~/.agents-server is %v", info)
	}
	if _, err := os.Stat(f.server("bin/ci-watcher")); err != nil {
		t.Fatal("ci-watcher was not copied")
	}
	var record installRecord
	data, _ := os.ReadFile(f.server("install.json"))
	if json.Unmarshal(data, &record) != nil || record.Version != "1.2.3" || record.SHA256 != f.sha || record.InstalledBy != "control plane" {
		t.Fatalf("install.json %s", data)
	}
	code, _ := os.ReadFile(f.server("root/control-join-code"))
	if string(code) != "agents-control:2:h:-:key:secret::-:test" {
		t.Fatalf("code %q", code)
	}
	args, _ := os.ReadFile(filepath.Join(f.home, "started-args"))
	if string(args) != "--root\n"+f.server("root")+"\n--serve\n--detach\n--control-network\n--host-name\nDev box\n" {
		t.Fatalf("started with %q", args)
	}
	// No key given: ssh offers the person's own, from their agent.
	log := f.logged()
	if strings.Contains(log, " -i /") || !strings.Contains(log, "agent=/tmp/agent.sock") {
		t.Fatalf("log %s", log)
	}
	if left := f.leftInstallFolders(); len(left) != 0 {
		t.Fatalf("left %v", left)
	}
}

func TestAnotherKeyIsShownAgain(t *testing.T) {
	f := newFake(t)
	var steps []string
	got := reply(t)(f.installer(&fakeCodes{}, &steps).Install(context.Background(),
		json.RawMessage(`{"destination":"devbox","trust":"SHA256:not-that-one"}`)))
	if got["needsTrust"] != hostKeyFingerprint {
		t.Fatalf("%v", got)
	}
	if _, err := os.Stat(f.server("")); !os.IsNotExist(err) {
		t.Fatal("something was installed")
	}
}

func TestAKeyThePersonKnowsIsNotAsked(t *testing.T) {
	f := newFake(t)
	f.env["FAKE_SSH_PERSON_KNOWS"] = "1"
	var steps []string
	got := reply(t)(f.installer(&fakeCodes{}, &steps).Install(context.Background(), json.RawMessage(`{"destination":"devbox"}`)))
	if got["started"] != true || got["name"] != "devbox" {
		t.Fatalf("%v", got)
	}
}

func TestAGivenKeyIsHeldForTheCallOnly(t *testing.T) {
	f := newFake(t)
	f.env["FAKE_SSH_PERSON_KNOWS"] = "1"
	var steps []string
	got := reply(t)(f.installer(&fakeCodes{}, &steps).Install(context.Background(),
		json.RawMessage(`{"destination":"devbox","key":"-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"}`)))
	if got["started"] != true {
		t.Fatalf("%v", got)
	}
	log := f.logged()
	if !strings.Contains(log, " -i /") || !strings.Contains(log, "IdentitiesOnly=yes") || strings.Contains(log, "agent=/tmp") {
		t.Fatalf("log %s", log)
	}
	if left := f.leftInstallFolders(); len(left) != 0 {
		t.Fatalf("the key was left in %v", left)
	}
}

func TestEachFailureIsSaid(t *testing.T) {
	for name, want := range map[string]string{
		"unknownHost":    "ssh doesn’t know that server.",
		"timedOut":       "It did not answer: the connection timed out or was refused.",
		"loginRefused":   "The server refused every key ssh offered. If yours has a passphrase, add it to the agent (ssh-add), or choose a key.",
		"hostKeyChanged": "The server’s host key has changed since your known_hosts last saw it, so nothing was installed. If the server was rebuilt, remove its old key (ssh-keygen -R) and try again.",
	} {
		f := newFake(t)
		f.env["FAKE_SSH_FAIL"] = name
		var steps []string
		_, err := f.installer(&fakeCodes{}, &steps).Install(context.Background(), json.RawMessage(`{"destination":"devbox"}`))
		if got := failure(t, err); got.Code != NotAllowed || got.Message != want {
			t.Errorf("%s: %v", name, got)
		}
	}
}

// As in Swift, only the machine is checked, not the system: a Mac on arm64 is not
// refused here.
func TestAMachineWithNoHostBuiltIsRefused(t *testing.T) {
	f := newFake(t)
	f.env["FAKE_SSH_PERSON_KNOWS"] = "1"
	f.env["FAKE_SSH_UNAME"] = "Linux riscv64"
	var steps []string
	_, err := f.installer(&fakeCodes{}, &steps).Install(context.Background(), json.RawMessage(`{"destination":"rv.lan"}`))
	if got := failure(t, err); got.Code != NotAllowed || got.Message != "rv.lan is Linux riscv64, which this control plane has no host for." {
		t.Fatalf("%v", got)
	}
	if _, err := os.Stat(f.server("")); !os.IsNotExist(err) {
		t.Fatal("something was installed")
	}
}

func TestATunnelNeedsACopyThatHoldsThem(t *testing.T) {
	f := newFake(t)
	f.env["FAKE_SSH_PERSON_KNOWS"] = "1"
	var steps []string
	_, err := f.installer(&fakeCodes{}, &steps).Install(context.Background(), json.RawMessage(`{"destination":"ws","tunnel":true}`))
	if got := failure(t, err); got.Message != "This control plane can’t hold an ssh tunnel: only one on your Mac can. Add the server without one." {
		t.Fatalf("%v", got)
	}
}

// #435: a server behind a bastion dials its own end of a reverse tunnel.
func TestAServerBehindABastionIsTunnelled(t *testing.T) {
	f := newFake(t)
	f.env["FAKE_SSH_PROXYJUMP"] = "bastion"
	var steps []string
	codes := &fakeCodes{}
	tunnels := &fakeTunnels{}
	i := f.installer(codes, &steps)
	i.Tunnels = tunnels
	got := reply(t)(i.Install(context.Background(), json.RawMessage(`{"destination":"gpu","trust":"`+hostKeyFingerprint+`"}`)))
	if got["tunnel"] != true {
		t.Fatalf("%v", got)
	}
	if !reflect.DeepEqual(codes.urls, []string{"https://127.0.0.1:8443"}) {
		t.Fatalf("codes %q", codes.urls)
	}
	if len(tunnels.added) != 1 {
		t.Fatalf("tunnels %v", tunnels.added)
	}
	r := tunnels.added[0]
	if r.Destination != "gpu" || r.Name != "gpu" || r.Port != 8443 || r.Code != "code-id" || r.Host != nil ||
		!strings.Contains(r.KnownHosts, hostKey) || len(r.ID) != 36 || r.ID != strings.ToLower(r.ID) {
		t.Fatalf("record %+v", r)
	}
	// Asked not to, it dials the control plane's own address.
	f.env["FAKE_SSH_PERSON_KNOWS"] = "1"
	codes.urls = nil
	i = f.installer(codes, &steps)
	i.Tunnels = tunnels
	got = reply(t)(i.Install(context.Background(), json.RawMessage(`{"destination":"gpu","tunnel":false}`)))
	if got["tunnel"] != false || !reflect.DeepEqual(codes.urls, []string{""}) {
		t.Fatalf("%v %q", got, codes.urls)
	}
}

func TestUpdateIsNotHereAndCheckAgainDoesNothing(t *testing.T) {
	i := &Installer{}
	if err := i.Update(context.Background(), "h"); err != NotHere {
		t.Fatal(err)
	}
	if err := i.CheckAgain(context.Background(), "h"); err != nil {
		t.Fatal(err)
	}
}
