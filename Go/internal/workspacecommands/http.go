package workspacecommands

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

// Request is an HTTP action (#1119): what the command provider does in place of a shell
// command, for a provider whose API it can call with nothing installed. Each part is a
// template. The URL and the body take the workspace's values. Only a header takes a
// secret, from the environment, so a token is never in a URL, a log or an error.
type Request struct {
	Method string
	// URL is the whole address; each value filled into it is escaped as one path segment
	// or query value.
	URL string
	// Headers are filled from the environment (the provider's secrets), then the values.
	Headers map[string]string
	// Body is JSON, sent when not nil: each string in it has the values filled in.
	Body any
	// Answer is "xml" for an API that answers XML (AWS's Query APIs), read into the same
	// values as JSON; "" for JSON.
	Answer string
	// Sign, when set, signs the request for AWS with the AWS_* secrets (#1345).
	Sign *AWSSign
	// Google, when set, authorises the request with a token from the service account key
	// in GOOGLE_SERVICE_ACCOUNT_KEY (#1346).
	Google *GoogleAuth
}

// Said is the request as a log or an error says it: its method and its URL as written.
func (r Request) Said() string { return r.Method + " " + r.URL }

// needs is the secrets its headers name: the ${NAME}s that are not values.
func (r Request) needs(values map[string]string) []string {
	var names []string
	for _, header := range r.Headers {
		rest := header
		for {
			open := strings.Index(rest, "${")
			if open < 0 {
				break
			}
			closing := strings.IndexByte(rest[open+2:], '}')
			if closing < 0 {
				break
			}
			name := rest[open+2 : open+2+closing]
			if _, isValue := values[name]; !isValue && !contains(names, name) {
				names = append(names, name)
			}
			rest = rest[open+2+closing+1:]
		}
	}
	return names
}

// Fetcher does one request within a deadline: its status and body.
type Fetcher func(r *http.Request, deadline time.Duration) (int, []byte, error)

// Fetch is the standard Fetcher: Go's own client, a body read up to a megabyte, and no
// redirect followed, so a header carrying a token never goes to another address.
func Fetch(r *http.Request, deadline time.Duration) (int, []byte, error) {
	ctx, cancel := context.WithTimeout(r.Context(), deadline)
	defer cancel()
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	response, err := client.Do(r.WithContext(ctx))
	if err != nil {
		return 0, nil, err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, outputLimit))
	return response.StatusCode, body, err
}

// Environment looks up a secret the control plane passed; os.LookupEnv when nil.
type Environment func(string) (string, bool)

// call does the request with the values filled in, and answers its body when the provider
// said yes. doing is what the person reads in a failure, such as "starting devbox".
func (p *Provider) call(r Request, values map[string]string, deadline time.Duration, doing string) ([]byte, error) {
	lookup := p.Env
	if lookup == nil {
		lookup = os.LookupEnv
	}
	secrets := map[string]string{}
	needed := r.needs(values)
	if r.Sign != nil {
		needed = append(needed, AWSKeySecret, AWSSecretSecret)
	}
	if r.Google != nil {
		needed = append(needed, GoogleSecret)
	}
	for _, name := range needed {
		value, ok := lookup(name)
		if !ok || value == "" {
			return nil, Failure{"It needs the " + name + " secret."}
		}
		secrets[name] = value
	}
	address := fillEscaped(r.URL, values)
	parsed, err := url.Parse(address)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
		return nil, Failure{"Its address isn't a web address: " + r.URL}
	}
	var body io.Reader
	var data []byte
	if r.Body != nil {
		data, err = json.Marshal(fillBody(r.Body, values))
		if err != nil {
			return nil, Failure{"Its request body isn't JSON."}
		}
		body = bytes.NewReader(data)
	}
	request, err := http.NewRequest(r.Method, address, body)
	if err != nil {
		return nil, Failure{"Its request can't be made: " + r.Said()}
	}
	request.Header.Set("Accept", "application/json")
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	for name, template := range r.Headers {
		request.Header.Set(name, Fill(Fill(template, secrets, false), values, false))
	}
	if r.Google != nil {
		token, err := p.googleToken(secrets[GoogleSecret], r.Google.Scope, deadline)
		if err != nil {
			return nil, err
		}
		request.Header.Set("Authorization", "Bearer "+token)
	}
	if r.Sign != nil {
		session, _ := lookup(AWSSessionSecret)
		signAWS(request, data, *r.Sign, secrets[AWSKeySecret], secrets[AWSSecretSecret], session, time.Now())
	}
	fetch := p.Fetch
	if fetch == nil {
		fetch = Fetch
	}
	status, answer, err := fetch(request, deadline)
	if err != nil {
		if errors.Is(err, context.DeadlineExceeded) {
			return nil, Failure{strings.ToUpper(doing[:1]) + doing[1:] + " took longer than " + words(deadline) + "."}
		}
		// Go's words name the address and the method, never a header.
		return nil, Failure{"It can't be reached: " + parsed.Host + "."}
	}
	if status < 200 || status > 299 {
		return nil, Failure{refusal(status, answer, parsed.Host)}
	}
	return answer, nil
}

// value is an answer read as the request says: JSON, or XML.
func (r Request) value(answer []byte) (any, error) {
	if r.Answer == "xml" {
		return xmlValue(answer)
	}
	return decode(answer)
}

// refusal is a provider's no in its own words: the message its JSON gives, cut at 1 KB.
func refusal(status int, answer []byte, host string) string {
	said := ""
	value, err := decode(answer)
	if err != nil {
		value, err = xmlValue(answer)
	}
	if err == nil {
		// JSON's message, or AWS's XML <Errors><Error><Message>.
		for _, path := range []string{"message", "detail", "error.message", "error", "Errors.Error.Message", "Error.Message", "Message"} {
			if text, ok := PathText(path, value); ok && strings.TrimSpace(text) != "" {
				said = strings.TrimSpace(text)
				break
			}
		}
	}
	text := fmt.Sprintf("%s answered %d", host, status)
	if said != "" {
		text += ": " + said
	}
	if !strings.HasSuffix(text, ".") && !strings.HasSuffix(text, "!") && !strings.HasSuffix(text, "?") {
		text += "."
	}
	if status == http.StatusUnauthorized || status == http.StatusForbidden {
		text += " Check its secrets, and what the token or key may do."
	}
	if len(text) > 1024 {
		text = strings.ToValidUTF8(text[:1024], "")
	}
	return text
}

// fillEscaped is Fill for an address: each value escaped as one path segment, or after the
// ? as one query value.
func fillEscaped(template string, values map[string]string) string {
	path, query, hasQuery := strings.Cut(template, "?")
	inPath := make(map[string]string, len(values))
	inQuery := make(map[string]string, len(values))
	for k, v := range values {
		inPath[k] = url.PathEscape(v)
		inQuery[k] = url.QueryEscape(v)
	}
	if !hasQuery {
		return Fill(path, inPath, false)
	}
	return Fill(path, inPath, false) + "?" + Fill(query, inQuery, false)
}

// fillBody is a JSON template with the values filled into each string in it.
func fillBody(template any, values map[string]string) any {
	switch t := template.(type) {
	case string:
		return Fill(t, values, false)
	case []any:
		out := make([]any, len(t))
		for i, v := range t {
			out[i] = fillBody(v, values)
		}
		return out
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, v := range t {
			out[k] = fillBody(v, values)
		}
		return out
	}
	return template
}

// requestFrom reads a request written in a configuration: {method, url, headers, body}.
func requestFrom(value any, what string) (*Request, error) {
	o, ok := value.(map[string]any)
	if !ok {
		return nil, ConfigError(what + " must be a command or a request")
	}
	address, _ := o["url"].(string)
	if address == "" {
		return nil, ConfigError(what + " needs a url")
	}
	if parsed, err := url.Parse(address); err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") {
		return nil, ConfigError(what + ".url must start with https://")
	}
	method, _ := o["method"].(string)
	if method == "" {
		method = http.MethodGet
	}
	method = strings.ToUpper(method)
	r := &Request{Method: method, URL: address, Headers: map[string]string{}, Body: o["body"]}
	if answer, ok := o["answer"].(string); ok {
		if answer != "json" && answer != "xml" {
			return nil, ConfigError(what + ".answer must be json or xml")
		}
		if answer == "xml" {
			r.Answer = answer
		}
	}
	if google, present := o["googleAuth"]; present {
		given, _ := google.(map[string]any)
		scope, _ := given["scope"].(string)
		if scope == "" {
			return nil, ConfigError(what + ".googleAuth needs a scope")
		}
		r.Google = &GoogleAuth{Scope: scope}
	}
	if sign, present := o["awsSign"]; present {
		given, _ := sign.(map[string]any)
		service, _ := given["service"].(string)
		region, _ := given["region"].(string)
		if service == "" || region == "" {
			return nil, ConfigError(what + ".awsSign needs service and region")
		}
		r.Sign = &AWSSign{Service: service, Region: region}
	}
	if headers, present := o["headers"]; present {
		given, ok := headers.(map[string]any)
		if !ok {
			return nil, ConfigError(what + ".headers must map names to values")
		}
		for name, value := range given {
			text, ok := value.(string)
			if !ok {
				return nil, ConfigError(what + ".headers." + name + " must be text")
			}
			r.Headers[name] = text
		}
	}
	return r, nil
}
