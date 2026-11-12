//go:build race

package agentsd

// raceEnabled says the race detector is on (#4680). It slows each memory access by
// several times, so a test that measures wall time skips under it.
const raceEnabled = true
