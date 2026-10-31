package controlplane

import "context"

// The plan's limit on agents running at the same time (#2243, spec 1003 FR-022): a hook
// hosted sets per account (Config.AgentsRunningGate), checked at the router's chokepoint
// to every host (toHostLocked) alongside the policy's own gate. Nothing running is
// stopped: a refusal only turns away the one that would start next.

// startsAgent are the calls that begin another running agent, each with a new id: those
// the plan's limit counts against.
var startsAgent = methodSet(
	"agents/branchFrom",
	"agents/continueInFolder",
	"agents/continueInNew",
	"agents/fork",
	"agents/start",
)

// runningAgents is how many agents are running now, across every host here, as each last
// listed them (#962): the same count the Console's Live Now shows. The best known count,
// not asked fresh of a host, so the gate answers without a round trip.
func (s *Service) runningAgents(ctx context.Context) int64 {
	var n int64
	for _, h := range s.records.Hosts() {
		if copy := s.copies.current(ctx, h.ID); copy != nil && copy.Agents != nil {
			n += runningInList(copy.Agents)
		}
	}
	return n
}

// agentsRunningGate is the router's check of a call that would start another agent,
// against Config.AgentsRunningGate: nil where hosted holds this copy to no limit, or the
// call starts no agent.
func (s *Service) agentsRunningGate(host, method string) error {
	if s.cfg.AgentsRunningGate == nil || !startsAgent[method] {
		return nil
	}
	return s.cfg.AgentsRunningGate(int(s.runningAgents(context.Background())))
}
