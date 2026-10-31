//go:build !darwin && !linux

package agentsd

import "errors"

// exchangePaths cannot swap in one step here: an update takes two renames.
func exchangePaths(a, b string) error { return errors.ErrUnsupported }
