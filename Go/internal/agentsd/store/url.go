package store

import "net/url"

func unescape(p string) (string, error) { return url.PathUnescape(p) }

// escapePath escapes a path as Foundation's file URL does: only what a URL path cannot hold.
func escapePath(p string) string { return (&url.URL{Path: p}).EscapedPath() }
