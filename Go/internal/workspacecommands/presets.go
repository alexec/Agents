package workspacecommands

import "strings"

// PresetNames are the command provider's presets (FR-071): the commands for one CLI, so most
// providers need nothing but a name and a parameter or two. Each needs its CLI installed,
// and signed in, where the control plane runs. None asks for sudo.
var PresetNames = []string{"docker", "doctl", "codespaces", "coder", "gcloud-workstations"}

// expandPreset is o's preset, with its parameters filled in.
func expandPreset(name string, o map[string]any) (Config, error) {
	switch name {
	case "docker":
		return docker(o), nil
	case "doctl":
		return doctl(o)
	case "codespaces":
		return codespaces(o), nil
	case "coder":
		return coder(), nil
	case "gcloud-workstations":
		return workstations(o)
	}
	return Config{}, ConfigError("no preset " + name + "; there are " + strings.Join(PresetNames, ", "))
}

func ptr(s string) *string { return &s }

// docker is containers on the machine that runs the control plane, such as the Linux
// devbox: the ones named in containers, or else every container labelled agents.workspace,
// each reached by its agents.ssh label or the shared ssh line. With an image, it makes
// labelled containers from it, which install Agents and join by themselves (#1025), and
// deletes them with their anonymous volumes.
func docker(o map[string]any) Config {
	var containers []string
	for _, c := range strings_(o["containers"]) {
		if c != "" {
			containers = append(containers, c)
		}
	}
	ssh := nonEmpty(o["ssh"])
	tunnel, _ := o["tunnel"].(bool)
	states := map[string]State{
		"running": Running, "restarting": Starting, "created": Stopped, "exited": Stopped,
		"paused": Stopped, "dead": Stopped, "removing": Stopping}
	if len(containers) > 0 {
		commands := Commands{Start: "docker start ${id}", Stop: "docker stop ${id}",
			Status: "docker inspect -f '{{.State.Status}}' ${id}", SSH: ssh, Tunnel: tunnel}
		entries := make([]Entry, len(containers))
		for i, c := range containers {
			entries[i] = Entry{ID: c, Name: c, Commands: commands}
		}
		return newConfig(entries, nil, states, Making{})
	}
	defaults := map[string]string{}
	if ssh != nil {
		defaults["ssh"] = *ssh
	}
	listing := &Listing{
		Command: `docker ps -a --filter label=agents.workspace --format '{{.Names}}\t{{.State}}\t{{.Label "agents.ssh"}}'`,
		Shape:   Shape{Columns: []string{"id", "state", "ssh"}},
		Commands: Commands{Start: "docker start ${id}", Stop: "docker stop ${id}",
			SSH: ptr("${ssh}"), Tunnel: tunnel},
		Defaults: defaults,
	}
	making := Making{}
	if image := nonEmpty(o["image"]); image != nil {
		making = Making{
			Create: "docker run -d --name ${name} --label agents.workspace ${image} && docker exec ${name} sh -c ${firstBoot}",
			Delete: "docker rm -f -v ${id}",
			Options: map[string]any{"type": "object", "properties": map[string]any{
				"image": map[string]any{"type": "string", "title": "Image", "description": *image, "default": *image}}},
		}
	}
	return newConfig(nil, listing, states, making)
}

// doctl is DigitalOcean droplets with a tag.
func doctl(o map[string]any) (Config, error) {
	tag, _ := o["tag"].(string)
	if tag == "" {
		return Config{}, ConfigError("the doctl preset needs a tag")
	}
	user, ok := o["user"].(string)
	if !ok {
		user = "root"
	}
	tunnel, _ := o["tunnel"].(bool)
	return newConfig(nil, &Listing{
		Command: "doctl compute droplet list --tag-name " + ShellQuoted(tag) + " --format ID,Name,Status,PublicIPv4 --no-header",
		Shape:   Shape{Columns: []string{"id", "name", "state", "ip"}},
		Commands: Commands{Start: "doctl compute droplet-action power-on ${id} --wait",
			Stop: "doctl compute droplet-action power-off ${id} --wait",
			SSH:  ptr(user + "@${ip}"), Tunnel: tunnel},
	}, map[string]State{"active": Running, "new": Starting, "off": Stopped, "archive": Stopped}, Making{}), nil
}

// optional is a string value, or nil.
func optional(v any) *string {
	if s, ok := v.(string); ok {
		return &s
	}
	return nil
}

// codespaces is GitHub Codespaces. A codespace starts when something connects to it, so
// start is an ssh that does nothing. It can't reach the control plane, so it needs a tunnel.
func codespaces(o map[string]any) Config {
	repo := ""
	if r, ok := o["repo"].(string); ok {
		repo = " --repo " + ShellQuoted(r)
	}
	return newConfig(nil, &Listing{
		Command: "gh codespace list" + repo + " --json name,displayName,state",
		Shape:   Shape{Fields: map[string]string{"id": "name", "name": "displayName", "state": "state"}},
		Commands: Commands{Start: "gh codespace ssh -c ${id} -- true", Stop: "gh codespace stop -c ${id}",
			SSH: optional(o["ssh"]), Tunnel: true},
	}, map[string]State{"available": Running, "starting": Starting, "provisioning": Starting,
		"shuttingdown": Stopping, "shutdown": Stopped}, Making{})
}

// coder is Coder workspaces, reached through the coder.<name> hosts `coder config-ssh`
// writes.
func coder() Config {
	return newConfig(nil, &Listing{
		Command: "coder list -o json",
		Shape:   Shape{Fields: map[string]string{"id": "name", "name": "name", "state": "latest_build.status"}},
		Commands: Commands{Start: "coder start -y ${id}", Stop: "coder stop -y ${id}",
			SSH: ptr("coder.${name}")},
	}, map[string]State{"pending": Starting, "canceling": Stopping, "canceled": Stopped, "failed": Unknown,
		"deleting": Stopping, "deleted": Stopped}, Making{})
}

// workstations is Google Cloud Workstations in one cluster and configuration.
func workstations(o map[string]any) (Config, error) {
	flags := ""
	for _, key := range []string{"cluster", "config", "region"} {
		value, _ := o[key].(string)
		if value == "" {
			return Config{}, ConfigError("the gcloud-workstations preset needs " + key)
		}
		flags += " --" + key + "=" + ShellQuoted(value)
	}
	return newConfig(nil, &Listing{
		Command: "gcloud workstations list" + flags + " --format='value(name.basename(),state)'",
		Shape:   Shape{Columns: []string{"id", "state"}},
		Commands: Commands{Start: "gcloud workstations start ${id}" + flags,
			Stop: "gcloud workstations stop ${id}" + flags,
			SSH:  optional(o["ssh"]), Tunnel: true},
	}, map[string]State{"state_running": Running, "state_starting": Starting, "state_stopping": Stopping,
		"state_stopped": Stopped, "state_reconciling": Starting}, Making{}), nil
}
