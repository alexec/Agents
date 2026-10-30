package agentsd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// show_file, suggest_next_prompt and ask_question, as DaemonCore+AppTools answers them on the
// Swift host.

const (
	shownNote        = "Shown in the person's empty prompt. They may take it, edit it, or ignore it."
	shownLineLimit   = 10_000_000
	suggestionLabel  = 60
	suggestionPrompt = 2_000
)

func prefix(s string, n int) string {
	if r := []rune(s); len(r) > n {
		return string(r[:n])
	}
	return s
}

func isMarkdown(path string) bool {
	switch strings.ToLower(strings.TrimPrefix(filepath.Ext(path), ".")) {
	case "md", "markdown", "mdown", "mkd":
		return true
	}
	return false
}

// showFile is show_file: a file put in front of the person, in the files pane, and on the
// record as a card where it was called.
func (d *Daemon) showFile(id wire.UUID, args map[string]json.RawMessage) (string, error) {
	path := strings.TrimSpace(argString(args, "path"))
	if !strings.HasPrefix(path, "/") {
		return "", Invalid("No file was shown: `path` has to be an absolute path, starting at `/`.")
	}
	file := wire.ShownFile{Path: filepath.Clean(path)}
	if n, ok := argInt(args, "line"); ok && n >= 1 && n <= shownLineLimit {
		line := int64(n)
		file.Line = &line
	}
	var chart struct {
		Mark, X, Y, Color string
		Title             *string
	}
	if raw, ok := args["chart"]; ok && json.Unmarshal(raw, &chart) == nil {
		x, y := strings.TrimSpace(chart.X), strings.TrimSpace(chart.Y)
		if x != "" && y != "" {
			mark := wire.ChartMark(strings.ToLower(chart.Mark))
			switch mark {
			case "bar", "line", "point", "area":
			default:
				mark = "bar"
			}
			hint := wire.ChartHint{Mark: mark, X: x, Y: y, Title: chart.Title}
			if c := strings.TrimSpace(chart.Color); c != "" {
				hint.Color = &c
			}
			file.Chart = &hint
		}
	}
	a := d.Store.Agent(id)
	if a == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so the file was not shown."}
	}
	folders := []string{store.FolderPath(a.Cwd)}
	for _, f := range a.AdditionalDirectories {
		folders = append(folders, store.FolderPath(f))
	}
	if !inScope(file.Path, folders) {
		return "", Invalid("Outside this agent's folders (%s)", strings.Join(folders, ", "))
	}
	st, err := os.Stat(file.Path)
	exists := err == nil
	if !exists {
		// A Markdown page may be shown before its first write, in a folder that is there.
		if fi, err := os.Stat(filepath.Dir(file.Path)); !isMarkdown(file.Path) || err != nil || !fi.IsDir() {
			return "", Invalid("There is no file at %s.", file.Path)
		}
	} else if st.IsDir() {
		return "", Invalid("%s is a folder, and this shows a file.", file.Path)
	}
	d.mu.Lock()
	windows := len(d.clients)
	d.mu.Unlock()
	if windows == 0 {
		return "", &Error{Code: CodeNoSuchAgent, Message: "No window is open, so there was nowhere to show it."}
	}
	Broadcast(d, wire.NotifyAgentShowFile, wire.ShowFileNotification{AgentID: id, File: file})
	d.record(id, wire.TranscriptEntryKind{FileShown: &wire.TranscriptEntryKindFileShown{Value: file}})
	// A file nobody has in front of them yet is a mark on the row until they look (#1802):
	// ending 2, "I have something for you", never Needs you.
	if !d.watched(id) {
		d.change(id, func(a *wire.Agent) { a.FileToSee = &file })
	}
	d.live(id).noteShown()
	name := filepath.Base(file.Path)
	if !exists {
		return name + " is open, empty, in the files pane beside this conversation, and will fill as you write it. " +
			"Just write; do not paste the file back.", nil
	}
	place := ""
	if file.Line != nil {
		place = " at line " + strconv.FormatInt(*file.Line, 10)
	}
	return name + " is open" + place + " in the files pane beside this conversation. Say what they are looking at; do not paste the file back.", nil
}

// suggestNextPrompt is suggest_next_prompt: one suggestion, in the person's empty prompt.
func (d *Daemon) suggestNextPrompt(id wire.UUID, args map[string]json.RawMessage) (string, error) {
	label, prompt := strings.TrimSpace(argString(args, "label")), strings.TrimSpace(argString(args, "prompt"))
	if label == "" || prompt == "" {
		return "", Invalid("Nothing was suggested: send a non-empty `label` and `prompt`.")
	}
	if d.Store.Agent(id) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so the suggestions were not shown."}
	}
	if d.live(id).asking() {
		return "", Invalid("Nothing was suggested: you have a question waiting to be answered.")
	}
	s := wire.SuggestedPrompt{ID: store.NewUUID(), Label: prefix(label, suggestionLabel), Prompt: prefix(prompt, suggestionPrompt)}
	d.change(id, func(a *wire.Agent) { a.SuggestedPrompts = []wire.SuggestedPrompt{s} })
	return shownNote, nil
}

// hangUp is hang_up (#2375): the person said they were done talking, so the client in
// voice mode on this chat says the reply and turns voice mode off.
func (d *Daemon) hangUp(id wire.UUID, _ map[string]json.RawMessage) (string, error) {
	t := now()
	if d.change(id, func(a *wire.Agent) { a.VoiceHungUpAt = &t }) == nil {
		return "", &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more."}
	}
	return "Voice mode ends once your reply has been said. Keep the goodbye short.", nil
}

// asker is the agent's live self, when it may ask the person: its conversation open, and a
// turn of its own running. notWorking is what it is told when no turn is.
func (d *Daemon) asker(id wire.UUID, notWorking string) (*live, error) {
	if d.Store.Agent(id) == nil {
		return nil, &Error{Code: CodeNoSuchAgent, Message: "That conversation is not open any more, so nobody was asked."}
	}
	l := d.live(id)
	l.mu.Lock()
	inTurn := l.inTurn
	l.mu.Unlock()
	if !inTurn {
		return nil, &Error{Code: -32600, Message: notWorking}
	}
	return l, nil
}

// askQuestion is ask_question: the person asked, as a form held like the runtime's own, and the
// call answered with what they said.
func (d *Daemon) askQuestion(id wire.UUID, args map[string]json.RawMessage) (string, error) {
	title := strings.TrimSpace(argString(args, "title"))
	var raw []struct {
		ID            string `json:"id"`
		Prompt        string `json:"prompt"`
		AllowMultiple *bool  `json:"allow_multiple"`
		Options       []struct {
			ID    string  `json:"id"`
			Label *string `json:"label"`
		} `json:"options"`
	}
	if json.Unmarshal(args["questions"], &raw) != nil || len(raw) == 0 {
		return "", Invalid("Nothing was asked: send at least one question in `questions`.")
	}
	var props []wire.ElicitationSchemaProperty
	for _, q := range raw {
		qid, prompt := strings.TrimSpace(q.ID), strings.TrimSpace(q.Prompt)
		if qid == "" || prompt == "" {
			return "", Invalid("Nothing was asked: each question needs an `id` and a `prompt`.")
		}
		var choices []wire.ElicitationSchemaPropertyChoice
		for _, o := range q.Options {
			if v := strings.TrimSpace(o.ID); v != "" {
				t := v
				if o.Label != nil {
					t = *o.Label
				}
				choices = append(choices, wire.ElicitationSchemaPropertyChoice{Value: v, Title: t})
			}
		}
		p := wire.ElicitationSchemaProperty{Name: qid, Title: &prompt, IsRequired: true}
		switch {
		case len(choices) == 0:
			p.Kind = wire.ElicitationSchemaPropertyKind{String: &wire.ElicitationSchemaPropertyKindString{}}
		case q.AllowMultiple != nil && *q.AllowMultiple:
			p.Kind = wire.ElicitationSchemaPropertyKind{MultiSelect: &wire.ElicitationSchemaPropertyKindMultiSelect{Items: choices}}
		default:
			p.Kind = wire.ElicitationSchemaPropertyKind{String: &wire.ElicitationSchemaPropertyKindString{Choices: choices}}
		}
		props = append(props, p)
	}
	l, err := d.asker(id, "A question can only be asked while this agent is working.")
	if err != nil {
		return "", err
	}
	schema := wire.ElicitationSchema{Properties: props}
	var message *string
	if title != "" {
		schema.Title = &title
		message = &title
	} else if len(props) == 1 {
		message = props[0].Title
	}
	req := wire.ElicitationRequest{ID: store.NewUUID(), AgentID: id, Message: message,
		Mode: wire.ElicitationRequestMode{Form: &wire.ElicitationRequestModeForm{Value: schema}}, Scope: wire.ElicitationRequestScopeSession,
		AskedAt: now()}
	r, answered := l.holdAskedForm(req)
	if !answered {
		return formStillOpen, nil
	}
	var said []wire.ElicitationAnswer
	if r.action == wire.AnswerElicitationRequestActionAccept {
		said = answers(schema, r.content, message)
	}
	return askQuestionNote(r.action, said), nil
}
