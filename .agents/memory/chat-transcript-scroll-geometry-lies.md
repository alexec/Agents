---
name: chat-transcript-scroll-geometry-lies
description: "ChatTranscript's LazyVStack re-measures every frame, so geometry can't tell a reader's scroll from the stack; a .scrollPosition binding re-anchors the pane by itself"
metadata:
  type: project
  modified: 2026-10-08T01:33:45.251Z
---

Found walking #378 (merged eb9aab4f, 2026-10-07): in `Shared/UI/Chat/ChatTranscript.swift` the lazy stack's content height jitters frame to frame (3252 → 3095 → 3421 …) and the offset moves with it, so "offset went up with the height unchanged" is as often the stack as the reader. Reading back is now told by input (`TranscriptInput.swift`: wheel over the transcript, finger distance via scroll phase, keys).

Adding `.scrollPosition($position)` with `.scrollTargetLayout()` made the pane jump to the top at open and back up after pins — don't use it there; page keys go through ScrollViewProxy and the visible turn ids.

A `.task(id:)` closure holds the view's `let` props as they were (settle's `entryCount` never changed); read fresh values through @State set from `onChange`.

**Why:** these cost most of the #378 Mac lane; os Logger + `/usr/bin/log show --predicate 'subsystem == …'` around the geometry action is what found them.
**How to apply:** any change to follow/read-back logic in the transcript: walk it with HID events in front (see [[pid-scroll-events-do-not-leave-follow-mode]]), log geometry, don't trust geometry for intent.
