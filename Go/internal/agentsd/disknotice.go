package agentsd

import "github.com/alexec/agents/Go/wire"

// A machine's notice (#3682): a volume became critically low, so agents on it will stop.
// It belongs to the machine, not to a chat, so it needs no agent, no mute and no chat to
// open; a tap opens the machine's page. One per volume each time it becomes critical, and
// withdrawn when the volume climbs back (machine.disk_ok). It is not taken from the
// person's notice bucket: it comes once per crossing, and a full disk dropped in a
// cool-down is the notice the person most needed.

// diskNoticeTitle is the notice's title, under the machine's name.
const diskNoticeTitle = "Disk almost full"

// diskNoticePrefix starts a disk notice's id, so a client knows a tap opens the machine's
// page; the rest is the volume's mount.
const diskNoticePrefix = "disk:"

// postDiskNotice posts the notice for a volume that became critical, unless it is posted
// already.
func (d *Daemon) postDiskNotice(a wire.DiskAlarm) {
	id := diskNoticePrefix + a.Reading.Mount
	d.attentionMu.Lock()
	for _, n := range d.notices {
		if n.id == id {
			d.attentionMu.Unlock()
			return
		}
	}
	d.notices = append(d.notices, postedNotice{id: id, mount: a.Reading.Mount, raised: now(),
		h3: a.Reading.Volume + " has " + diskWords(a.Reading.FreeBytes) + " free. Agents stop when it is full."})
	d.attentionMu.Unlock()
	d.reconsider()
}

// withdrawDiskNotice takes back the volume's notice, when it is posted.
func (d *Daemon) withdrawDiskNotice(mount string) {
	d.attentionMu.Lock()
	kept := d.notices[:0]
	gone := false
	for _, n := range d.notices {
		if n.mount == mount {
			gone = true
			continue
		}
		kept = append(kept, n)
	}
	d.notices = kept
	d.attentionMu.Unlock()
	if gone {
		d.reconsider()
	}
}
