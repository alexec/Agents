package providers

import (
	"encoding/json"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/alexec/agents/Go/wire"
)

// The daily summary's facts from the person's other machines (#3354). A machine cannot read
// another's sessions, so the Daily summary workflow's agent asks here (machines/summaryFacts),
// and the control plane asks each of the person's other machines that is online for its own
// facts (agents/summaryFacts), all at once. A read relayed now, not a list each machine
// pushes: the facts are as fresh as the summary, and nothing is kept here. A machine that is
// off, or does not answer in time, is named with why, never left out silently.

const (
	// mostSummaryMachines bounds the machines one machines/summaryFacts asks; the rest are
	// named as not asked.
	mostSummaryMachines = 50
	// summaryFactsPatience is how long each machine has to answer: it may ask gh for the
	// pull requests merged in its folders.
	summaryFactsPatience = 30 * time.Second
)

// summaryFacts is machines/summaryFacts: each of the person's machines but host, by name,
// with its facts or the words for why there are none.
func (p *Providers) summaryFacts(host string, params json.RawMessage, caller Caller) (any, error) {
	var request wire.SummaryFactsRequest
	if err := requireParams(params, &request, "SummaryFactsRequest", "since"); err != nil {
		return nil, err
	}
	var machines []wire.MachineSummaryFacts
	for _, h := range p.records.Hosts() {
		// Another user's machine is not this person's summary (FR-038); a relay has no folders.
		if strings.EqualFold(h.ID, host) || p.hooks.OwnerOf(h.ID) != caller.Person ||
			h.Forgotten != nil && *h.Forgotten || h.Relay != nil && *h.Relay {
			continue
		}
		machines = append(machines, wire.MachineSummaryFacts{Machine: wire.MachineRef(h.ID), MachineName: h.Name})
	}
	slices.SortFunc(machines, func(a, b wire.MachineSummaryFacts) int { return strings.Compare(a.MachineName, b.MachineName) })
	raw := rawOf(request)
	var wg sync.WaitGroup
	for i := range machines {
		m := &machines[i]
		switch {
		case i >= mostSummaryMachines:
			m.Unreached = new("not asked, as there are over 50 machines")
		case !p.router.Online(string(m.Machine)):
			m.Unreached = new("off")
		default:
			wg.Go(func() { m.Facts, m.Unreached = p.askSummaryFacts(string(m.Machine), raw, caller) })
		}
	}
	wg.Wait()
	if machines == nil {
		machines = []wire.MachineSummaryFacts{}
	}
	return wire.MachinesSummaryFacts{Machines: machines}, nil
}

// askSummaryFacts is one machine's agents/summaryFacts: its facts, or why there are none.
func (p *Providers) askSummaryFacts(host string, params json.RawMessage, caller Caller) (*wire.SummaryFacts, *string) {
	reply := p.router.DeliverKept(wire.CallAgentsSummaryFacts.Name, params, caller.Client, caller.Kind, host, summaryFactsPatience)
	switch {
	case reply == nil:
		return nil, new("did not answer in time")
	case reply.Error != nil:
		// A machine from before #3354 does not know the method.
		return nil, new("too old to say, or refused: " + reply.Error.Message)
	}
	var facts wire.SummaryFacts
	if json.Unmarshal(reply.Result, &facts) != nil {
		return nil, new("its answer could not be read")
	}
	return &facts, nil
}
