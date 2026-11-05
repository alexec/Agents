package whatsappmcp

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"
)

// Meta is the Cloud API's one call the server makes, POST /<phone number id>/messages, with Go's
// own HTTP client: it sends a message (text, buttons, a list or a template) and marks one read.
// The account is read at each call, so a token saved after the server started is used.
type Meta struct {
	Account func() (Account, error)
	// HTTP is the client; a two-minute one when nil.
	HTTP *http.Client
}

var defaultClient = &http.Client{Timeout: 2 * time.Minute}

// Send sends one message to a person and gives its id (wamid.…).
func (m *Meta) Send(ctx context.Context, message map[string]any) (string, error) {
	message["messaging_product"] = "whatsapp"
	message["recipient_type"] = "individual"
	var answer struct {
		Messages []struct {
			ID string `json:"id"`
		} `json:"messages"`
	}
	if err := m.post(ctx, message, &answer); err != nil {
		return "", err
	}
	if len(answer.Messages) == 0 || answer.Messages[0].ID == "" {
		return "", errors.New("WhatsApp took the message but gave no id for it")
	}
	return answer.Messages[0].ID, nil
}

// MarkRead marks a message a person sent as read: they see two blue ticks.
func (m *Meta) MarkRead(ctx context.Context, id string) error {
	return m.post(ctx, map[string]any{"messaging_product": "whatsapp", "status": "read", "message_id": id}, nil)
}

func (m *Meta) post(ctx context.Context, body map[string]any, into any) error {
	a, err := m.Account()
	if err != nil {
		return err
	}
	data, err := json.Marshal(body)
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, a.APIURL+"/"+a.PhoneNumberID+"/messages", bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+a.Token)
	req.Header.Set("Content-Type", "application/json")
	client := m.HTTP
	if client == nil {
		client = defaultClient
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("WhatsApp: %w", err)
	}
	defer func() { _ = resp.Body.Close() }()
	got, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return fmt.Errorf("WhatsApp: %w", err)
	}
	if resp.StatusCode/100 != 2 {
		return apiError(resp.StatusCode, got)
	}
	if into != nil && json.Unmarshal(got, into) != nil {
		return fmt.Errorf("WhatsApp gave an answer that is not JSON (%d)", resp.StatusCode)
	}
	return nil
}

// The Cloud API's error codes that say what to do.
const (
	codeToken       = 190    // the access token expired or was revoked
	codePermission  = 10     // the token lacks whatsapp_business_messaging
	codeWindow      = 131047 // more than 24 hours since the person last wrote
	codeNotOnApp    = 131026 // the number is not on WhatsApp, or cannot get the message
	codeTestNumber  = 131030 // a test number can send only to the numbers in its list
	codeNoTemplate  = 132001 // no such template in that language
	codeTemplateArg = 132000 // the template's parameters do not match it
)

// apiError says what Meta refused, and what to do for the usual refusals.
func apiError(status int, body []byte) error {
	var e struct {
		Error struct {
			Message   string `json:"message"`
			Code      int    `json:"code"`
			ErrorData struct {
				Details string `json:"details"`
			} `json:"error_data"`
		} `json:"error"`
	}
	_ = json.Unmarshal(body, &e)
	said := e.Error.Message
	if e.Error.ErrorData.Details != "" {
		said += ": " + e.Error.ErrorData.Details
	}
	if said == "" {
		said = http.StatusText(status)
	}
	switch {
	case e.Error.Code == codeToken || status == http.StatusUnauthorized:
		return &NotSignedInError{"WhatsApp refused the token: make WHATSAPP_TOKEN again (a system user's token does not expire) (" + said + ")"}
	case e.Error.Code == codeWindow:
		return fmt.Errorf("WhatsApp takes a free message only within 24 hours of the person's last message: send an approved template with send_template (%s)", said)
	case e.Error.Code == codeTestNumber:
		return fmt.Errorf("a test number sends only to the numbers in its list: add this one on the app's WhatsApp ▸ API Setup page (%s)", said)
	case e.Error.Code == codeNotOnApp:
		return fmt.Errorf("WhatsApp cannot deliver to that number: it may not be on WhatsApp (%s)", said)
	case e.Error.Code == codeNoTemplate || e.Error.Code == codeTemplateArg:
		return fmt.Errorf("WhatsApp refused the template: check its name, its language and its parameters in WhatsApp Manager (%s)", said)
	case e.Error.Code == codePermission || status == http.StatusForbidden:
		return fmt.Errorf("WhatsApp refused: the token needs whatsapp_business_messaging on this number (%s)", said)
	}
	return fmt.Errorf("WhatsApp: %s (%d, code %d)", said, status, e.Error.Code)
}

// NotSignedInError is a refused token.
type NotSignedInError struct{ Message string }

func (e *NotSignedInError) Error() string { return e.Message }
