package agentsd

import (
	"bytes"
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
