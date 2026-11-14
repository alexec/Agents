package agentsd

import (
	"context"
	"encoding/json"

	"github.com/agentloops-dev/agent-loops/Go/wire"
)

// pair_web_page (#4214): the agent browser that this agentsd launched opens the web page
// already paired, as Open in Browser pairs the person's own browser, so an agent can use
// the web page (Connectors, the bot, Settings) with no person. agentsd asks the control
// plane for a one-time browser code on its own uplink, and only the machine on the control
// plane's Mac gets one. The code goes from that uplink to this browser's tab; the agent
// is told the page opened, never the code.

const pairWebPageName = "pair_web_page"

// pairWebPageTool is pair_web_page as tools/list sends it, with the browser tools.
var pairWebPageTool = json.RawMessage(`{"name":"pair_web_page","title":"Open the web page, paired",` +
	`"description":"Open the app's web page (the control plane's, on localhost) in the browser, paired with the person's account, with no pairing code to ask for. ` +
	`Use it before a step that only the web page does, such as Connectors or Settings. You never see the code. It works on the machine the control plane runs on.",` +
	`"inputSchema":{"type":"object","properties":{},"additionalProperties":false},` +
	`"annotations":{"title":"Open the web page, paired","readOnlyHint":false,"destructiveHint":false,"openWorldHint":false}}`)

// pairWebPage gets the code and opens the page with it in the agent's tab.
func (d *Daemon) pairWebPage(ctx context.Context, drive *browserDrive) ([]any, bool, string) {
	ask := d.askControl.Load()
	if ask == nil {
		return fillWords("The web page was not opened: this machine has no control plane.")
	}
	out, err := (*ask)(ctx, wire.CallMachinePairWebPage.Name, wire.Empty{})
	var pairing wire.WebPagePairing
	if err == nil {
		err = json.Unmarshal(out, &pairing)
	}
	if err != nil {
		return fillWords("The web page was not opened: " + err.Error())
	}
	res, err := drive.call(ctx, "browser_navigate", map[string]json.RawMessage{"url": rawString(pairing.URL)})
	// Neither the result nor an error goes back: either could hold the code.
	if err != nil || res.IsError {
		return fillWords("The web page did not open in the browser. Call pair_web_page again.")
	}
	note := "The web page is open in the browser and pairs with it now. Take a browser_snapshot to go on."
	return []any{map[string]any{"type": "text", "text": note}}, false, note
}
