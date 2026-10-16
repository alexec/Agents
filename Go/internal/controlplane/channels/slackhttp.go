package channels

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/coder/websocket"
)

// SlackHTTP is SlackHTTP: Slack itself, the Web API over HTTPS and Socket Mode's
// WebSocket dialled out. The zero value uses http.DefaultClient and slack.com.
type SlackHTTP struct {
	Client *http.Client
	// Base is "https://slack.com/api/" unless set.
	Base string
}

// Call is SlackHTTP.call: a POST with the token, the reply when ok.
func (h SlackHTTP) Call(ctx context.Context, method, token string, body map[string]any) (map[string]any, error) {
	client, base := h.Client, h.Base
	if client == nil {
		client = http.DefaultClient
	}
	if base == "" {
		base = "https://slack.com/api/"
	}
	data, err := marshal(body)
	if err != nil {
		return nil, err
	}
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, base+method, bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	request.Header.Set("authorization", "Bearer "+token)
	request.Header.Set("content-type", "application/json; charset=utf-8")
	response, err := client.Do(request)
	if err != nil {
		return nil, &SlackFailure{fmt.Sprintf("Slack could not be reached: %v", err)}
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, 4<<20+1))
	if err != nil {
		return nil, err
	}
	var reply map[string]any
	if response.StatusCode != http.StatusOK || len(raw) > 4<<20 || json.Unmarshal(raw, &reply) != nil || reply == nil {
		return nil, &SlackFailure{fmt.Sprintf("Slack answered %s with %d.", method, response.StatusCode)}
	}
	if reply["ok"] != true {
		code, ok := reply["error"].(string)
		if !ok {
			code = "an unknown error"
		}
		return nil, SlackSaid(code, method)
	}
	return reply, nil
}

// Connect is SlackHTTP.connect: Socket Mode's WebSocket.
func (h SlackHTTP) Connect(ctx context.Context, url string) (LineConn, error) {
	options := &websocket.DialOptions{}
	if h.Client != nil {
		options.HTTPClient = h.Client
	}
	conn, _, err := websocket.Dial(ctx, url, options)
	if err != nil {
		return nil, err
	}
	conn.SetReadLimit(4 << 20)
	return &wsLines{conn: conn}, nil
}

// wsLines is a WebSocket read and written a text message at a time.
type wsLines struct{ conn *websocket.Conn }

func (w *wsLines) ReadLine(ctx context.Context) (string, error) {
	_, data, err := w.conn.Read(ctx)
	if err != nil {
		if websocket.CloseStatus(err) != -1 || errors.Is(err, io.EOF) {
			return "", io.EOF
		}
		return "", err
	}
	return string(data), nil
}

func (w *wsLines) WriteLine(line string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return w.conn.Write(ctx, websocket.MessageText, []byte(line))
}

func (w *wsLines) Close() error { return w.conn.Close(websocket.StatusNormalClosure, "") }
