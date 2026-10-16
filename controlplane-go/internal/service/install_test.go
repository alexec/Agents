package service

import (
	"crypto/tls"
	"io"
	"net/http"
	"os"
	"reflect"
	"strings"
	"testing"
)

// The command a host code carries is HostInstallScript.command's, so Add a Server shows
// the same line for either control plane.
func TestTheInstallCommandIsSwifts(t *testing.T) {
	got := installCommand("https://192.168.0.2:8791/", "zBmz-pl4Lxg4SmUZMJo0Hh0_qMWZGIb38noX4uKqX_Q", "agents-control:2:h:-:x")
	want := "curl -fsSL --insecure --pinnedpubkey sha256//zBmz+pl4Lxg4SmUZMJo0Hh0/qMWZGIb38noX4uKqX/Q= https://192.168.0.2:8791/v1/install.sh | sh -s -- 'agents-control:2:h:-:x'"
	if got != want {
		t.Fatalf("\n got %s\nwant %s", got, want)
	}
}

func TestDestinations(t *testing.T) {
	for d, want := range map[string][]string{
		"agents@127.0.0.1:2222": {"-p", "2222", "agents@127.0.0.1"},
		"devbox":                {"devbox"},
		"ssh://a@b:22":          {"-p", "22", "a@b"},
	} {
		if got := sshTarget(d); !reflect.DeepEqual(got, want) {
			t.Errorf("%s: %v", d, got)
		}
	}
	if label("agents@devbox.lan:2222") != "devbox.lan" {
		t.Fatal(label("agents@devbox.lan:2222"))
	}
}

func TestTheScriptAndServersAreServed(t *testing.T) {
	folder := t.TempDir()
	writeFile(t, folder+"/VERSION", "1")
	writeFile(t, folder+"/agentsd-linux-aarch64", "binary")
	t.Setenv("AGENTS_CONTROL_SERVERS", folder)
	w := start(t)
	c := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}}
	get := func(p string) (int, string) {
		r, err := c.Get(w.url + p)
		if err != nil {
			t.Fatal(err)
		}
		b, _ := io.ReadAll(r.Body)
		return r.StatusCode, string(b)
	}
	if code, body := get("/v1/install.sh"); code != 200 || !strings.HasPrefix(body, "#!/bin/sh") {
		t.Fatalf("%d %.40s", code, body)
	}
	if code, body := get("/v1/servers/agentsd-linux-aarch64"); code != 200 || body != "binary" {
		t.Fatalf("%d %s", code, body)
	}
	if code, _ := get("/v1/servers/../control-key"); code != 404 {
		t.Fatalf("a made-up path: %d", code)
	}
}

func writeFile(t *testing.T, path, text string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(text), 0o600); err != nil {
		t.Fatal(err)
	}
}
