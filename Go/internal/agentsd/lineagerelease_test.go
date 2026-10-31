package agentsd

import (
	"context"
	"sync"
	"testing"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

func TestVersionTagsOf(t *testing.T) {
	out := "abc123\trefs/tags/v0.13.0\n" +
		"def456\trefs/tags/v0.14.0\n" +
		"aaa000\trefs/tags/v0.14.0^{}\n" + // the annotated tag's peeled commit: the same tag.
		"zzz999\trefs/tags/not-a-version\n" +
		"\n"
	got := versionTagsOf(out)
	want := []string{"v0.13.0", "v0.14.0"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestSortVersionTags(t *testing.T) {
	tags := []string{"v0.14.1", "v0.9.0", "v0.14.0", "v0.2.3"}
	sortVersionTags(tags)
	want := []string{"v0.2.3", "v0.9.0", "v0.14.0", "v0.14.1"}
	for i, w := range want {
		if tags[i] != w {
			t.Fatalf("got %v, want %v", tags, want)
		}
	}
}

func TestMilestoneVersionOf(t *testing.T) {
	for tag, want := range map[string]string{
		"v0.14.0": "0.14",
		"v0.14.1": "0.14.1",
		"v1.0.0":  "1.0",
	} {
		if got := milestoneVersionOf(tag); got != want {
			t.Errorf("%s: got %q, want %q", tag, got, want)
		}
	}
}

func TestSquashPRNumber(t *testing.T) {
	if n, ok := squashPRNumber("github", "Lineage: release nodes (#3023)\n\nbody"); !ok || n != 3023 {
		t.Fatalf("github: got %d, %v", n, ok)
	}
	if n, ok := squashPRNumber("gitlab", "Lineage: release nodes (!42)"); !ok || n != 42 {
		t.Fatalf("gitlab: got %d, %v", n, ok)
	}
	if _, ok := squashPRNumber("github", "A merge commit with no number"); ok {
		t.Fatal("want no number")
	}
	if _, ok := squashPRNumber("gitlab", "Lineage: release nodes (#3023)"); ok {
		t.Fatal("github's mark is not gitlab's")
	}
}

func TestCommitTimeOf(t *testing.T) {
	gh, err := commitTimeOf("github", []byte(`{"commit":{"committer":{"date":"2026-10-29T10:00:00Z"}}}`))
	if err != nil || !gh.Equal(time.Date(2026, 10, 29, 10, 0, 0, 0, time.UTC)) {
		t.Fatalf("github: %v, %v", gh, err)
	}
	gl, err := commitTimeOf("gitlab", []byte(`{"committed_date":"2026-10-29T11:00:00Z"}`))
	if err != nil || !gl.Equal(time.Date(2026, 10, 29, 11, 0, 0, 0, time.UTC)) {
		t.Fatalf("gitlab: %v, %v", gl, err)
	}
	if _, err := commitTimeOf("github", []byte(`{}`)); err == nil {
		t.Fatal("no date: want an error")
	}
}

func TestCompareCommitsOf(t *testing.T) {
	gh, err := compareCommitsOf("github", []byte(`{"commits":[{"sha":"a1","commit":{"message":"x (#1)"}}]}`))
	if err != nil || len(gh) != 1 || gh[0].SHA != "a1" || gh[0].Message != "x (#1)" {
		t.Fatalf("github: %+v, %v", gh, err)
	}
	gl, err := compareCommitsOf("gitlab", []byte(`{"commits":[{"id":"b2","message":"y (!2)"}]}`))
	if err != nil || len(gl) != 1 || gl[0].SHA != "b2" || gl[0].Message != "y (!2)" {
		t.Fatalf("gitlab: %+v, %v", gl, err)
	}
}

func TestCommitPRNumberOf(t *testing.T) {
	if n, err := commitPRNumberOf("github", []byte(`[{"number":9}]`)); err != nil || n != 9 {
		t.Fatalf("github: %d, %v", n, err)
	}
	if n, err := commitPRNumberOf("github", []byte(`[]`)); err != nil || n != 0 {
		t.Fatalf("github none: %d, %v", n, err)
	}
	if n, err := commitPRNumberOf("gitlab", []byte(`[{"iid":11}]`)); err != nil || n != 11 {
		t.Fatalf("gitlab: %d, %v", n, err)
	}
}

func TestMilestonesOf(t *testing.T) {
	gh, err := milestonesOf("github", []byte(`[{"number":15,"title":"0.14 Lineage and value"}]`))
	if err != nil || len(gh) != 1 || gh[0].Number != 15 || gh[0].Title != "0.14 Lineage and value" {
		t.Fatalf("github: %+v, %v", gh, err)
	}
	gl, err := milestonesOf("gitlab", []byte(`[{"iid":4,"title":"0.14.1 Bug fixes"}]`))
	if err != nil || len(gl) != 1 || gl[0].Number != 4 {
		t.Fatalf("gitlab: %+v, %v", gl, err)
	}
}

// fakeReleases is a fake forge for the release linker: tags, each tag's commit time, the
// commits a compare names, each commit's PR when its title has no number, and the
// milestones, with how often each was asked.
type fakeReleases struct {
	mu         sync.Mutex
	tags       []string
	commitTime map[string]time.Time
	compares   map[string][]compareCommit // key: base+".."+head
	commitPRs  map[string]int             // by sha, for a commit with no number in its title
	milestones []forgeMilestone
	asked      map[string]int // by kind: "compare", "commitPR", "milestones"
}

func (f *fakeReleases) tagsOf(string) ([]string, error) {
	return append([]string{}, f.tags...), nil
}

func (f *fakeReleases) time(_ context.Context, _ string, _ forgeRepo, ref string) (time.Time, error) {
	t, ok := f.commitTime[ref]
	if !ok {
		return time.Time{}, errNoForgeInTests
	}
	return t, nil
}

func (f *fakeReleases) compare(_ context.Context, _ string, _ forgeRepo, base, head string) ([]compareCommit, error) {
	f.mu.Lock()
	f.asked["compare"]++
	f.mu.Unlock()
	return f.compares[base+".."+head], nil
}

func (f *fakeReleases) commitPR(_ context.Context, _ string, _ forgeRepo, sha string) (int, error) {
	f.mu.Lock()
	f.asked["commitPR"]++
	f.mu.Unlock()
	return f.commitPRs[sha], nil
}

func (f *fakeReleases) ms(_ context.Context, _ string, _ forgeRepo) ([]forgeMilestone, error) {
	f.mu.Lock()
	f.asked["milestones"]++
	f.mu.Unlock()
	return f.milestones, nil
}

// #3023: the first tag in a repo links no PR, as there is no earlier one to compare since;
// a later tag links the PRs of the commits since the one before it, from a squash title's
// "(#n)" or, when it has none, the forge's commits/<sha>/pulls; a milestone whose title
// starts with the tag's version (a .0 patch dropped) is shipped-in it. Each tag is done
// once: a second check asks the forge nothing more.
func TestLinksReleasesFromTags(t *testing.T) {
	d, _ := start(t, t.TempDir())
	defer d.Shutdown()
	repo := forgeRepo{"github", "alexec/agents"}
	t013 := time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	t014 := time.Date(2026, 10, 27, 9, 0, 0, 0, time.UTC)
	forge := &fakeReleases{
		tags:       []string{"v0.14.0", "v0.13.0"}, // out of order on purpose: the linker sorts them.
		commitTime: map[string]time.Time{"v0.13.0": t013, "v0.14.0": t014},
		compares: map[string][]compareCommit{
			"v0.13.0..v0.14.0": {
				{SHA: "s1", Message: "Lineage: release nodes (#3023)"},
				{SHA: "s2", Message: "A merge commit with no number"},
			},
		},
		commitPRs:  map[string]int{"s2": 3024},
		milestones: []forgeMilestone{{Number: 15, Title: "0.14 Lineage and value"}},
		asked:      map[string]int{},
	}
	d.releaseTags, d.releaseCommitTime, d.releaseCompare, d.releaseCommitPR, d.releaseMilestones =
		forge.tagsOf, forge.time, forge.compare, forge.commitPR, forge.ms

	d.checkReleaseTagsForFolder(context.Background(), "/folder", repo)
	d.lineageSettle(5 * time.Second)

	rel013 := repo.release("v0.13.0")
	rel014 := repo.release("v0.14.0")
	// v0.13.0 is the first tag: it links no PR (there is nothing before it to compare
	// since), and the only milestone's title matches v0.14.0, not it.
	wantLinks(t, active(d, rel013))
	wantLinks(t, active(d, rel014),
		"github:alexec/agents#3023 part-of "+rel014.Ref+" (forge)",
		"github:alexec/agents#3024 part-of "+rel014.Ref+" (forge)",
		"github:alexec/agents/milestone/15 shipped-in "+rel014.Ref+" (forge)")
	for _, l := range d.lineage().Links(rel014).Links {
		if l.To == rel014 && l.At != wire.DateOf(t014) {
			t.Errorf("link at %v, want the tag's commit time %v", l.At, t014)
		}
	}

	// Done once: asking again finds nothing new to ask the forge for.
	before := map[string]int{"compare": forge.asked["compare"], "commitPR": forge.asked["commitPR"], "milestones": forge.asked["milestones"]}
	d.checkReleaseTagsForFolder(context.Background(), "/folder", repo)
	d.lineageSettle(5 * time.Second)
	if forge.asked["compare"] != before["compare"] || forge.asked["commitPR"] != before["commitPR"] {
		t.Fatalf("asked again: %+v, was %+v", forge.asked, before)
	}
}

// #3023: lineage/cost on a release adds up its PRs and the issues those PRs fix, once each.
func TestRollupOfARelease(t *testing.T) {
	cost := wire.LineageCost{Cost: map[string]float64{"USD": 1}}
	merged := lineage.OutcomeMerged
	nodes := []wire.LineageCostNode{
		{Node: wire.LineageNode{Kind: lineage.KindPR, Ref: "github:o/r#2"}, Banked: cost, PartOf: []string{"github:o/r/release/v1.0.0"}, Fixes: []string{"github:o/r#1"}, Outcome: &merged, LastAt: 2},
		{Node: wire.LineageNode{Kind: lineage.KindIssue, Ref: "github:o/r#1"}, Banked: cost, LastAt: 1},
		{Node: wire.LineageNode{Kind: lineage.KindPR, Ref: "github:o/r#9"}, Banked: cost, LastAt: 3}, // not part of the release.
	}
	r := lineage.Rollup(nodes, wire.LineageNode{Kind: lineage.KindRelease, Ref: "github:o/r/release/v1.0.0"})
	if r.Total.Cost["USD"] != 2 || len(r.Parts) != 2 {
		t.Fatalf("%+v", r)
	}
}
