package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// fakeTools is a folder of a gcloud that writes each call to log and finds nothing, and a
// curl and a dig that answer as the internet would before DNS is set up.
func fakeTools(t *testing.T, log string) string {
	t.Helper()
	bin := t.TempDir()
	tools := map[string]string{
		"gcloud": `#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FAKE_LOG"
case "$*" in
*"addresses describe"*"value(address)"*) echo 203.0.113.10 ;;
*"instances describe"*"value(disks"*) echo agents-hosted ;;
*"disks describe"*) ;;
*describe*) exit 1 ;;
esac
exit 0
`,
		"curl": "#!/bin/sh\necho 198.51.100.7\n",
		"dig":  "#!/bin/sh\nexit 0\n",
	}
	for name, text := range tools {
		if err := os.WriteFile(filepath.Join(bin, name), []byte(text), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return bin
}

// hostedUp runs deploy/gcp/hosted-up.sh with env and the fake tools first on the PATH.
func hostedUp(t *testing.T, env map[string]string, args ...string) (string, string, error) {
	t.Helper()
	bash, err := exec.LookPath("bash")
	if err != nil {
		t.Skip("no bash")
	}
	log := filepath.Join(t.TempDir(), "gcloud.log")
	cmd := exec.Command(bash, append([]string{"../../../deploy/gcp/hosted-up.sh"}, args...)...)
	cmd.Env = []string{"PATH=" + fakeTools(t, log) + ":/usr/bin:/bin", "HOME=" + t.TempDir(), "FAKE_LOG=" + log}
	for k, v := range env {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	var out, errOut strings.Builder
	cmd.Stdout, cmd.Stderr = &out, &errOut
	err = cmd.Run()
	calls, _ := os.ReadFile(log)
	return out.String() + errOut.String(), string(calls), err
}

// #2226 SC-008: with nothing set, hosted-up.sh names each missing input, and runs no gcloud.
func TestHostedUpSaysWhatIsMissing(t *testing.T) {
	out, calls, err := hostedUp(t, nil)
	if err == nil {
		t.Fatal("it went on with nothing set")
	}
	for _, name := range []string{"AGENTS_GCP_PROJECT", "AGENTS_GCP_ZONE", "AGENTS_GCP_KEY_FILE", "AGENTS_HOSTED_DOMAIN",
		"AGENTS_HOSTED_ACCOUNTS_DOMAIN", "AGENTS_HOSTED_GITHUB_SECRET", "ACME_EMAIL", "nothing was made"} {
		if !strings.Contains(out, name) {
			t.Errorf("does not say %s:\n%s", name, out)
		}
	}
	if calls != "" {
		t.Fatal("gcloud ran:", calls)
	}
	// Billing is all three or none.
	env := ready(t)
	env["AGENTS_HOSTED_STRIPE_KEY"] = "sk_test_x"
	out, calls, err = hostedUp(t, env, "--check")
	if err == nil || !strings.Contains(out, "AGENTS_HOSTED_STRIPE_PRICE") || !strings.Contains(out, "AGENTS_HOSTED_STRIPE_WEBHOOK_SECRET") || calls != "" {
		t.Fatal(out, calls, err)
	}
}

func ready(t *testing.T) map[string]string {
	key := filepath.Join(t.TempDir(), "key.json")
	if err := os.WriteFile(key, []byte(`{"project_id":"p"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	return map[string]string{"AGENTS_GCP_PROJECT": "agents-hosted-test", "AGENTS_GCP_ZONE": "us-west1-b", "AGENTS_GCP_KEY_FILE": key,
		"AGENTS_HOSTED_DOMAIN": "hosted.test", "AGENTS_HOSTED_ACCOUNTS_DOMAIN": "cp.hosted.test",
		"AGENTS_HOSTED_GITHUB_SECRET": "github-secret-value", "ACME_EMAIL": "ops@hosted.test"}
}

// With everything set, it makes the key, the VM and the daily snapshots, then stops until the
// names point at the VM; --check runs nothing.
func TestHostedUpMakesTheVM(t *testing.T) {
	env := ready(t)
	if out, calls, err := hostedUp(t, env, "--check"); err != nil || calls != "" {
		t.Fatal(out, calls, err)
	}
	out, calls, err := hostedUp(t, env)
	if err != nil {
		t.Fatal(out, err)
	}
	for _, want := range []string{
		"auth activate-service-account --key-file " + env["AGENTS_GCP_KEY_FILE"],
		"kms keys create hosted --keyring agents --location global --purpose encryption",
		"iam service-accounts create agents-hosted-vm",
		"--member serviceAccount:agents-hosted-vm@agents-hosted-test.iam.gserviceaccount.com --role roles/cloudkms.cryptoKeyEncrypterDecrypter",
		"compute networks subnets create agents-hosted --network agents-hosted --region us-west1",
		"compute firewall-rules create agents-hosted-ssh --network agents-hosted --direction INGRESS --allow tcp:22 --source-ranges 198.51.100.7/32",
		"compute instances create agents-hosted --zone us-west1-b --machine-type e2-medium",
		"--address 203.0.113.10",
		"compute resource-policies create snapshot-schedule agents-hosted-daily --region us-west1 --daily-schedule --start-time 10:00 --max-retention-days 7",
		"compute disks add-resource-policies agents-hosted --zone us-west1-b --resource-policies agents-hosted-daily",
	} {
		if !strings.Contains(calls, want) {
			t.Errorf("no %q in\n%s", want, calls)
		}
	}
	if strings.Contains(calls, "ssh") && strings.Contains(calls, "compute ssh") {
		t.Fatal("it went on before the names pointed at the VM")
	}
	if !strings.Contains(out, "do not point at 203.0.113.10 yet") {
		t.Fatal(out)
	}
	if strings.Contains(out+calls, "github-secret-value") {
		t.Fatal("a secret was printed or passed to gcloud")
	}
}

// #3124: the image it builds is tagged as compose.hosted.yaml names it, so compose runs that
// one and pulls no release, and once /healthz answers the old images are pruned.
func TestHostedUpRunsTheImageItBuiltAndPrunes(t *testing.T) {
	compose, err := os.ReadFile("../../../deploy/compose.hosted.yaml")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(compose), "image: ghcr.io/alexec/agents-control:${AGENTS_VERSION:-latest}") {
		t.Fatal("compose.hosted.yaml names another image; change the test and hosted-up.sh with it")
	}
	env := ready(t)
	env["AGENTS_VERSION"] = "0.15.0+abc123"
	out, _, err := hostedUp(t, env, "--dry-run")
	if err != nil {
		t.Fatal(out, err)
	}
	image := "ghcr.io/alexec/agents-control:0.15.0-abc123"
	build := strings.Index(out, "docker build --platform linux/amd64 --build-arg VERSION=0.15.0+abc123")
	save := strings.Index(out, "docker save "+image+" ")
	healthz := strings.Index(out, "/healthz")
	prune := strings.Index(out, `docker\ image\ prune\ -af`)
	if build < 0 || !strings.Contains(out, "-t "+image+" ") || save < 0 || healthz < 0 || prune < healthz {
		t.Fatalf("build %d, save %d, healthz %d, prune %d in\n%s", build, save, healthz, prune, out)
	}
	if strings.Contains(out, "agents-control:latest") {
		t.Fatal("it still builds or loads agents-control:latest:\n" + out)
	}
}
