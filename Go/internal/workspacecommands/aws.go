package workspacecommands

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"io"
	"net/http"
	"net/url"
	"sort"
	"strings"
	"time"
)

// AWSSign is how a request to AWS is signed (#1345): Signature Version 4, for one service in
// one region, with the keys in the provider's secrets AWS_ACCESS_KEY_ID and
// AWS_SECRET_ACCESS_KEY, and AWS_SESSION_TOKEN when the keys are a role's.
type AWSSign struct {
	Service string
	Region  string
}

// The secrets a signed request reads.
const (
	AWSKeySecret     = "AWS_ACCESS_KEY_ID"
	AWSSecretSecret  = "AWS_SECRET_ACCESS_KEY"
	AWSSessionSecret = "AWS_SESSION_TOKEN"
)

// signAWS adds SigV4's headers to r, whose body is body, as at now. The query is written
// again in AWS's canonical form, so what is signed is what is sent.
func signAWS(r *http.Request, body []byte, s AWSSign, key, secret, session string, now time.Time) {
	stamp := now.UTC().Format("20060102T150405Z")
	day := stamp[:8]
	r.URL.RawQuery = canonicalQuery(r.URL.Query())
	r.Header.Set("X-Amz-Date", stamp)
	if session != "" {
		r.Header.Set("X-Amz-Security-Token", session)
	}
	names := []string{"host", "x-amz-date"}
	values := map[string]string{"host": r.URL.Host, "x-amz-date": stamp}
	if session != "" {
		names = append(names, "x-amz-security-token")
		values["x-amz-security-token"] = session
	}
	var headers strings.Builder
	for _, n := range names {
		headers.WriteString(n + ":" + values[n] + "\n")
	}
	signed := strings.Join(names, ";")
	path := r.URL.EscapedPath()
	if path == "" {
		path = "/"
	}
	hashed := sha256.Sum256(body)
	canonical := strings.Join([]string{r.Method, path, r.URL.RawQuery, headers.String(), signed,
		hex.EncodeToString(hashed[:])}, "\n")
	scope := day + "/" + s.Region + "/" + s.Service + "/aws4_request"
	canonicalHash := sha256.Sum256([]byte(canonical))
	toSign := "AWS4-HMAC-SHA256\n" + stamp + "\n" + scope + "\n" + hex.EncodeToString(canonicalHash[:])
	k := mac([]byte("AWS4"+secret), day)
	for _, part := range []string{s.Region, s.Service, "aws4_request"} {
		k = mac(k, part)
	}
	r.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+key+"/"+scope+", SignedHeaders="+signed+
		", Signature="+hex.EncodeToString(mac(k, toSign)))
}

func mac(key []byte, data string) []byte {
	h := hmac.New(sha256.New, key)
	h.Write([]byte(data))
	return h.Sum(nil)
}

// canonicalQuery is a query as SigV4 signs it: by name, then value, each escaped as RFC 3986
// says, a space as %20.
func canonicalQuery(q url.Values) string {
	var pairs []string
	for name, values := range q {
		for _, v := range values {
			pairs = append(pairs, awsEscape(name)+"="+awsEscape(v))
		}
	}
	sort.Strings(pairs)
	return strings.Join(pairs, "&")
}

func awsEscape(s string) string {
	var b strings.Builder
	for _, c := range []byte(s) {
		if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.' || c == '~' {
			b.WriteByte(c)
		} else {
			b.WriteString("%" + strings.ToUpper(hex.EncodeToString([]byte{c})))
		}
	}
	return b.String()
}

// xmlValue reads an XML answer, as AWS's Query APIs give, into the values a JSON answer
// has, so the same paths read it: the root element's content. An element with children is
// an object of them; a list (its children all <item>, or its name ending in Set, as EC2
// names them) is an array; anything else is its text.
func xmlValue(data []byte) (any, error) {
	d := xml.NewDecoder(bytes.NewReader(data))
	for {
		token, err := d.Token()
		if err != nil {
			return nil, err
		}
		if start, ok := token.(xml.StartElement); ok {
			return element(d, start.Name.Local)
		}
	}
}

func element(d *xml.Decoder, name string) (any, error) {
	type child struct {
		name  string
		value any
	}
	var children []child
	var text strings.Builder
	for {
		token, err := d.Token()
		if err == io.EOF {
			break
		}
		if err != nil {
			return nil, err
		}
		switch t := token.(type) {
		case xml.StartElement:
			v, err := element(d, t.Name.Local)
			if err != nil {
				return nil, err
			}
			children = append(children, child{t.Name.Local, v})
		case xml.CharData:
			text.Write(t)
		case xml.EndElement:
			list := strings.HasSuffix(name, "Set") && name != "Set"
			if len(children) > 0 {
				items := true
				for _, c := range children {
					items = items && c.name == "item"
				}
				list = list || items
			}
			if list {
				out := make([]any, len(children))
				for i, c := range children {
					out[i] = c.value
				}
				return out, nil
			}
			if len(children) == 0 {
				return strings.TrimSpace(text.String()), nil
			}
			out := map[string]any{}
			for _, c := range children {
				if _, taken := out[c.name]; !taken {
					out[c.name] = c.value
				}
			}
			return out, nil
		}
	}
	return nil, io.ErrUnexpectedEOF
}
