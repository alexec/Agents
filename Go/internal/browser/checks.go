package browser

import (
	"net/url"
	"slices"
	"strings"

	"golang.org/x/net/publicsuffix"
)

// botCheckSites are the sites, by registrable domain, whose bot check refuses a headless
// Chrome even when it says Chrome (#4272): Cloudflare's dashboard (#3911), Microsoft's
// account sign-up (#3908) and Paddle's checkout (#4019). The browser opens them headed.
var botCheckSites = []string{
	"cloudflare.com",
	"live.com",
	"microsoft.com",
	"microsoftonline.com",
	"paddle.com",
	"paddle.io",
}

// ChecksBots is whether the page at rawURL is on a site whose bot check needs a headed
// browser (Machine.Headed).
func ChecksBots(rawURL string) bool {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || u.Hostname() == "" {
		// Playwright opens a URL with no scheme as https.
		if u, err = url.Parse("https://" + strings.TrimSpace(rawURL)); err != nil {
			return false
		}
	}
	site, err := publicsuffix.EffectiveTLDPlusOne(strings.ToLower(u.Hostname()))
	return err == nil && slices.Contains(botCheckSites, site)
}
