package agentsd

import (
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/pem"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

var starterValues = map[string]map[string]string{
	"iphone-app": {"APP_NAME": "Tide Log", "BUNDLE_ID": "com.example.tidelog"},
	"web-service": {
		"APP_NAME": "Tide Log", "SERVICE": "tidelog", "GCP_PROJECT": "tidelog-1234",
		"GCP_REGION": "us-central1", "GITHUB_REPO": "someone/tidelog",
	},
}

func TestStarterIDs(t *testing.T) {
	if got, want := starterIDs(), []string{"iphone-app", "web-service"}; !reflect.DeepEqual(got, want) {
		t.Fatalf("starterIDs() = %v, want %v", got, want)
	}
}

func TestStarterPlaceholders(t *testing.T) {
	for id, values := range starterValues {
		got, err := starterPlaceholders(id)
		if err != nil {
			t.Fatal(err)
		}
		var want []string
		for k := range values {
			want = append(want, k)
		}
		if !sameSet(got, want) {
			t.Errorf("%s placeholders = %v, want %v", id, got, want)
		}
	}
}

func sameSet(a, b []string) bool {
	m := map[string]int{}
	for _, s := range a {
		m[s]++
	}
	for _, s := range b {
		m[s]--
	}
	for _, n := range m {
		if n != 0 {
			return false
		}
	}
	return len(a) == len(b)
}

func TestStarterFilesFillsEveryPlaceholder(t *testing.T) {
	for id, values := range starterValues {
		files, err := starterFiles(id, values)
		if err != nil {
			t.Fatal(err)
		}
		for p, b := range files {
			if m := starterPlaceholder.Find(b); m != nil && starterText(b) {
				t.Errorf("%s/%s still says %s", id, p, m)
			}
		}
	}
}

func TestStarterFilesNeedsEveryValue(t *testing.T) {
	_, err := starterFiles("iphone-app", map[string]string{"APP_NAME": "Tide Log"})
	if err == nil || !strings.Contains(err.Error(), "BUNDLE_ID") {
		t.Fatalf("err = %v, want one that names BUNDLE_ID", err)
	}
	if _, err := starterFiles("android-app", nil); err == nil {
		t.Fatal("an unknown starter gave no error")
	}
}

// The workflows say what they deployed with the notice that Lineage reads (#3584).
func TestStartersSayTheirDeploys(t *testing.T) {
	want := map[string][]string{
		"iphone-app": {
			".github/workflows/release.yml:::notice title=deploy::testflight:$BUNDLE_ID/${{ github.run_number }}",
			".github/workflows/release.yml:BUNDLE_ID: com.example.tidelog",
			".github/workflows/app-store.yml:::notice title=deploy::appstore:$BUNDLE_ID/${TAG#v}",
			".github/workflows/app-store.yml:environment: app-store",
			".github/workflows/release.yml:environment: testflight",
			".github/workflows/release.yml:-allowProvisioningUpdates",
			".github/workflows/setup.yml:swift scripts/asc.swift register",
			"project.yml:SentryDSN: $(SENTRY_DSN)",
			"App/StarterApp.swift:options.releaseName",
			".github/workflows/release.yml:SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}",
			".github/workflows/release.yml:SENTRY_PROJECT: ${{ vars.SENTRY_PROJECT }}",
			".github/workflows/release.yml:debug-files upload --project \"$SENTRY_PROJECT\" \"$RUNNER_TEMP/App.xcarchive/dSYMs\"",
		},
		"web-service": {
			".github/workflows/deploy.yml:::notice title=deploy::cloudrun:$PROJECT/$REGION/$SERVICE/$SERVICE-${{ github.run_number }}",
			".github/workflows/deploy.yml:environment: production",
			".github/workflows/deploy.yml:SENTRY_RELEASE=$SERVICE@${TAG#v}",
			"setup-gcp.sh:assertion.repository == '$repo'",
			"setup-gcp.sh:echo \"GCP_WIF_PROVIDER=",
			"setup-gcp.sh:echo \"GCP_DEPLOY_SA=",
			"instrument.mjs:dsn: process.env.SENTRY_DSN",
		},
	}
	for id, lines := range want {
		files, err := starterFiles(id, starterValues[id])
		if err != nil {
			t.Fatal(err)
		}
		for _, l := range lines {
			p, text, _ := strings.Cut(l, ":")
			if !bytes.Contains(files[p], []byte(text)) {
				t.Errorf("%s/%s does not say %q", id, p, text)
			}
		}
	}
}

// setup-gcp.sh names the pool, the provider and the account the same every time, so an agent
// that reads only the project's number builds the two variables (#3710,
// specs/3656-new-app/google-cloud.md, step 5).
func TestSetupGCPNamesAreFixed(t *testing.T) {
	files, err := starterFiles("web-service", starterValues["web-service"])
	if err != nil {
		t.Fatal(err)
	}
	script := string(files["setup-gcp.sh"])
	for _, l := range []string{"pool=github\n", "provider=github\n", "account=deploy\n", "repo=someone/tidelog\n",
		"project=${1:-tidelog-1234}\n",
		`echo "GCP_WIF_PROVIDER=projects/$number/locations/global/workloadIdentityPools/$pool/providers/$provider"`,
		`sa="$account@$project.iam.gserviceaccount.com"`, `echo "GCP_DEPLOY_SA=$sa"`} {
		if !strings.Contains(script, l) {
			t.Errorf("setup-gcp.sh does not say %q", l)
		}
	}
	// The two names are the script's last output, which the agent reads from the page.
	lines := strings.Split(strings.TrimSpace(script), "\n")
	if !strings.HasPrefix(lines[len(lines)-1], `echo "GCP_DEPLOY_SA=`) || !strings.HasPrefix(lines[len(lines)-2], `echo "GCP_WIF_PROVIDER=`) {
		t.Errorf("setup-gcp.sh does not end with the two names: %q", lines[len(lines)-2:])
	}
}

// The iPhone app's icon is an image, so it is not filled, and it is there: App Store Connect
// refuses a build with no icon.
func TestStarterKeepsTheIcon(t *testing.T) {
	files, err := starterFiles("iphone-app", starterValues["iphone-app"])
	if err != nil {
		t.Fatal(err)
	}
	icon := files["App/Assets.xcassets/AppIcon.appiconset/AppIcon.png"]
	if !bytes.HasPrefix(icon, []byte("\x89PNG\r\n\x1a\n")) {
		t.Fatal("no AppIcon.png")
	}
}

// A key pasted in ask_secret's one-line field loses its line breaks (#3709,
// specs/3656-new-app/apple.md, step 5): every workflow writes the .p8 file with asc-key.sh,
// which puts them back, so the file is the one Apple gave.
func TestStarterRebuildsThePastedKey(t *testing.T) {
	files, err := starterFiles("iphone-app", starterValues["iphone-app"])
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{"setup.yml", "release.yml", "app-store.yml"} {
		y := string(files[".github/workflows/"+w])
		if !strings.Contains(y, `bash scripts/asc-key.sh "$RUNNER_TEMP/asc.p8"`) || strings.Contains(y, `echo "$ASC_KEY_P8"`) {
			t.Errorf("%s does not write the key with scripts/asc-key.sh", w)
		}
	}
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	p8 := string(pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
	dir := t.TempDir()
	script := filepath.Join(dir, "asc-key.sh")
	if err := os.WriteFile(script, files["scripts/asc-key.sh"], 0o755); err != nil {
		t.Fatal(err)
	}
	for name, pasted := range map[string]string{"as downloaded": p8, "no line breaks": strings.ReplaceAll(p8, "\n", ""),
		"spaces": strings.ReplaceAll(p8, "\n", " ")} {
		out := filepath.Join(dir, "asc.p8")
		cmd := exec.Command("bash", script, out)
		cmd.Env = append(os.Environ(), "ASC_KEY_P8="+pasted)
		if b, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s: %v: %s", name, err, b)
		}
		if got, _ := os.ReadFile(out); string(got) != p8 {
			t.Errorf("%s: wrote\n%s\nwant\n%s", name, got, p8)
		}
	}
	cmd := exec.Command("bash", script, filepath.Join(dir, "bad.p8"))
	cmd.Env = append(os.Environ(), "ASC_KEY_P8=not a key!")
	if err := cmd.Run(); err == nil {
		t.Error("asc-key.sh took text that is not a key")
	}
}
