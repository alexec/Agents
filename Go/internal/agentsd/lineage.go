package agentsd

import (
	"context"
	"path/filepath"
	"sync"
	"time"

	"github.com/alexec/agents/Go/internal/lineage"
	"github.com/alexec/agents/Go/wire"
)

// The lineage graph (#2348): typed links between issues, sessions, PRs and the rest, in
// <root>/lineage.jsonl, through lineage.Store so a graph database can take its place.
// A person's connection reads and writes it; lineagelinks.go makes the links on its own
// (#2349).

type lineageBook struct {
	lineageOnce  sync.Once
	lineageStore lineage.Store
	lineageLinker
	costLedgerBook
	prCommentBook
	issueMilestoneBook
	releaseTagsBook
	lineageResolveBook
}

func (d *Daemon) lineagePath() string { return filepath.Join(d.Store.Loc.Root, "lineage.jsonl") }

// lineage is the store, opened on first use.
func (d *Daemon) lineage() lineage.Store {
	d.lineageOnce.Do(func() { d.lineageStore = lineage.Open(d.lineagePath(), nowFunc) })
	return d.lineageStore
}

// closeLineage lets the file go at shutdown.
func (d *Daemon) closeLineage() {
	d.lineageSettle(2 * time.Second)
	d.closeCost()
	d.lineage().Close()
}

func (d *Daemon) registerLineage() {
	d.registerLineageCost()
	On(d, wire.CallLineageLink, func(_ context.Context, _ *Client, r wire.LineageLinkRequest) (wire.LineageLink, error) {
		l, err := d.lineage().Link(r, nowFunc())
		if err != nil {
			return l, Invalid("lineage/link: %v", err)
		}
		return l, nil
	})
	On(d, wire.CallLineageEnd, func(_ context.Context, _ *Client, r wire.LineageEndRequest) (wire.LineageLinks, error) {
		ended, err := d.lineage().End(r, nowFunc())
		return wire.LineageLinks{Links: ended}, err
	})
	On(d, wire.CallLineageLinks, func(_ context.Context, _ *Client, r wire.LineageNodeRequest) (wire.LineageLinks, error) {
		return d.lineage().Links(r.Node), nil
	})
	On(d, wire.CallLineageWalk, func(ctx context.Context, _ *Client, r wire.LineageNodeRequest) (wire.LineageGraph, error) {
		depth := 0
		if r.Depth != nil {
			depth = int(*r.Depth)
		}
		return d.resolvedGraph(ctx, d.lineage().Walk(r.Node, depth)), nil
	})
}
