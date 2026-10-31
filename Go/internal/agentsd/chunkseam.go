package agentsd

import "github.com/alexec/agents/Go/wire"

// A token split across two message chunks (#1001, slice a2). Redaction (redact.Text) runs
// on each transcript line alone, so `ghp_abc` in one chunk and `def…` in the next would go
// to disk whole. The end of each agent message chunk that could be the start of a token, a
// trailing run of token characters of at most heldMost bytes, is held back and goes at the
// front of the next chunk of the same message, or by itself when a different message or
// update comes, or the turn ends. The clients see that tail a chunk later.

// heldMost bounds what is held back: more than the longest known token shape's prefix and
// body together would be held for nothing.
const heldMost = 256

// tokenByte is a byte a token shape can hold: letters, digits and _ - . / + =.
func tokenByte(c byte) bool {
	return 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z' || '0' <= c && c <= '9' ||
		c == '_' || c == '-' || c == '.' || c == '/' || c == '+' || c == '='
}

// splitHeld is text less its trailing run of token characters (at most heldMost bytes),
// and that run. Every token byte is ASCII, so the cut is never inside a rune.
func splitHeld(text string) (send, hold string) {
	i := len(text)
	for i > 0 && len(text)-i < heldMost && tokenByte(text[i-1]) {
		i--
	}
	return text[:i], text[i:]
}

// holdChunk takes an agent message chunk: what to record now, the held text of an
// earlier message first when this one is another.
func (l *live) holdChunk(id *string, text string) (earlier *wire.TranscriptEntryKindAgentMessage, now string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.held != "" && !sameMessageID(l.heldID, id) {
		earlier = &wire.TranscriptEntryKindAgentMessage{MessageID: l.heldID, Text: l.held}
		l.held = ""
	}
	now, l.held = splitHeld(l.held + text)
	l.heldID = id
	return earlier, now
}

// flushHeld records what is held back, if anything: a different update came, or the
// turn ended.
func (l *live) flushHeld() {
	l.mu.Lock()
	text, id := l.held, l.heldID
	l.held, l.heldID = "", nil
	l.mu.Unlock()
	if text != "" {
		l.d.record(l.id, wire.TranscriptEntryKind{AgentMessage: &wire.TranscriptEntryKindAgentMessage{MessageID: id, Text: text}})
	}
}
