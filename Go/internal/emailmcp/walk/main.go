// A stand-in mailbox for walks (#1780): go-imap's in-memory IMAP server on this machine, with
// no TLS, which the email server and Connect Email reach as imap+insecure://127.0.0.1:<port>.
// It holds INBOX, Archive and Junk, and a few messages; each line on stdin that reads
// `deliver <from> <subject>` puts one more into INBOX, as mail coming in.
//
// Build it for the Mac (the Go container's own 127.0.0.1 is not the Mac's), then run it:
//
//	GOOS=darwin Go/scripts/go.sh build -o out/fake-imap ./internal/emailmcp/walk
//	Go/out/fake-imap --port 1143      user agents@example.com, password walk-app-password
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"github.com/emersion/go-imap/v2"
	"github.com/emersion/go-imap/v2/imapclient"
	"github.com/emersion/go-imap/v2/imapserver"
	"github.com/emersion/go-imap/v2/imapserver/imapmemserver"
)

const (
	user     = "agents@example.com"
	password = "walk-app-password"
)

func main() {
	port := flag.Int("port", 1143, "the port on 127.0.0.1")
	flag.Parse()
	mem := imapmemserver.New()
	u := imapmemserver.NewUser(user, password)
	for _, name := range []string{"INBOX", "Archive", "Junk"} {
		if err := u.Create(name, nil); err != nil {
			log.Fatal(err)
		}
	}
	mem.AddUser(u)
	server := imapserver.New(&imapserver.Options{
		NewSession: func(*imapserver.Conn) (imapserver.Session, *imapserver.GreetingData, error) {
			return mem.NewSession(), nil, nil
		},
		InsecureAuth: true,
		Caps:         imap.CapSet{imap.CapIMAP4rev1: {}, imap.CapIMAP4rev2: {}},
		Logger:       log.New(io.Discard, "", 0),
	})
	address := fmt.Sprintf("127.0.0.1:%d", *port)
	ln, err := net.Listen("tcp", address)
	if err != nil {
		log.Fatal(err)
	}
	go func() { _ = server.Serve(ln) }()

	deliver(address, "INBOX", "GitLab <gitlab@mg.gitlab.com>", "Your GitLab sign-in code", "Your code is 482913. It expires in 15 minutes.")
	deliver(address, "INBOX", "AWS <no-reply@signin.aws>", "Verify your email address", "Your verification code is 731004.")
	deliver(address, "INBOX", "news@example.org", "Weekly news", "Nothing much happened this week.")
	deliver(address, "Archive", "DigitalOcean <support@digitalocean.com>", "Welcome to DigitalOcean", "Your account is ready.")
	fmt.Printf("imap+insecure://%s user %s password %s\n", address, user, password)

	lines := bufio.NewScanner(os.Stdin)
	for lines.Scan() {
		words := strings.Fields(lines.Text())
		if len(words) >= 3 && words[0] == "deliver" {
			deliver(address, "INBOX", words[1], strings.Join(words[2:], " "), "Your code is 112233.")
			fmt.Println("delivered")
		}
	}
	select {}
}

func deliver(address, folder, from, subject, body string) {
	c, err := imapclient.DialInsecure(address, nil)
	if err != nil {
		log.Fatal(err)
	}
	defer c.Close()
	if err := c.Login(user, password).Wait(); err != nil {
		log.Fatal(err)
	}
	raw := fmt.Sprintf("From: %s\r\nTo: %s\r\nSubject: %s\r\nDate: %s\r\nMessage-Id: <%d@walk.example.com>\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n%s\r\n",
		from, user, subject, time.Now().Format(time.RFC1123Z), time.Now().UnixNano(), body)
	cmd := c.Append(folder, int64(len(raw)), nil)
	if _, err := cmd.Write([]byte(raw)); err != nil {
		log.Fatal(err)
	}
	if err := cmd.Close(); err != nil {
		log.Fatal(err)
	}
	if _, err := cmd.Wait(); err != nil {
		log.Fatal(err)
	}
}
