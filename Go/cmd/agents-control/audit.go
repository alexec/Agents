package main

import (
	"context"
	"fmt"
	"os"

	"github.com/alexec/agents/Go/internal/controlplane/audit"
)

// verifyAudit is `agents-control audit verify` (#1001): every chain of the audit and every
// seal checked. It says what was changed or removed, and exits 1 when anything was.
func verifyAudit() {
	r, err := audit.Verify(context.Background(), openStore(""))
	if err != nil {
		fail("audit verify: %v", err)
	}
	fmt.Printf("%d entries in %d chains, %d seals", r.Entries-r.Unchained, r.Chains, r.Seals)
	if r.Unchained > 0 {
		fmt.Printf("; %d entries from before the chain, not checked", r.Unchained)
	}
	fmt.Println()
	for _, p := range r.Problems {
		fmt.Println(p)
	}
	if !r.OK() {
		os.Exit(1)
	}
	fmt.Println("no entry was changed or removed")
}
