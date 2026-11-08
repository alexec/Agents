package agentsd

import (
	"context"
	"encoding/json"
	"slices"
	"strings"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/alexec/agents/Go/wire"
)

// fill_secret (#3530, spike #3527): the agent names a secret from Settings ▸ Secrets and a
// field on the page, and agentsd types the value into it through the agent's own
// @playwright/mcp. The value goes from secrets.env to the page and nowhere else: not to
// the agent, the model, the transcript or the logs. The agent is told "<NAME> filled".
// After the fill, every way the agent reads the page is closed to the value:
//
//   - text: the machine's browser.Filter takes it out of every result, as <secret NAME>;
//   - pixels: the field is drawn as dots (-webkit-text-security), in screenshots and in
//     the stream to the person, and drawn so again when the page changes its style;
//   - scripts: browser_evaluate on a page with a filled field, and browser_run_code_unsafe
//     while any value is filled, are refused, as a script can read the value in ways a
//     filter cannot follow;
//   - files: a call that asks Playwright to write its result to a file is refused while a
//     value is filled, as the file would skip the filter.
//
// The promise is ask_secret's (#2885): an agent that tries hard can read secrets.env or
// talk to Chromium itself; for a wall, use the sandbox.

const fillSecretName = "fill_secret"

// fillSecretTool is fill_secret as tools/list sends it, with the browser tools.
var fillSecretTool = json.RawMessage(`{"name":"fill_secret","title":"Fill a secret into a page field",` +
	`"description":"Type one of the person's secrets (Settings ▸ Secrets), such as a password or an API key, into a field on the browser's page, without you seeing it. ` +
	`Name the secret and the field as browser_type does (target: a reference from browser_snapshot, or a selector). You get \"<NAME> filled\", never the value. ` +
	`After it, the field shows as dots, page reads show the value as <secret NAME>, and browser_evaluate is refused on that page until it navigates. ` +
	`When the secret is not set, ask for it with ask_secret first. Never ask for a secret's value or type it with browser_type. ` +
	`A card secret (a payment card with a spend limit) is filled a part at a time: name the part for each field.",` +
	`"inputSchema":{"type":"object","properties":{` +
	`"secret":{"type":"string","description":"The secret's name, as in Settings ▸ Secrets, e.g. GITLAB_PASSWORD."},` +
	`"element":{"type":"string","description":"The field, in words, for the person: e.g. \"Password field\"."},` +
	`"part":{"type":"string","enum":["number","expiry","exp_month","exp_year","cvc","name","zip"],"description":"For a card secret only: which part goes in this field. expiry is MM/YY, exp_month MM, exp_year YYYY, zip the billing postal code."},` +
	`"target":{"type":"string","description":"Exact target element reference from the page snapshot, or a unique element selector"},` +
	`"submit":{"type":"boolean","description":"Whether to press Enter after the fill."}},` +
	`"required":["secret","target"],"additionalProperties":false},` +
	`"annotations":{"title":"Fill a secret","readOnlyHint":false,"destructiveHint":true,"openWorldHint":true}}`)

// filledMark is the attribute the fill puts on a field it filled: the evaluate check
// looks for it.
const filledMark = "data-agents-filled"

// maskField draws the field's text as dots, marks it, and draws it as dots again when the
// page changes its style.
const maskField = `(el) => {
  const mask = () => {
    if (el.style.getPropertyValue('-webkit-text-security') !== 'disc' || el.style.getPropertyPriority('-webkit-text-security') !== 'important')
      el.style.setProperty('-webkit-text-security', 'disc', 'important');
    if (!el.hasAttribute('` + filledMark + `')) el.setAttribute('` + filledMark + `', '');
  };
  mask();
  if (!el.__agentsFillWatch) {
    el.__agentsFillWatch = new MutationObserver(mask);
    el.__agentsFillWatch.observe(el, { attributes: true, attributeFilter: ['style', 'class', '` + filledMark + `'] });
  }
  return 'agents-masked';
}`

// filledCheck says whether the page (the target's, or the tab's) has a filled field, in
// its own document or in a frame it can reach.
const filledCheck = `(el) => {
  let start = el ? el.ownerDocument : document;
  try { start = (el ? el.ownerDocument.defaultView : window).top.document; } catch (e) {}
  const filled = (d) => {
    try {
      if (d.querySelector('[` + filledMark + `]')) return true;
      for (const f of d.querySelectorAll('iframe, frame')) {
        try { if (f.contentDocument && filled(f.contentDocument)) return true; } catch (e) {}
      }
    } catch (e) {}
    return false;
  };
  return filled(start) || (el ? filled(el.ownerDocument) : false) ? 'agents-filled' : 'agents-clear';
}`

// fillWords is a refusal or failure as the agent reads it.
func fillWords(msg string) ([]any, bool, string) {
	return []any{map[string]any{"type": "text", "text": msg}}, true, msg
}

// secretFill is what one fill_secret call types, read before the lease.
type secretFill struct {
	label string // the secret's name, and a card's part: what the agent is told was filled
	value string
	// hide is every value the call puts in the filter, by its label: for a card, all its
	// parts, so none of them comes back once the card is in the page.
	hide  map[string]string
	codes map[string]string // a card's CVC, hidden as a whole number
}

// cardParts are a card secret's parts as fill_secret names them (#3531).
var cardParts = []string{"number", "expiry", "exp_month", "exp_year", "cvc", "name", "zip"}

// cardSecret is a card secret's value: one JSON object, as Settings ▸ Secrets writes it.
type cardSecret struct {
	Number string `json:"number"`
	Expiry string `json:"expiry"` // MM/YY
	CVC    string `json:"cvc"`
	Name   string `json:"name"`
	Zip    string `json:"zip"`
}

// parseCard is value's parts, or false when value is not a card.
func parseCard(value string) (map[string]string, bool) {
	if !strings.HasPrefix(value, "{") {
		return nil, false
	}
	var c cardSecret
	if json.Unmarshal([]byte(value), &c) != nil || c.Number == "" {
		return nil, false
	}
	month, year, _ := strings.Cut(c.Expiry, "/")
	if len(year) == 2 {
		year = "20" + year
	}
	return map[string]string{"number": c.Number, "expiry": c.Expiry, "exp_month": month, "exp_year": year,
		"cvc": c.CVC, "name": c.Name, "zip": c.Zip}, true
}

// fillSecretValue is what the call fills, read from the session's own secrets (#3548) or
// secrets.env, or the words that say why nothing. It runs before the lease, so a call that
// cannot fill starts nothing.
func (d *Daemon) fillSecretValue(agent wire.UUID, args map[string]json.RawMessage) (fill secretFill, refusal string) {
	name := strings.TrimSpace(argString(args, "secret"))
	if !secretAskName.MatchString(name) {
		return fill, "Nothing was filled: `secret` is the secret's name, letters, digits and underscores, e.g. GITLAB_PASSWORD."
	}
	if strings.TrimSpace(argString(args, "target")) == "" {
		return fill, "Nothing was filled: `target` is the field, a reference from browser_snapshot or a selector."
	}
	home := d.personalHome()
	if home == "" {
		return fill, "Nothing was filled: this machine has no personal home to keep secrets in."
	}
	v, ok, expired := d.localSecret(agent, name)
	if expired && (!ok || v == "") {
		return fill, name + " was for this session only and has expired. Ask the person for it again with ask_secret if you still need it."
	}
	if !ok || v == "" {
		return fill, name + " is not set. Ask the person for it with ask_secret, then call fill_secret again."
	}
	part := strings.TrimSpace(argString(args, "part"))
	if parts, card := parseCard(v); card {
		if !slices.Contains(cardParts, part) {
			return fill, "Nothing was filled: " + name + " is a card. Name the part for this field in `part`: " + strings.Join(cardParts, ", ") + "."
		}
		if parts[part] == "" {
			return fill, "Nothing was filled: " + name + " has no " + part + ". Ask the person to replace it in Settings ▸ Secrets."
		}
		fill = secretFill{label: name + " " + part, value: parts[part], hide: map[string]string{}, codes: map[string]string{}}
		for p, value := range parts {
			switch p {
			case "cvc":
				fill.codes[name+"."+p] = value
			case "exp_month", "exp_year":
				// Not secret on their own; expiry hides them together.
			default:
				fill.hide[name+"."+p] = value
			}
		}
		return fill, ""
	}
	if part != "" {
		return fill, "Nothing was filled: " + name + " is not a card, so leave out `part`."
	}
	// The filter does not hide a value this short: it would take half the page out.
	if len([]rune(v)) < 4 {
		return fill, "Nothing was filled: " + name + " is shorter than four characters, too short to keep out of page reads."
	}
	return secretFill{label: name, value: v, hide: map[string]string{name: v}}, ""
}

// fillSecret types the value into the field and masks it. The value is hidden by the
// filter before it is typed, so even a failure's words have it out.
func (d *Daemon) fillSecret(ctx context.Context, drive *browserDrive, fill secretFill, args map[string]json.RawMessage) ([]any, bool, string) {
	f := &d.browser.Filter
	for label, v := range fill.hide {
		f.Hide(label, v)
	}
	for label, v := range fill.codes {
		f.HideCode(label, v)
	}
	name, value := fill.label, fill.value
	field := map[string]json.RawMessage{"target": args["target"]}
	if e, ok := args["element"]; ok {
		field["element"] = e
	}
	typed := map[string]json.RawMessage{"text": rawString(value)}
	for k, v := range field {
		typed[k] = v
	}
	res, err := drive.call(ctx, "browser_type", typed)
	if err != nil {
		return fillWords("Nothing was filled: " + f.Text(err.Error()))
	}
	if res.IsError {
		return fillWords("Nothing was filled: " + f.Text(resultText(res)))
	}
	masked := map[string]json.RawMessage{"function": rawString(maskField)}
	for k, v := range field {
		masked[k] = v
	}
	if res, err := drive.call(ctx, "browser_evaluate", masked); err != nil || res.IsError || !evaluated(res, "agents-masked") {
		// A value that cannot be drawn as dots would show in a screenshot: take it out again.
		cleared := map[string]json.RawMessage{"text": rawString("")}
		for k, v := range field {
			cleared[k] = v
		}
		drive.call(ctx, "browser_type", cleared)
		return fillWords("Nothing was filled: " + name + " could not be hidden in that field, so it was taken out again.")
	}
	if submit := args["submit"]; string(submit) == "true" {
		pressed := map[string]json.RawMessage{"key": rawString("Enter")}
		if res, err := drive.call(ctx, "browser_press_key", pressed); err != nil || res.IsError {
			msg := name + " filled, but Enter was not pressed"
			if err == nil {
				msg += ": " + f.Text(resultText(res))
			}
			return fillWords(msg)
		}
	}
	note := name + " filled."
	if string(args["submit"]) == "true" {
		note = name + " filled, and Enter pressed."
	}
	return []any{map[string]any{"type": "text", "text": note}}, false, note
}

// browserRefusal is why a browser call may not go through while a value is filled, or "".
func (d *Daemon) browserRefusal(ctx context.Context, drive *browserDrive, name string, args map[string]json.RawMessage) string {
	f := &d.browser.Filter
	if !f.Hides() {
		return ""
	}
	if _, ok := args["filename"]; ok {
		return "Leave out filename while a secret is filled into this browser: a file would skip the filter that keeps it out of what you read."
	}
	switch name {
	case "browser_run_code_unsafe":
		return "browser_run_code_unsafe is refused while a secret is filled into this browser: code could read it. Use the other browser tools."
	case "browser_evaluate":
		check := map[string]json.RawMessage{"function": rawString(filledCheck)}
		if t, ok := args["target"]; ok {
			check["target"] = t
			if e, ok := args["element"]; ok {
				check["element"] = e
			}
		}
		// A check that fails says nothing: the agent's own call meets the same page.
		if res, err := drive.call(ctx, "browser_evaluate", check); err == nil && !res.IsError && evaluated(res, "agents-filled") {
			return "browser_evaluate is refused on a page with a secret filled in: a script could read it. It works again once the page navigates."
		}
	}
	return ""
}

// evaluated is whether browser_evaluate's result is word. Playwright says the result
// under "### Result" and then the code it ran, which has every word the function can say.
func evaluated(res *mcp.CallToolResult, word string) bool {
	return strings.Contains(resultText(res), "### Result\n\""+word+"\"")
}

// resultText is a result's text, all of it.
func resultText(res *mcp.CallToolResult) string {
	var texts []string
	for _, c := range res.Content {
		if t, ok := c.(*mcp.TextContent); ok {
			texts = append(texts, t.Text)
		}
	}
	return strings.Join(texts, "\n")
}

func rawString(s string) json.RawMessage {
	b, _ := json.Marshal(s)
	return b
}
