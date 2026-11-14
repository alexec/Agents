package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"time"

	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd"
	"github.com/agentloops-dev/agent-loops/Go/internal/agentsd/store"
	"github.com/agentloops-dev/agent-loops/Go/wire"
)

const lockUsage = `usage: agentsd lock reset [--root <root>]

Forget the machine lock this machine pinned (#3493), after you started a new lock because
every one of your devices and your recovery key were lost. The machine then takes the next
lock the control plane sends on first use, and asks to join it: approve it on your new device.`

// lockCommand is `agentsd lock …`. reset is the only way to turn the lock off on a machine
// (specs/3399-machine-lock D4), and only this machine's own account can run it: it talks to
// the running agentsd on daemon.sock, or, with none running, removes the files itself.
func lockCommand(args []string) int {
	if len(args) == 0 || args[0] != "reset" {
		fmt.Fprintln(os.Stderr, lockUsage)
		return 2
	}
	cl := parse(args[1:])
	loc := store.At(cl.root)
	if !running(loc.Lock(), 0) {
		agentsd.ResetLockFiles(loc.Root)
		fmt.Println("The lock is reset. When agentsd starts, it pins the lock the control plane sends, and asks to join it.")
		return 0
	}
	if err := callSocket(loc.Socket(), wire.CallDaemonLockReset.Name, wire.Empty{}); err != nil {
		fmt.Fprintf(os.Stderr, "The lock was not reset: %v\n", err)
		return 1
	}
	fmt.Println("The lock is reset. This machine pins the lock the control plane sends, and asks to join it: approve it on your new device.")
	return 0
}

// callSocket makes one call on daemon.sock and waits for its answer.
func callSocket(path, method string, params any) error {
	c, err := net.DialTimeout("unix", path, 5*time.Second)
	if err != nil {
		return err
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(30 * time.Second))
	b, _ := json.Marshal(map[string]any{"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
	if _, err := c.Write(append(b, '\n')); err != nil {
		return err
	}
	r := bufio.NewReaderSize(c, 1<<20)
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return err
		}
		var reply struct {
			ID    *json.RawMessage `json:"id"`
			Error *struct {
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.Unmarshal(line, &reply) != nil || reply.ID == nil {
			continue // a notification
		}
		if reply.Error != nil {
			return fmt.Errorf("%s", reply.Error.Message)
		}
		return nil
	}
}
