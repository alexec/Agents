package agentsd

import (
	"archive/tar"
	"compress/gzip"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"unicode"

	"github.com/alexec/agents/Go/internal/agentsd/store"
	"github.com/alexec/agents/Go/wire"
)

// Export and import of one agent or one folder's agents (#1001, slice c1). An export is
// a backup archive (backups.go) of the chosen agents and none of the root's files. The
// host writes it into Outgoing, and the client reads it in parts (agents/exportRead), as
// a send's bundle is read. An import is sent in parts into Incoming (agents/importUpload),
// as a send is received, and agents/import restores its agents archived. Both folders are
// swept of a file nothing touched for an hour (transferLimit).
//
// An imported agent is never run here, whatever its manifest says: it keeps the root that
// made it, or "restored", as a record from another machine's backup does. An agent this
// machine deleted (erased.json) is skipped.

// exportNameMost is the most characters of a title or a folder an export's name keeps.
const exportNameMost = 60

func (d *Daemon) registerExports() {
	On(d, wire.CallAgentsExport, func(ctx context.Context, c *Client, r wire.AgentsExportRequest) (wire.AgentsExport, error) {
		return d.export(r)
	})
	On(d, wire.CallAgentsExportRead, func(ctx context.Context, c *Client, r wire.SendReadRequest) (wire.SendRead, error) {
		return d.readOutgoing(r, "That export is gone. Export again.")
	})
	On(d, wire.CallAgentsImportUpload, func(ctx context.Context, c *Client, r wire.ReceiveUploadRequest) (wire.Empty, error) {
		return wire.Empty{}, d.receiveUpload(r)
	})
	On(d, wire.CallAgentsImport, func(ctx context.Context, c *Client, r wire.AgentsImportRequest) (wire.BackupRestoreResult, error) {
		return d.importExport(r)
	})
}

// exportAgents is what an export request names: one agent, or a folder's agents.
func (d *Daemon) exportAgents(r wire.AgentsExportRequest) ([]wire.Agent, string, error) {
	switch {
	case r.AgentID != nil && r.Folder != nil:
		return nil, "", Invalid("Export one agent or one folder, not both.")
	case r.AgentID != nil:
		a := d.Store.Agent(*r.AgentID)
		if a == nil {
			return nil, "", noSuchAgent()
		}
		name := "Agent"
		if a.Title != nil && strings.TrimSpace(*a.Title) != "" {
			name = *a.Title
		}
		return []wire.Agent{*a}, name, nil
	case r.Folder != nil:
		folder := store.FolderPath(*r.Folder)
		if resolved, err := store.Resolve(folder); err == nil {
			folder = resolved
		}
		agents := d.agentsOf(folder)
		if len(agents) == 0 {
			return nil, "", Invalid("%s has no agents to export.", shortPath(folder))
		}
		return agents, filepath.Base(folder), nil
	}
	return nil, "", Invalid("Name an agent or a folder to export.")
}

func (d *Daemon) export(r wire.AgentsExportRequest) (wire.AgentsExport, error) {
	agents, name, err := d.exportAgents(r)
	if err != nil {
		return wire.AgentsExport{}, err
	}
	sweepTransfers(d.outgoingFolder())
	if err := os.MkdirAll(d.outgoingFolder(), 0o700); err != nil {
		return wire.AgentsExport{}, err
	}
	id := store.NewUUID()
	path, _ := d.outgoingFile(id)
	at := nowFunc().UTC()
	m := backupManifest{Format: backupFormat, RootID: d.Store.RootID, Machine: macName(), MadeAt: wire.DateOf(at)}
	if err := d.writeBackupArchive(path, &m, agents, false); err != nil {
		os.Remove(path)
		return wire.AgentsExport{}, err
	}
	fi, err := os.Stat(path)
	if err != nil {
		return wire.AgentsExport{}, err
	}
	return wire.AgentsExport{
		File:   wire.SendFile{ID: id, Size: fi.Size()},
		Agents: m.Agents,
		Name:   exportFileName(name) + " " + at.Format("2006-01-02") + ".tar.gz",
	}, nil
}

// exportFileName is a title or a folder's name as a file name: no path separators or
// control characters, and at most exportNameMost characters.
func exportFileName(s string) string {
	var b strings.Builder
	n := 0
	for _, r := range strings.TrimSpace(s) {
		if n == exportNameMost {
			break
		}
		switch {
		case r == '/' || r == '\\' || r == ':' || unicode.IsControl(r):
			r = '-'
		case unicode.IsSpace(r):
			r = ' '
		}
		b.WriteRune(r)
		n++
	}
	out := strings.Trim(strings.TrimSpace(b.String()), ".")
	if out == "" {
		return "Agents"
	}
	return out
}

// importExport restores the agents of an uploaded export, archived, and removes the upload.
// With a folder, the folder whose menu the person used, every agent comes back in that
// folder (#2389); without one, each in the folder it had where it was exported.
func (d *Daemon) importExport(r wire.AgentsImportRequest) (wire.BackupRestoreResult, error) {
	into := ""
	if r.Folder != nil {
		into = store.FolderPath(*r.Folder)
		s, ok := d.summaryFor(into)
		if !ok {
			return wire.BackupRestoreResult{}, noSuchFolder(shortPath(into) + " is not a folder.")
		}
		into = store.FolderPath(s.Folder.Folder)
	}
	path, err := d.incomingFile(r.Upload)
	if err != nil {
		return wire.BackupRestoreResult{}, err
	}
	defer os.Remove(path)
	m, err := readExportManifest(path)
	if err != nil {
		return wire.BackupRestoreResult{}, err
	}
	// Never this machine's own: an imported agent is shown and never run (#1001).
	return d.restoreArchive(path, m.RootID, false, false, into)
}

// readExportManifest reads an archive's first entry, which a backup and an export both
// begin with.
func readExportManifest(path string) (backupManifest, error) {
	var m backupManifest
	notOne := Invalid("That file is not an export of Agents.")
	f, err := os.Open(path)
	if err != nil {
		return m, Invalid("The upload is gone. Import again.")
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return m, notOne
	}
	tr := tar.NewReader(gz)
	h, err := tr.Next()
	if err != nil || h.Name != "manifest.json" || h.Size > 64<<10 {
		return m, notOne
	}
	b, err := io.ReadAll(io.LimitReader(tr, h.Size))
	if err != nil || json.Unmarshal(b, &m) != nil || m.Format < 1 {
		return m, notOne
	}
	if m.Format != backupFormat {
		return m, Invalid("That export was made by a newer version of Agents. Update Agents and import again.")
	}
	return m, nil
}
