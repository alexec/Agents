//go:build !darwin

package agentsd

// simulatorHelper is "": simulators run on a Mac only (#842).
func simulatorHelper() string { return "" }
