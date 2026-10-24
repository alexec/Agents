package skillcatalog

import (
	"encoding/json"
	"math/rand"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"
)

// Ports SkillHashesTests and SkillLocksTests: the hashes against values made by git and by
// the `skills` CLI under node, and the lock files written as the CLI writes them. The
// fixtures are AgentsKit's own.

const fixtures = "../../../../Packages/AgentsKit/Tests/AgentsKitTests/Fixtures/catalog"

type golden struct {
	Fixtures map[string]struct {
		ComputedHash string   `json:"computedHash"`
		LocaleOrder  []string `json:"localeOrder"`
		TreeSHA      string   `json:"treeSHA"`
		Blobs        map[string]struct {
			Mode string `json:"mode"`
			SHA  string `json:"sha"`
		} `json:"blobs"`
	} `json:"fixtures"`
}

func TestTheHashesAreGitsAndTheCLIs(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(fixtures, "golden.json"))
	if err != nil {
		t.Fatal(err)
	}
	var g golden
	json.Unmarshal(b, &g)
	for _, name := range []string{"plain", "mixed", "nested"} {
		want := g.Fixtures[name]
		folder := filepath.Join(fixtures, "skills", name)
		if got, err := ComputedHash(folder); err != nil || got != want.ComputedHash {
			t.Errorf("%s computedHash %s %v", name, got, err)
		}
		if got, err := TreeSHA(folder); err != nil || got != want.TreeSHA {
			t.Errorf("%s treeSHA %s %v", name, got, err)
		}
		for path, blob := range want.Blobs {
			data, _ := os.ReadFile(filepath.Join(folder, path))
			if BlobSHA(data) != blob.SHA {
				t.Errorf("%s/%s blob", name, path)
			}
		}
		order := append([]string(nil), want.LocaleOrder...)
		rand.Shuffle(len(order), func(i, j int) { order[i], order[j] = order[j], order[i] })
		sort.Slice(order, func(i, j int) bool { return LocaleLess(order[i], order[j]) })
		if strings.Join(order, ",") != strings.Join(want.LocaleOrder, ",") {
			t.Errorf("%s locale order %v", name, order)
		}
	}
}

var lockNow = time.Date(2026, 9, 26, 15, 10, 0, 0, time.UTC)

func copyLock(t *testing.T, name, to string) {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(fixtures, "locks", name))
	if err != nil {
		t.Fatal(err)
	}
	os.MkdirAll(filepath.Dir(to), 0o755)
	os.WriteFile(to, b, 0o644)
}

func TestThePersonalLockComesOutAsTheCLIWritesIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".agents", ".skill-lock.json")
	copyLock(t, "personal-before.json", path)
	lock, err := LoadLock(Personal, path)
	if err != nil {
		t.Fatal(err)
	}
	lock.Upsert("nested", "fixture-owner/fixture-skills", "skills/nested/SKILL.md", "b4146b99df32f406302cf36ff69949f3b394ea01", lockNow)
	lock.Upsert("find-skills", "vercel-labs/skills", "skills/find-skills/SKILL.md", "1111111111111111111111111111111111111111", lockNow)
	if err := lock.Write(); err != nil {
		t.Fatal(err)
	}
	want, _ := os.ReadFile(filepath.Join(fixtures, "locks", "personal-after.json"))
	got, _ := os.ReadFile(path)
	if string(got) != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
	if e, _ := lock.Entry("find-skills"); e.InstalledAt != "2026-09-17T14:59:25.092Z" || e.UpdatedAt != "2026-09-26T15:10:00.000Z" {
		t.Fatalf("%+v", e)
	}
}

func TestTheFolderLockComesOutAsTheCLIWritesIt(t *testing.T) {
	path := filepath.Join(t.TempDir(), "skills-lock.json")
	copyLock(t, "folder-before.json", path)
	lock, err := LoadLock(FolderScope, path)
	if err != nil {
		t.Fatal(err)
	}
	lock.Upsert("nested", "fixture-owner/fixture-skills", "skills/nested/SKILL.md", "43d79cc2b2a7065d4f3f4cc5ae35447d31c5b22469dcee4c35395c2c09d0ac0e", lockNow)
	lock.Write()
	want, _ := os.ReadFile(filepath.Join(fixtures, "locks", "folder-after.json"))
	if got, _ := os.ReadFile(path); string(got) != string(want) {
		t.Fatalf("got\n%s\nwant\n%s", got, want)
	}
}

func TestANewPersonalLockStartsAsTheCLIsEmptyOne(t *testing.T) {
	path := filepath.Join(t.TempDir(), ".agents", ".skill-lock.json")
	lock, _ := LoadLock(Personal, path)
	lock.Upsert("plain", "o/r", "skills/plain/SKILL.md", "aa", lockNow)
	lock.Write()
	b, _ := os.ReadFile(path)
	if !strings.HasPrefix(string(b), "{\n  \"version\": 3,\n  \"skills\": {\n    \"plain\": {") || !strings.HasSuffix(string(b), "\n  },\n  \"dismissed\": {}\n}") {
		t.Fatal(string(b))
	}
}

func TestAnUnreadableLockIsRefusedAndLeftAlone(t *testing.T) {
	for _, text := range []string{`{"version": 2, "skills": {}}`, `{not json`, `{"version": 3}`} {
		path := filepath.Join(t.TempDir(), ".skill-lock.json")
		os.WriteFile(path, []byte(text), 0o644)
		_, err := LoadLock(Personal, path)
		ce, ok := err.(*Error)
		if !ok || ce.Why.LockUnreadable == nil {
			t.Fatalf("%q: %v", text, err)
		}
		if b, _ := os.ReadFile(path); string(b) != text {
			t.Fatal(string(b))
		}
	}
}

func TestASkillFileSaysItsNameAndDescription(t *testing.T) {
	f := ParseSkillFile("---\nname: \"Find skills\"\ndescription: >-\n  Finds\n  skills.\nother: x\n---\n# Body")
	if f.Name != "Find skills" || f.Description != "Finds skills." {
		t.Fatalf("%+v", f)
	}
	if f := ParseSkillFile("no front matter"); f != (SkillFile{}) {
		t.Fatalf("%+v", f)
	}
	if FolderName("My Skill!") != "my-skill" || FolderName("..") != "unnamed-skill" || Slug("Swift_UI expert") != "swift-ui-expert" {
		t.Fatal(FolderName("My Skill!"), FolderName(".."), Slug("Swift_UI expert"))
	}
}
