package controlplane

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"

	"github.com/alexec/agents/Go/internal/controlplane/hostinstall"
	"github.com/alexec/agents/Go/internal/controlplane/providers"
	"github.com/alexec/agents/Go/internal/controlplane/store"
	"github.com/alexec/agents/Go/wire"
)

// JSON-RPC as the daemon speaks it, enough for the control plane: it reads a request's
// id and method to tell its own from a host's, and passes every other line on as its
// bytes.

// Error codes: JSONRPCError's and DaemonAPI.Failure's.
const (
	parseError     = -32700
	invalidParams  = -32602
	methodNotFound = -32601
	internalError  = -32603

	notSupported         = -32009
	notPermitted         = -32045
	providersNeedOneCopy = -32064
	botMachine           = -32073
	hostOffline          = -32090
	noSuchHost           = -32091
	changedElsewhere     = -32093
	storeUnavailable     = -32094
	notKeeper            = -32101
)

// RPCError is JSONRPCError.
type RPCError struct {
	Code    int             `json:"code"`
	Message string          `json:"message"`
	Data    json.RawMessage `json:"data,omitempty"`
}

func (e *RPCError) Error() string { return fmt.Sprintf("%d %s", e.Code, e.Message) }

func fail(code int, format string, args ...any) *RPCError {
	return &RPCError{Code: code, Message: fmt.Sprintf(format, args...)}
}

// notFound is JSONRPCError.methodNotFound.
func notFound(method string) *RPCError {
	data, _ := json.Marshal(map[string]string{"method": method})
	return &RPCError{Code: methodNotFound, Message: "Method not found", Data: data}
}

// noSSHHere is a hosted copy's answer to a method that reaches a machine over ssh (#1807).
var noSSHHere = fail(notSupported, "This control plane runs on our servers, which have no ssh of yours. Add a machine with its join command or a code, or from a machine provider.")

// overSSH are the methods that reach a machine over this machine's ssh.
var overSSH = map[string]bool{"hosts/install": true, "hosts/detect": true, "hosts/sshHosts": true}

// ownersSSH are the methods that log in with this account's ssh: its config, agent and
// known_hosts. That ssh is the local owner's, so no other person, admin or not, uses it.
var ownersSSH = map[string]bool{"hosts/install": true, "hosts/detect": true, "hosts/sshHosts": true, "hosts/update": true}

// notOwnersSSH is the answer to another person who calls one of ownersSSH.
var notOwnersSSH = fail(notPermitted, "Only the control plane's owner can use its ssh. Add a machine with its join command or a code.")

// asRPC is what a client is told of an error: its own words for an RPCError, a store's
// for a store's (StoreError.rpcError), and an internal error for anything else.
func asRPC(err error) *RPCError {
	var e *RPCError
	if errors.As(err, &e) {
		return e
	}
	var workspace *providers.Failure
	if errors.As(err, &workspace) {
		return &RPCError{Code: workspace.Code, Message: workspace.Message, Data: workspace.Data}
	}
	var provider *providers.ProviderFailure
	if errors.As(err, &provider) {
		return &RPCError{Code: providers.CodeProviderFailed, Message: provider.Words}
	}
	var install *hostinstall.Failure
	if errors.As(err, &install) {
		return &RPCError{Code: install.Code, Message: install.Message}
	}
	var conflict *store.ConflictError
	if errors.As(err, &conflict) {
		return fail(changedElsewhere, "Someone changed that at the same time, so nothing was changed. Try again.")
	}
	var down *store.UnavailableError
	if errors.As(err, &down) {
		return fail(storeUnavailable, "The control plane can't reach where it keeps its records (%s). Nothing was changed.", down.Why)
	}
	return fail(internalError, "%v", err)
}

// message is one JSON-RPC line, read for its id and method.
type message struct {
	ID     json.RawMessage `json:"id,omitempty"`
	Method string          `json:"method,omitempty"`
	Params json.RawMessage `json:"params,omitempty"`
	Result json.RawMessage `json:"result,omitempty"`
	Error  json.RawMessage `json:"error,omitempty"`
}

// decode reads a line, with a machine/* or machines/* method under its old name (#2653).
func decode(line string) (*message, bool) {
	var m message
	if json.Unmarshal([]byte(line), &m) != nil {
		return nil, false
	}
	m.Method = wire.OldMethodName(m.Method)
	return &m, true
}

func (m *message) isRequest() bool { return m.Method != "" && len(m.ID) > 0 && string(m.ID) != "null" }

// idKey is an id as a map key: a number's digits, or a string with its quotes.
func idKey(raw json.RawMessage) string { return strings.TrimSpace(string(raw)) }

func reply(id json.RawMessage, result any) string {
	r, err := json.Marshal(result)
	if err != nil {
		return replyError(id, fail(internalError, "%v", err))
	}
	if id == nil {
		id = json.RawMessage("null")
	}
	return `{"id":` + string(id) + `,"jsonrpc":"2.0","result":` + string(r) + `}`
}

func replyError(id json.RawMessage, err error) string {
	b, _ := json.Marshal(asRPC(err))
	if id == nil {
		id = json.RawMessage("null")
	}
	return `{"error":` + string(b) + `,"id":` + string(id) + `,"jsonrpc":"2.0"}`
}

func notification(method string, params any) string {
	b, _ := json.Marshal(params)
	return `{"jsonrpc":"2.0","method":` + strconv.Quote(method) + `,"params":` + string(b) + `}`
}

func request(id, method string, params any) string {
	b, _ := json.Marshal(params)
	return `{"id":` + strconv.Quote(id) + `,"jsonrpc":"2.0","method":` + strconv.Quote(method) + `,"params":` + string(b) + `}`
}

// answeredID is the id of a reply, read at the top level only, or "" for anything else:
// every reply a host sends passes here, and a page of transcript is large (#167).
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

// require decodes params into T, or says they are not one, as ControlMethods.require.
func require[T any](params json.RawMessage, what string) (T, error) {
	var v T
	if len(params) == 0 || string(params) == "null" || json.Unmarshal(params, &v) != nil {
		return v, fail(invalidParams, "Those parameters are not a %s.", what)
	}
	return v, nil
}
