package connections

import "time"

// Email is the fourth provider (#1780): one IMAP mailbox for the email server. It has no
// sign-in page: the person gives the IMAP server, the user and an app password, which the
// host checks by signing in once (Go/internal/emailmcp) and keeps here. URL is the server
// (imaps://imap.example.com:993), Login the user, Workspace the server's host, and Access the
// app password, which never ends and has no refresh.
const Email = "email"

// EmailConnection is the connection an IMAP sign-in made.
func EmailConnection(serverURL, host, user, password string, at time.Time) Connection {
	return Connection{Provider: Email, Login: user, Workspace: host, URL: serverURL, Access: password, ConnectedAt: at}
}
