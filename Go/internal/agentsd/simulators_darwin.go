package agentsd

import "os"

// simulatorHelper is agents-watch, which touches a simulator on a Mac (#842), or "" when it is
// not beside agentsd.
func simulatorHelper() string {
	helper := watchHelper()
	if _, err := os.Stat(helper); err != nil {
		return ""
	}
	return helper
}
