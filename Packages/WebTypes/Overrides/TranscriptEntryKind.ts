// as synthesized, defaults optional
// passthrough: unrecognised
// TranscriptEntry.Kind (Model/TranscriptEntry+Coding.swift) writes the synthesized shape by hand
// so old records still read: nil and default values are left out, and a kind a newer build wrote
// (`unrecognised`) is written back as it came, so the web remote must skip keys it doesn't know.
