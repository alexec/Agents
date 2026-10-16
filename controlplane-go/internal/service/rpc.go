package service

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
)

// JSON-RPC as the daemon speaks it, enough for the control plane: it reads a request's id
// and method to tell its own from a host's, and passes every other line on as its bytes.

const (
	parseError     = -32700
	invalidParams  = -32602
	methodNotFound = -32601
	internalError  = -32603

	notSupported         = -32009
	notPermitted         = -32045
	hostOffline          = -32090
	noSuchHost           = -32091
	changedElsewhere     = -32093
	storeUnavailable     = -32094
	providersNeedOneCopy = -32064
)

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

func (e *rpcError) Error() string { return fmt.Sprintf("%d %s", e.Code, e.Message) }

func fail(code int, format string, args ...any) error {
	return &rpcError{Code: code, Message: fmt.Sprintf(format, args...)}
}

type message struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  json.RawMessage `json:"error,omitempty"`
}

func decode(line string) (*message, bool) {
	var m message
	if json.Unmarshal([]byte(line), &m) != nil {
		return nil, false
	}
	return &m, true
}

func (m *message) isRequest() bool { return m.Method != "" && len(m.ID) > 0 && string(m.ID) != "null" }

// idKey is an id as a map key: a number's digits, or a string with its quotes.
func idKey(raw json.RawMessage) string { return strings.TrimSpace(string(raw)) }

func reply(id json.RawMessage, result any) string {
	r, err := json.Marshal(result)
	if err != nil {
		return replyError(id, &rpcError{internalError, err.Error()})
	}
	if id == nil {
		id = json.RawMessage("null")
	}
	return `{"id":` + string(id) + `,"jsonrpc":"2.0","result":` + string(r) + `}`
}

func replyError(id json.RawMessage, err error) string {
	e, ok := err.(*rpcError)
	if !ok {
		e = &rpcError{internalError, err.Error()}
	}
	b, _ := json.Marshal(e)
	if id == nil {
		id = json.RawMessage("null")
	}
	return `{"error":` + string(b) + `,"id":` + string(id) + `,"jsonrpc":"2.0"}`
}

func notification(method string, params any) string {
	b, _ := json.Marshal(params)
	return `{"jsonrpc":"2.0","method":` + strconv.Quote(method) + `,"params":` + string(b) + `}`
}

func request(id string, method string, params any) string {
	b, _ := json.Marshal(params)
	return `{"id":` + id + `,"jsonrpc":"2.0","method":` + strconv.Quote(method) + `,"params":` + string(b) + `}`
}

// answeredID is the id of a reply, scanned at the top level only, or "" for anything
// else: every reply a host sends passes here, and a page of transcript is large (#167).
func answeredID(line string) string {
	var top map[string]json.RawMessage
	if json.Unmarshal([]byte(line), &top) != nil {
		return ""
	}
	if _, ok := top["method"]; ok {
		return ""
	}
	_, r := top["result"]
	_, e := top["error"]
	if !r && !e {
		return ""
	}
	return idKey(top["id"])
}
