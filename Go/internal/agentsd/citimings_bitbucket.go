package agentsd

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/bitbucketmcp"
	"github.com/agentloops-dev/agent-loops/Go/internal/citimings"
)

// Build timings from Bitbucket Pipelines (#5223, spec 5166, "The data spike"), as from GitHub
// (citimings.go): the same store, bounds and pacing. A pipeline is a run and its steps are its
// jobs (citimings/bitbucket.go).
//
//   - Live: the newest completed pipelines (pipelines/?status=COMPLETED&sort=-created_on), and
//     for each attempt the store does not have, its steps (pipelines/{build number}/steps/): one
//     call a pipeline.
//   - Backfill: the same list, page after page, newest first, until a page is older than
//     citimings.KeepDays or the list ends. Decided: Bitbucket's list is paged, not windowed by
//     time as GitHub's is, so the backfill keeps the next page's number; a pipeline made since
//     moves the pages on, so a page is seen again, never missed, because the list is newest
//     first. Alex can overrule.
//   - Pacing: Bitbucket Cloud allows 1,000 API calls an hour for a person's token, so the
//     backfill takes a tenth of that (ciBitbucketHourly / ciBackfillShare), apart from GitHub's.
//   - Auth: the person's Bitbucket connection (its email, when it has one, as Basic auth with
//     an Atlassian API token, else a Bearer access token), else BITBUCKET_TOKEN and
//     BITBUCKET_EMAIL in the secrets, as the bitbucket server takes them.

const (
	// ciBitbucketHourly is Bitbucket Cloud's hourly limit for a token's API calls.
	ciBitbucketHourly = 1000
	// ciBitbucketPage is the most pipelines or steps Bitbucket gives on one page.
	ciBitbucketPage = 100
	// ciBitbucketStepPages bounds the pages of one pipeline's steps.
	ciBitbucketStepPages = 3
	// ciBitbucketMostPages bounds the backfill's pages: 10,000 pipelines.
	ciBitbucketMostPages = 100
)

// ciBitbucketAuth is the token, and the email for Basic auth, the person gave for Bitbucket.
func (d *Daemon) ciBitbucketAuth() (root, token, email string) {
	if d.ciBitbucketAPI != "" {
		return d.ciBitbucketAPI, "test", ""
	}
	if c, ok := d.bitbucketConnection(); ok && c.Usable(nowFunc()) {
		return bitbucketmcp.BaseURL(c.URL), c.Access, c.User
	}
	s := d.secrets()
	if s["BITBUCKET_TOKEN"] != "" {
		return bitbucketmcp.DefaultBase, s["BITBUCKET_TOKEN"], s["BITBUCKET_EMAIL"]
	}
	return "", "", ""
}

// ciBitbucketPath is a path under the repository's part of Bitbucket's API.
func ciBitbucketPath(h ciRepoHere, rest string) string {
	workspace, name, _ := strings.Cut(h.repo.path, "/")
	return "repositories/" + url.PathEscape(workspace) + "/" + url.PathEscape(name) + rest
}

// ciBitbucketList is one page of the newest completed pipelines.
func (d *Daemon) ciBitbucketList(ctx context.Context, h ciRepoHere, page int) (citimings.BitbucketPipelines, error) {
	var list citimings.BitbucketPipelines
	q := url.Values{"status": {"COMPLETED"}, "sort": {"-created_on"}, "pagelen": {strconv.Itoa(ciBitbucketPage)}, "page": {strconv.Itoa(page)}}
	raw, err := d.ciGet(ctx, h, ciBitbucketPath(h, "/pipelines/?"+q.Encode()))
	if err != nil {
		return list, err
	}
	if err := json.Unmarshal(raw, &list); err != nil {
		return list, fmt.Errorf("the pipeline list: %v", err)
	}
	return list, nil
}

// ciBitbucketLive reads the newest completed pipelines, until a page has nothing new.
func (d *Daemon) ciBitbucketLive(ctx context.Context, h ciRepoHere, key, def string) error {
	for page := 1; page <= ciLivePages; page++ {
		list, err := d.ciBitbucketList(ctx, h, page)
		if err != nil {
			return err
		}
		added, err := d.ciKeepPipelinesBitbucket(ctx, h, def, list.Values, nowFunc())
		if err != nil {
			return err
		}
		if added == 0 || list.Next == "" {
			break
		}
	}
	at := nowFunc()
	d.ciMu.Lock()
	d.ciRepoLocked(key).ReadAt = &at
	d.saveCIFileLocked()
	d.ciMu.Unlock()
	return nil
}

// ciBitbucketBackfill reads older pages while the hour's budget lasts.
func (d *Daemon) ciBitbucketBackfill(ctx context.Context, h ciRepoHere, key, def string) error {
	for ctx.Err() == nil && d.ciBudgetLeft() && d.ciBitbucketBudgetLeft() {
		d.ciMu.Lock()
		st := d.ciRepoLocked(key)
		filled, page := st.Filled, st.BackfillPage+1
		d.ciMu.Unlock()
		if filled {
			return nil
		}
		now := nowFunc()
		list, err := d.ciBitbucketList(ctx, h, page)
		if err != nil {
			return err
		}
		if _, err := d.ciKeepPipelinesBitbucket(ctx, h, def, list.Values, now); err != nil {
			return err
		}
		oldest := now
		for _, p := range list.Values {
			if t, err := time.Parse(time.RFC3339, p.CreatedOn); err == nil && t.Before(oldest) {
				oldest = t
			}
		}
		d.ciMu.Lock()
		st = d.ciRepoLocked(key)
		st.BackfillPage = page
		st.FilledFrom = &oldest
		st.Filled = list.Next == "" || page >= ciBitbucketMostPages || now.Sub(oldest) >= citimings.KeepDays*24*time.Hour
		if st.Filled {
			// The backfill reached as far back as the store keeps, or the list's start.
			from := now.Add(-citimings.KeepDays * 24 * time.Hour)
			if list.Next == "" && oldest.After(from) {
				from = oldest
			}
			st.FilledFrom = &from
		}
		d.saveCIFileLocked()
		d.ciMu.Unlock()
	}
	return nil
}

// ciKeepPipelinesBitbucket reads the steps of each pipeline attempt the store does not have,
// within its bounds, and keeps them; it says how many it kept.
func (d *Daemon) ciKeepPipelinesBitbucket(ctx context.Context, h ciRepoHere, def string, pipelines []citimings.BitbucketPipeline, now time.Time) (int, error) {
	repo := citimings.Repo{Forge: h.repo.forge, Path: h.repo.path}
	added := 0
	for _, p := range pipelines {
		if ctx.Err() != nil {
			return added, ctx.Err()
		}
		made, err := time.Parse(time.RFC3339, p.CreatedOn)
		if err != nil || !p.Completed() || p.BuildNumber <= 0 {
			continue
		}
		onDefault := p.Branch() == def && !p.PullRequest() && !p.OnTag()
		keep := citimings.StepDays
		if onDefault || p.OnTag() && !p.PullRequest() {
			keep = citimings.KeepDays
		}
		ref := h.repo.ciRun(p.BuildNumber).Ref
		if now.Sub(made) > time.Duration(keep)*24*time.Hour || d.ciTimings().Has(repo, ref, max(p.RunNumber, 1), made) {
			continue
		}
		var pages [][]byte
		next := ciBitbucketPath(h, fmt.Sprintf("/pipelines/%d/steps/?pagelen=%d", p.BuildNumber, ciBitbucketPage))
		for i := 0; i < ciBitbucketStepPages && next != ""; i++ {
			raw, err := d.ciGet(ctx, h, next)
			if err != nil {
				return added, err
			}
			pages = append(pages, raw)
			next = ""
			if n := citimings.BitbucketStepsNext(raw); n != "" {
				next = ciBitbucketNext(n, h)
			}
		}
		page := fmt.Sprintf("https://%s/%s/pipelines/results/%d", bitbucketmcp.Host, h.repo.path, p.BuildNumber)
		got, err := citimings.FromBitbucket(p, pages, ref, page, onDefault)
		if err != nil {
			log.Printf("build timings: %s: %v", h.repo.path, err)
			continue
		}
		if err := d.ciTimings().Put(repo, got...); err != nil {
			return added, err
		}
		added++
	}
	if added > 0 {
		d.ciChanged(repo.String())
	}
	return added, nil
}

// ciBitbucketNext is a next link as a path under the API's root, or "" when it is on another
// host: the token goes to Bitbucket's API only.
func ciBitbucketNext(next string, h ciRepoHere) string {
	u, err := url.Parse(next)
	if err != nil {
		return ""
	}
	_, path, ok := strings.Cut(u.EscapedPath(), "/2.0/")
	if !ok || !strings.HasPrefix(path, ciBitbucketPath(h, "/pipelines/")) {
		return ""
	}
	if u.RawQuery != "" {
		path += "?" + u.RawQuery
	}
	return path
}

// ciBitbucketBudgetLeft says the backfill may make another Bitbucket call this hour.
func (d *Daemon) ciBitbucketBudgetLeft() bool {
	d.ciMu.Lock()
	defer d.ciMu.Unlock()
	f := d.ciFileLocked()
	d.ciHourLocked(f)
	return f.BitbucketCalls < ciBitbucketHourly/ciBackfillShare
}

// ciGetBitbucket is one GET of Bitbucket's API, counted against Bitbucket's hour too.
func (d *Daemon) ciGetBitbucket(ctx context.Context, path string) ([]byte, error) {
	d.ciMu.Lock()
	d.ciFileLocked().BitbucketCalls++
	d.ciMu.Unlock()
	root, token, email := d.ciBitbucketAuth()
	if token == "" {
		return nil, errors.New(bitbucketmcp.NotConnected)
	}
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimSuffix(root, "/")+"/"+path, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/json")
	if email = strings.TrimSpace(email); email != "" {
		req.SetBasicAuth(email, token)
	} else {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("Bitbucket answered %d", resp.StatusCode)
	}
	return body, nil
}
