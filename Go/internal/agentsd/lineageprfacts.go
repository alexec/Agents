package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"net/url"
	"strconv"

	"github.com/agentloops-dev/agents/Go/internal/lineage"
	"github.com/agentloops-dev/agents/Go/wire"
)

// A merged PR's facts for the delivery figures (#4552): its files, for the rework rate, and
// the PR a revert reverts, for the recovery time. The forge's PR events say neither, so a
// pr.merged asks gh or glab once, in the background, in a folder signed in to the PR's repo,
// at most prFactsWorkers at a time. The files are kept on its cost node, at most
// lineage.FilesKept, and dropped lineage.FilesKeep after its merge (pruneCost).
//
// Decided: GitHub and GitLab only, by their CLIs, because the other forges' connections ask
// no PR's files yet; a PR whose files are not known is left out of the rework rate.

// prFactsWorkers is how many gh or glab processes ask a merged PR's facts at once.
const prFactsWorkers = 2

// prFacts is what a merged PR's forge says for the delivery figures.
type prFacts struct {
	files []string
	// body is its description, for the PR a revert names.
	body string
}

// prFactsLookup asks the forge for a merged PR's facts. Tests set a daemon's prFactsLookup in
// place of prFactsAsk.
type prFactsLookup func(ctx context.Context, folder string, repo forgeRepo, n int) (prFacts, error)

// prFactsAsk is how a daemon with no prFactsLookup asks: forgePRFacts. TestMain turns it off.
var prFactsAsk prFactsLookup = forgePRFacts

// askPRFacts asks, in the background, for the facts of the PR n of repo that merged.
func (d *Daemon) askPRFacts(repo forgeRepo, n int, pr wire.LineageNode) {
	if repo.forge != "github" && repo.forge != "gitlab" {
		return
	}
	folder := d.repoFolder(repo)
	if folder == "" {
		return
	}
	d.workMu.Lock()
	if d.prFactsSlots == nil {
		d.prFactsSlots = make(chan struct{}, prFactsWorkers)
	}
	slots, ask := d.prFactsSlots, d.prFactsLookup
	d.workMu.Unlock()
	if ask == nil {
		ask = prFactsAsk
	}
	ctx := d.ctx
	if ctx == nil {
		ctx = context.Background()
	}
	go func() {
		slots <- struct{}{}
		defer func() { <-slots }()
		facts, err := ask(ctx, folder, repo, n)
		if err != nil {
			log.Printf("lineage: the files of %s: %v", pr.Ref, err)
			return
		}
		d.notePRFacts(pr, repo, facts)
	}()
}

// notePRFacts keeps a merged PR's files and the PR it reverts on its node.
func (d *Daemon) notePRFacts(pr wire.LineageNode, repo forgeRepo, facts prFacts) {
	files := facts.files[:min(len(facts.files), lineage.FilesKept)]
	// In the full form, as the PR nodes are (#4824), so the figures find the PR it reverts.
	reverts := lineage.RevertsIn(repo.forge+":"+repo.path, facts.body)
	if reverts != "" {
		reverts = lineage.FullRefText(lineage.KindPR, reverts, "")
	}
	d.workMu.Lock()
	defer d.workMu.Unlock()
	d.noteCostLocked(pr, nowFunc(), func(c *wire.LineageCostNode) {
		c.Files = files
		c.Reverts = nil
		if reverts != "" && reverts != pr.Ref {
			c.Reverts = &reverts
		}
	})
	d.costChangedLocked()
}

// forgePRFacts asks gh or glab, in folder, for the PR's files and description.
func forgePRFacts(ctx context.Context, folder string, repo forgeRepo, n int) (prFacts, error) {
	switch repo.forge {
	case "github":
		exe := forgeCLI("gh")
		if exe == "" {
			return prFacts{}, errors.New("gh is not installed")
		}
		out, err := runForgeCLI(ctx, exe, folder, nil, "pr", "view", strconv.Itoa(n), "--repo", repo.path, "--json", "files,body")
		if err != nil {
			return prFacts{}, err
		}
		return githubPRFactsOf(out)
	case "gitlab":
		exe := forgeCLI("glab")
		if exe == "" {
			return prFacts{}, errors.New("glab is not installed")
		}
		out, err := runForgeCLI(ctx, exe, folder, nil, "api",
			fmt.Sprintf("projects/%s/merge_requests/%d/changes", url.PathEscape(repo.path), n))
		if err != nil {
			return prFacts{}, err
		}
		return gitlabPRFactsOf(out)
	}
	return prFacts{}, fmt.Errorf("no PR files on %s", repo.forge)
}

// githubPRFactsOf reads `gh pr view --json files,body`.
func githubPRFactsOf(out []byte) (prFacts, error) {
	var j struct {
		Body  string `json:"body"`
		Files []struct {
			Path string `json:"path"`
		} `json:"files"`
	}
	if err := json.Unmarshal(out, &j); err != nil {
		return prFacts{}, err
	}
	f := prFacts{body: j.Body}
	for _, file := range j.Files {
		if file.Path != "" {
			f.files = append(f.files, file.Path)
		}
	}
	return f, nil
}

// gitlabPRFactsOf reads GitLab's merge_requests/<n>/changes: a renamed file is both its paths.
func gitlabPRFactsOf(out []byte) (prFacts, error) {
	var j struct {
		Description string `json:"description"`
		Changes     []struct {
			OldPath string `json:"old_path"`
			NewPath string `json:"new_path"`
		} `json:"changes"`
	}
	if err := json.Unmarshal(out, &j); err != nil {
		return prFacts{}, err
	}
	f := prFacts{body: j.Description}
	for _, c := range j.Changes {
		if c.NewPath != "" {
			f.files = append(f.files, c.NewPath)
		}
		if c.OldPath != "" && c.OldPath != c.NewPath {
			f.files = append(f.files, c.OldPath)
		}
	}
	return f, nil
}
