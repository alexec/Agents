package agentsd

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Forms as Elicitation.swift reads, checks and words them: ElicitationRequest(wire:),
// ElicitationSchema(wire:), Property.problem(with:) and ElicitationSchema.answers.

// value is a JSON value read with its numbers kept as written, so an integer is told from
// a number as Swift's JSONValue tells .int from .double.
func value(raw []byte) any {
	if len(raw) == 0 {
		return nil
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber()
	var v any
	if dec.Decode(&v) != nil {
		return nil
	}
	return v
}

func object(v any) map[string]any { m, _ := v.(map[string]any); return m }
func array(v any) []any           { a, _ := v.([]any); return a }

func text(v any) (string, bool) { s, ok := v.(string); return s, ok }

func textPointer(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}

// integer is JSONValue.intValue: a whole number as written.
func integer(v any) (int64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	i, err := strconv.ParseInt(string(n), 10, 64)
	return i, err == nil
}

func integerPointer(v any) *int64 {
	if i, ok := integer(v); ok {
		return &i
	}
	return nil
}

func double(v any) (float64, bool) {
	n, ok := v.(json.Number)
	if !ok {
		return 0, false
	}
	f, err := n.Float64()
	return f, err == nil
}

func doublePointer(v any) *float64 {
	if f, ok := double(v); ok {
		return &f
	}
	return nil
}

// parseElicitation is ElicitationRequest(wire:): a link when it names a url, a form when
// its schema can be drawn, and false otherwise, which is a decline rather than half an
// answer.
func parseElicitation(raw json.RawMessage, agentID wire.UUID) (wire.ElicitationRequest, bool) {
	w := object(value(raw))
	if w == nil {
		return wire.ElicitationRequest{}, false
	}
	var mode wire.ElicitationRequestMode
	if u, ok := text(w["url"]); ok {
		mode.URL = &wire.ElicitationRequestModeURL{Value: u}
	} else if schema, ok := parseSchema(w["requestedSchema"]); ok {
		mode.Form = &wire.ElicitationRequestModeForm{Value: schema}
	} else {
		return wire.ElicitationRequest{}, false
	}
	// Tied to a session, unless it names the request it belongs to.
	scope := wire.ElicitationRequestScopeSession
	if _, ok := w["requestId"]; ok {
		scope = wire.ElicitationRequestScopeRequest
	}
	return wire.ElicitationRequest{ID: store.NewUUID(), ElicitationID: textPointer(w["elicitationId"]), AgentID: agentID,
		Message: textPointer(w["message"]), Mode: mode, Scope: scope, AskedAt: now()}, true
}

func parseSchema(v any) (wire.ElicitationSchema, bool) {
	w := object(v)
	props := object(w["properties"])
	if props == nil {
		return wire.ElicitationSchema{}, false
	}
	required := map[string]bool{}
	for _, r := range array(w["required"]) {
		if s, ok := text(r); ok {
			required[s] = true
		}
	}
	// The schema's own order where it gives one, and by name otherwise.
	var names []string
	for _, n := range array(w["propertyOrder"]) {
		if s, ok := text(n); ok {
			names = append(names, s)
		}
	}
	if len(names) == 0 {
		for n := range props {
			names = append(names, n)
		}
		sort.Strings(names)
	}
	var properties []wire.ElicitationSchemaProperty
	for _, name := range names {
		p, ok := parseProperty(name, props[name], required[name])
		if !ok {
			return wire.ElicitationSchema{}, false // one we cannot draw: the whole form
		}
		properties = append(properties, p)
	}
	if len(properties) == 0 {
		return wire.ElicitationSchema{}, false
	}
	return wire.ElicitationSchema{Title: textPointer(w["title"]), Description: textPointer(w["description"]),
		Properties: properties}, true
}

var formats = map[string]wire.ElicitationSchemaPropertyFormat{
	"email": wire.ElicitationSchemaPropertyFormatEmail, "uri": wire.ElicitationSchemaPropertyFormatURI,
	"date": wire.ElicitationSchemaPropertyFormatDate, "date-time": wire.ElicitationSchemaPropertyFormatDateTime,
}

func parseProperty(name string, v any, required bool) (wire.ElicitationSchemaProperty, bool) {
	w := object(v)
	if w == nil {
		return wire.ElicitationSchemaProperty{}, false
	}
	var kind wire.ElicitationSchemaPropertyKind
	kindName, _ := text(w["type"])
	switch kindName {
	case "string":
		k := &wire.ElicitationSchemaPropertyKindString{MinLength: integerPointer(w["minLength"]),
			MaxLength: integerPointer(w["maxLength"])}
		if f, ok := text(w["format"]); ok {
			if format, known := formats[f]; known {
				k.Format = &format
			}
		}
		choices := w["enum"]
		if choices == nil {
			choices = w["oneOf"]
		}
		k.Choices = parseChoices(choices)
		kind.String = k
	case "number":
		kind.Number = &wire.ElicitationSchemaPropertyKindNumber{Minimum: doublePointer(w["minimum"]), Maximum: doublePointer(w["maximum"])}
	case "integer":
		kind.Integer = &wire.ElicitationSchemaPropertyKindInteger{Minimum: integerPointer(w["minimum"]), Maximum: integerPointer(w["maximum"])}
	case "boolean":
		kind.Boolean = &struct{}{}
	case "array":
		// Titled choices under items.anyOf, bare ones under items.enum, or the items
		// themselves a plain list.
		items := w["items"]
		var list any = items
		if m := object(items); m != nil {
			if m["enum"] != nil {
				list = m["enum"]
			} else if m["anyOf"] != nil {
				list = m["anyOf"]
			}
		}
		choices := parseChoices(list)
		if choices == nil {
			return wire.ElicitationSchemaProperty{}, false
		}
		kind.MultiSelect = &wire.ElicitationSchemaPropertyKindMultiSelect{Items: choices,
			MinItems: integerPointer(w["minItems"]), MaxItems: integerPointer(w["maxItems"])}
	default:
		return wire.ElicitationSchemaProperty{}, false
	}
	p := wire.ElicitationSchemaProperty{Name: name, Title: textPointer(w["title"]), Description: textPointer(w["description"]),
		IsRequired: required, Kind: kind}
	if d, ok := w["default"]; ok {
		p.DefaultValue, _ = json.Marshal(d)
	}
	return p, true
}

func parseChoices(v any) []wire.ElicitationSchemaPropertyChoice {
	entries := array(v)
	var choices []wire.ElicitationSchemaPropertyChoice
	for _, e := range entries {
		if plain, ok := text(e); ok {
			choices = append(choices, wire.ElicitationSchemaPropertyChoice{Value: plain, Title: plain})
			continue
		}
		m := object(e)
		// A titled option names its value const; value is the older MCP spelling.
		val, ok := text(m["const"])
		if !ok {
			if val, ok = text(m["value"]); !ok {
				continue
			}
		}
		title := val
		if t, ok := text(m["title"]); ok {
			title = t
		}
		choices = append(choices, wire.ElicitationSchemaPropertyChoice{Value: val, Title: title, Description: textPointer(m["description"])})
	}
	return choices
}

func elicitationTitle(r wire.ElicitationRequest) string {
	if r.Mode.Form != nil {
		if r.Mode.Form.Value.Title != nil {
			return *r.Mode.Form.Value.Title
		}
		if r.Message != nil {
			return *r.Message
		}
		return "The agent needs something"
	}
	return "The agent wants you to open a page"
}

func propertyName(p wire.ElicitationSchemaProperty) string {
	if p.Title != nil {
		return *p.Title
	}
	return p.Name
}

func hasChoice(choices []wire.ElicitationSchemaPropertyChoice, v string) bool {
	for _, c := range choices {
		if c.Value == v {
			return true
		}
	}
	return false
}

// formatNumber is Swift's Double description for the bounds in a message: 3.0, 2.5.
func formatNumber(f float64) string {
	s := strconv.FormatFloat(f, 'f', -1, 64)
	if !strings.Contains(s, ".") {
		s += ".0"
	}
	return s
}

// problem is Property.problem(with:): why this value will not do, or "".
func problem(p wire.ElicitationSchemaProperty, raw wire.JSONValue) string {
	v := value(raw)
	missing := v == nil
	if s, ok := v.(string); ok && s == "" {
		missing = true
	}
	if a, ok := v.([]any); ok && len(a) == 0 {
		missing = true
	}
	if missing {
		if p.IsRequired {
			return propertyName(p) + " is needed"
		}
		return ""
	}
	k := p.Kind
	switch {
	case k.String != nil:
		s, ok := text(v)
		if !ok {
			return p.Name + " must be text"
		}
		n := int64(utf8.RuneCountInString(s))
		if k.String.MinLength != nil && n < *k.String.MinLength {
			return fmt.Sprintf("At least %d characters", *k.String.MinLength)
		}
		if k.String.MaxLength != nil && n > *k.String.MaxLength {
			return fmt.Sprintf("At most %d characters", *k.String.MaxLength)
		}
		if k.String.Choices != nil && !hasChoice(k.String.Choices, s) {
			return "Not one of the choices"
		}
		if k.String.Format != nil && !matches(*k.String.Format, s) {
			return "Not a " + string(*k.String.Format)
		}
	case k.Number != nil:
		f, ok := double(v)
		if !ok {
			return p.Name + " must be a number"
		}
		if k.Number.Minimum != nil && f < *k.Number.Minimum {
			return "At least " + formatNumber(*k.Number.Minimum)
		}
		if k.Number.Maximum != nil && f > *k.Number.Maximum {
			return "At most " + formatNumber(*k.Number.Maximum)
		}
	case k.Integer != nil:
		i, ok := integer(v)
		if !ok {
			return p.Name + " must be a whole number"
		}
		if k.Integer.Minimum != nil && i < *k.Integer.Minimum {
			return fmt.Sprintf("At least %d", *k.Integer.Minimum)
		}
		if k.Integer.Maximum != nil && i > *k.Integer.Maximum {
			return fmt.Sprintf("At most %d", *k.Integer.Maximum)
		}
	case k.Boolean != nil:
		if _, ok := v.(bool); !ok {
			return p.Name + " must be yes or no"
		}
	case k.MultiSelect != nil:
		list, ok := v.([]any)
		if !ok {
			return p.Name + " must be a list"
		}
		var chosen []string
		for _, e := range list {
			if s, ok := text(e); ok {
				chosen = append(chosen, s)
			}
		}
		m := k.MultiSelect
		if m.MinItems != nil && int64(len(chosen)) < *m.MinItems {
			return fmt.Sprintf("Choose at least %d", *m.MinItems)
		}
		if m.MaxItems != nil && int64(len(chosen)) > *m.MaxItems {
			return fmt.Sprintf("Choose at most %d", *m.MaxItems)
		}
		for _, c := range chosen {
			if !hasChoice(m.Items, c) {
				return "Not one of the choices"
			}
		}
	}
	return ""
}

// matches is deliberately loose: the agent checks its own input; this keeps the form from
// sending something obviously wrong.
func matches(f wire.ElicitationSchemaPropertyFormat, s string) bool {
	switch f {
	case wire.ElicitationSchemaPropertyFormatEmail:
		parts := strings.Split(s, "@")
		return len(parts) == 2 && parts[0] != "" && strings.Contains(parts[1], ".")
	case wire.ElicitationSchemaPropertyFormatURI:
		u, err := url.Parse(s)
		return err == nil && u.Scheme != ""
	case wire.ElicitationSchemaPropertyFormatDate:
		return len(s) == 10 && timestamp(s+"T00:00:00Z")
	case wire.ElicitationSchemaPropertyFormatDateTime:
		return timestamp(s)
	}
	return true
}

// timestamp is ACP.timestamp(from:): ISO 8601, with or without fractional seconds.
func timestamp(s string) bool {
	_, err := time.Parse(time.RFC3339Nano, s)
	return err == nil
}

func problems(s wire.ElicitationSchema, content map[string]wire.JSONValue) []string {
	var out []string
	for _, p := range s.Properties {
		if why := problem(p, content[p.Name]); why != "" {
			out = append(out, why)
		}
	}
	return out
}

// isNote is Property.isNote(on:): the free-text box belonging to the question before it
// (question_0_custom beside question_0).
func isNote(p, previous wire.ElicitationSchemaProperty) bool {
	k := p.Kind.String
	return !p.IsRequired && strings.HasPrefix(p.Name, previous.Name+"_") && k != nil &&
		k.Format == nil && k.MinLength == nil && k.MaxLength == nil && k.Choices == nil
}

func pages(s wire.ElicitationSchema) [][]wire.ElicitationSchemaProperty {
	var out [][]wire.ElicitationSchemaProperty
	for _, p := range s.Properties {
		if n := len(out); n > 0 && isNote(p, out[n-1][len(out[n-1])-1]) {
			out[n-1] = append(out[n-1], p)
		} else {
			out = append(out, []wire.ElicitationSchemaProperty{p})
		}
	}
	return out
}

// words is the value as the card drew it: a choice's title, Yes or No.
func words(p wire.ElicitationSchemaProperty, raw wire.JSONValue) []string {
	v := value(raw)
	if v == nil {
		return nil
	}
	k := p.Kind
	switch {
	case k.String != nil:
		s, ok := text(v)
		if !ok || s == "" {
			return nil
		}
		for _, c := range k.String.Choices {
			if c.Value == s {
				return []string{c.Title}
			}
		}
		return []string{s}
	case k.MultiSelect != nil:
		var out []string
		for _, e := range array(v) {
			s, ok := text(e)
			if !ok {
				continue
			}
			word := s
			for _, c := range k.MultiSelect.Items {
				if c.Value == s {
					word = c.Title
				}
			}
			out = append(out, word)
		}
		return out
	case k.Boolean != nil:
		if b, ok := v.(bool); ok {
			if b {
				return []string{"Yes"}
			}
			return []string{"No"}
		}
		return nil
	default:
		if i, ok := integer(v); ok {
			return []string{strconv.FormatInt(i, 10)}
		}
		if f, ok := double(v); ok {
			return []string{strconv.FormatFloat(f, 'f', -1, 64)}
		}
		if s, ok := text(v); ok {
			return []string{s}
		}
		return nil
	}
}

// answers is ElicitationSchema.answers: what was asked and said, one line a page.
func answers(s wire.ElicitationSchema, content map[string]wire.JSONValue, message *string) []wire.ElicitationAnswer {
	ps := pages(s)
	var out []wire.ElicitationAnswer
	for _, page := range ps {
		var said []string
		for _, p := range page {
			said = append(said, words(p, content[p.Name])...)
		}
		if len(said) == 0 {
			continue
		}
		first := page[0]
		var question string
		switch {
		case first.Title != nil:
			question = *first.Title
		case len(ps) == 1 && message != nil:
			question = *message
		case first.Description != nil:
			question = *first.Description
		default:
			question = first.Name
		}
		out = append(out, wire.ElicitationAnswer{Question: question, Answer: strings.Join(said, ", ")})
	}
	return out
}

func outcomeSummary(action wire.AnswerElicitationRequestAction) string {
	switch action {
	case wire.AnswerElicitationRequestActionAccept:
		return "You answered the agent's form"
	case wire.AnswerElicitationRequestActionDecline:
		return "You declined the agent's form"
	}
	return "The form was closed"
}

// askQuestionNote is DaemonCore.askQuestionNote: the words an agent reads for an answer.
func askQuestionNote(action wire.AnswerElicitationRequestAction, said []wire.ElicitationAnswer) string {
	switch action {
	case wire.AnswerElicitationRequestActionAccept:
		if len(said) == 0 {
			return "They sent an empty answer."
		}
		lines := []string{"They answered:"}
		for _, a := range said {
			lines = append(lines, "- "+a.Question+": "+a.Answer)
		}
		return strings.Join(lines, "\n")
	case wire.AnswerElicitationRequestActionDecline:
		return "They skipped the questions."
	}
	return "They cancelled."
}
