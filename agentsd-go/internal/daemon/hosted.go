package daemon

import "net/http"

// hostedServers is stage 4's: "hosted": true stdio servers, served to sessions over HTTP.
type hostedServers struct{}

func (h *hostedServers) routes() []string                              { return nil }
func (h *hostedServers) ServeHTTP(w http.ResponseWriter, r *http.Request) { http.NotFound(w, r) }
