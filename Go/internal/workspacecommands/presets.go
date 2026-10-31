package workspacecommands

import (
	"net/url"
	"strconv"
	"strings"
)

// PresetNames are the command provider's presets (FR-071), so most providers need nothing
// but a name and a parameter or two. A CLI preset needs its CLI installed, and signed in,
// where the control plane runs. An API preset (#1119, the -api ones) needs only a token,
// given as the provider's secret. None asks for sudo.
var PresetNames = []string{"docker", "doctl", "codespaces", "coder", "gcloud-workstations",
	"digitalocean-api", "codespaces-api", "coder-api", "aws-ec2-api", "gcp-compute-api"}

// The secrets the API presets read their tokens from.
const (
	DigitalOceanSecret = "DIGITALOCEAN_API_TOKEN"
	GitHubSecret       = "GITHUB_TOKEN"
	CoderSecret        = "CODER_SESSION_TOKEN"
)

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
	case "digitalocean-api":
		return digitalOceanAPI(o)
	case "codespaces-api":
		return codespacesAPI(o)
	case "coder-api":
		return coderAPI(o)
	case "aws-ec2-api":
		return awsEC2API(o)
	case "gcp-compute-api":
		return gcpComputeAPI(o)
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

// workstations is Google Cloud Workstations in one cluster and configuration. A
// workstation's container is made again at each start and only /home is kept, so its ssh
// host key is new each time (#1701).
func workstations(o map[string]any) (Config, error) {
	flags := ""
	for _, key := range []string{"cluster", "config", "region"} {
		value, _ := o[key].(string)
		if value == "" {
			return Config{}, ConfigError("the gcloud-workstations preset needs " + key)
		}
		flags += " --" + key + "=" + ShellQuoted(value)
	}
	// Without a project, gcloud's own default one (core/project).
	if project, _ := o["project"].(string); project != "" {
		flags += " --project=" + ShellQuoted(project)
	}
	return newConfig(nil, &Listing{
		Command: "gcloud workstations list" + flags + " --format='value(name.basename(),state)'",
		Shape:   Shape{Columns: []string{"id", "state"}},
		Commands: Commands{Start: "gcloud workstations start ${id}" + flags,
			Stop: "gcloud workstations stop ${id}" + flags,
			SSH:  optional(o["ssh"]), Tunnel: true, HostKeyRenews: true},
	}, map[string]State{"state_running": Running, "state_starting": Starting, "state_stopping": Stopping,
		"state_stopped": Stopped, "state_reconciling": Starting, "reconciling": Starting}, Making{}), nil
}

// api is a preset's API address: the given one (a proxy, or a test's server), or its
// provider's own, with no slash at its end.
func api(o map[string]any, standard, preset string) (string, error) {
	address := standard
	if given := nonEmpty(o["api"]); given != nil {
		address = *given
	}
	parsed, err := url.Parse(address)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Host == "" {
		return "", ConfigError("the " + preset + " preset's api must be a web address, https://…")
	}
	return strings.TrimRight(address, "/"), nil
}

// digitalOceanStates are a droplet's statuses.
var digitalOceanStates = map[string]State{"active": Running, "new": Starting, "off": Stopped, "archive": Stopped}

// digitalOceanFirstBoot is a new droplet's user data. It runs as root, once, so it makes a
// user, agents, with root's ssh keys, and installs Agents as that user (a host never runs as
// root). Linger starts the agents user's systemd at boot, so the host starts with the droplet.
const digitalOceanFirstBoot = `#!/bin/sh
id -u agents >/dev/null 2>&1 || useradd -m -s /bin/bash agents
mkdir -p /home/agents/.ssh
cp /root/.ssh/authorized_keys /home/agents/.ssh/ 2>/dev/null
chown -R agents:agents /home/agents/.ssh
chmod 700 /home/agents/.ssh
loginctl enable-linger agents
uid=$(id -u agents)
i=0
while [ ! -S "/run/user/$uid/bus" ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
cat > /home/agents/first-boot.sh <<'FIRSTBOOT'
${firstBoot}
FIRSTBOOT
chown agents:agents /home/agents/first-boot.sh
su - agents -c "XDG_RUNTIME_DIR=/run/user/$uid sh ~/first-boot.sh"
rm -f /home/agents/first-boot.sh
`

// digitalOceanAPI is DigitalOcean droplets with a tag, through DigitalOcean's API with a
// token in DIGITALOCEAN_API_TOKEN: nothing to install. Each is reached by plain ssh to its
// public address. New Machine makes a droplet with the tag that installs Agents on its
// first boot; Delete deletes it.
func digitalOceanAPI(o map[string]any) (Config, error) {
	tag, _ := o["tag"].(string)
	if tag == "" {
		return Config{}, ConfigError("the digitalocean-api preset needs a tag")
	}
	base, err := api(o, "https://api.digitalocean.com", "digitalocean-api")
	if err != nil {
		return Config{}, err
	}
	user, ok := o["user"].(string)
	if !ok || user == "" {
		user = "root"
	}
	tunnel, _ := o["tunnel"].(bool)
	headers := map[string]string{"Authorization": "Bearer ${" + DigitalOceanSecret + "}"}
	action := func(kind string) *Request {
		return &Request{Method: "POST", URL: base + "/v2/droplets/${id}/actions", Headers: headers,
			Body: map[string]any{"type": kind}}
	}
	body := map[string]any{"name": "${name}", "region": "${region}", "size": "${size}", "image": "${image}",
		"tags": []any{tag}, "user_data": digitalOceanFirstBoot}
	if keys := strings_(o["sshKeys"]); len(keys) > 0 {
		given := make([]any, len(keys))
		for i, k := range keys {
			given[i] = k
		}
		body["ssh_keys"] = given
	}
	text := func(title, value, description string) map[string]any {
		return map[string]any{"type": "string", "title": title, "default": value, "description": description}
	}
	return newConfig(nil, &Listing{
		Request: &Request{Method: "GET", Headers: headers,
			URL: base + "/v2/droplets?per_page=200&tag_name=" + url.QueryEscape(tag)},
		Shape: Shape{Items: "droplets", Fields: map[string]string{"id": "id", "name": "name", "state": "status",
			"ip": "networks.v4[type=public].ip_address"}},
		Commands: Commands{StartRequest: action("power_on"), StopRequest: action("power_off"),
			SSH: ptr(user + "@${ip}"), Tunnel: tunnel},
	}, digitalOceanStates, Making{
		CreateRequest: &Request{Method: "POST", URL: base + "/v2/droplets", Headers: headers, Body: body},
		DeleteRequest: &Request{Method: "DELETE", URL: base + "/v2/droplets/${id}", Headers: headers},
		Options: map[string]any{"type": "object", "properties": map[string]any{
			"region": text("Region", "nyc3", "A region's slug, such as nyc3, sfo3, ams3 or fra1."),
			"size":   text("Size", "s-1vcpu-1gb", "A size's slug, such as s-1vcpu-1gb or s-2vcpu-4gb."),
			"image":  text("Image", "ubuntu-24-04-x64", "An image with systemd, such as ubuntu-24-04-x64 or debian-12-x64."),
		}},
	}), nil
}

// codespacesAPI is GitHub Codespaces through GitHub's API, with a token in GITHUB_TOKEN:
// a real start and stop, and no gh for them. A codespace has no ssh port of its own, so ssh
// still goes through gh: the cs.<name>.<branch> hosts `gh codespace ssh --config` writes,
// whose ProxyCommand is gh. It can't reach the control plane, so it needs a tunnel.
func codespacesAPI(o map[string]any) (Config, error) {
	base, err := api(o, "https://api.github.com", "codespaces-api")
	if err != nil {
		return Config{}, err
	}
	list := base + "/user/codespaces?per_page=100"
	if repo, _ := o["repo"].(string); repo != "" {
		owner, name, ok := strings.Cut(repo, "/")
		if !ok || owner == "" || name == "" || strings.Contains(name, "/") {
			return Config{}, ConfigError("the codespaces-api preset's repo is owner/name")
		}
		list = base + "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name) + "/codespaces?per_page=100"
	}
	headers := map[string]string{"Authorization": "Bearer ${" + GitHubSecret + "}",
		"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
	ssh := ptr("cs.${id}.${ref}")
	if given := nonEmpty(o["ssh"]); given != nil {
		ssh = given
	}
	return newConfig(nil, &Listing{
		Request: &Request{Method: "GET", URL: list, Headers: headers},
		Shape: Shape{Items: "codespaces", Fields: map[string]string{"id": "name", "name": "display_name",
			"state": "state", "ref": "git_status.ref"}},
		Commands: Commands{
			StartRequest: &Request{Method: "POST", URL: base + "/user/codespaces/${id}/start", Headers: headers},
			StopRequest:  &Request{Method: "POST", URL: base + "/user/codespaces/${id}/stop", Headers: headers},
			SSH:          ssh, Tunnel: true},
	}, map[string]State{"available": Running, "starting": Starting, "provisioning": Starting, "queued": Starting,
		"awaiting": Starting, "rebuilding": Starting, "exporting": Stopping, "shuttingdown": Stopping,
		"shutdown": Stopped}, Making{
		// From a repository (#1809): the codespace clones it itself, with its own git
		// credentials. It has no user data, so Agents is installed over ssh afterwards.
		CreateRequest: &Request{Method: "POST", URL: base + "/repos/${repository.owner}/${repository.name}/codespaces",
			Headers: headers, Body: map[string]any{"display_name": "${name}"}},
		DeleteRequest: &Request{Method: "DELETE", URL: base + "/user/codespaces/${id}", Headers: headers},
		Options: map[string]any{"type": "object", "required": []any{"repository"}, "properties": map[string]any{
			"repository": map[string]any{"type": "string", "title": "Repository",
				"description": "The repository to make the codespace from, as owner/name."},
		}},
	}), nil
}

// coderAPI is Coder workspaces through the deployment's API at url, with a session token
// in CODER_SESSION_TOKEN: no coder for start and stop. ssh still goes through coder: the
// coder.<name> hosts `coder config-ssh` writes, whose ProxyCommand is coder.
func coderAPI(o map[string]any) (Config, error) {
	if nonEmpty(o["url"]) == nil {
		return Config{}, ConfigError("the coder-api preset needs url, the deployment's address")
	}
	base, err := api(map[string]any{"api": o["url"]}, "", "coder-api")
	if err != nil {
		return Config{}, err
	}
	headers := map[string]string{"Coder-Session-Token": "${" + CoderSecret + "}"}
	build := func(transition string) *Request {
		return &Request{Method: "POST", URL: base + "/api/v2/workspaces/${id}/builds", Headers: headers,
			Body: map[string]any{"transition": transition}}
	}
	return newConfig(nil, &Listing{
		Request:  &Request{Method: "GET", URL: base + "/api/v2/workspaces?q=" + url.QueryEscape("owner:me"), Headers: headers},
		Shape:    Shape{Items: "workspaces", Fields: map[string]string{"id": "id", "name": "name", "state": "latest_build.status"}},
		Commands: Commands{StartRequest: build("start"), StopRequest: build("stop"), SSH: ptr("coder.${name}")},
	}, map[string]State{"pending": Starting, "canceling": Stopping, "canceled": Stopped, "failed": Unknown,
		"deleting": Stopping, "deleted": Stopped}, Making{}), nil
}

// ec2Version is the EC2 Query API's version.
const ec2Version = "2016-11-15"

// awsEC2API is EC2 instances with a tag, in one region, through EC2's Query API, signed with
// SigV4 from an IAM user's keys in AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY (#1345):
// nothing to install. Each is reached by plain ssh to its public address. It doesn't make
// or delete instances.
func awsEC2API(o map[string]any) (Config, error) {
	region, _ := o["region"].(string)
	if region == "" {
		return Config{}, ConfigError("the aws-ec2-api preset needs a region, such as us-east-1")
	}
	for _, r := range region {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
			return Config{}, ConfigError("the aws-ec2-api preset's region is a name such as us-east-1")
		}
	}
	tag, ok := o["tag"].(string)
	if !ok || tag == "" {
		tag = "agents"
	}
	base, err := api(o, "https://ec2."+region+".amazonaws.com", "aws-ec2-api")
	if err != nil {
		return Config{}, err
	}
	user, ok := o["user"].(string)
	if !ok || user == "" {
		user = "ec2-user"
	}
	tunnel, _ := o["tunnel"].(bool)
	sign := &AWSSign{Service: "ec2", Region: region}
	query := func(action string, rest string) *Request {
		return &Request{Method: "GET", URL: base + "/?Action=" + action + "&Version=" + ec2Version + rest,
			Answer: "xml", Sign: sign}
	}
	// Every instance with the tag that is not gone (terminated).
	list := "&Filter.1.Name=tag-key&Filter.1.Value.1=" + url.QueryEscape(tag) +
		"&Filter.2.Name=instance-state-name"
	for i, state := range []string{"pending", "running", "stopping", "stopped", "shutting-down"} {
		list += "&Filter.2.Value." + strconv.Itoa(i+1) + "=" + state
	}
	return newConfig(nil, &Listing{
		Request: query("DescribeInstances", list),
		Shape: Shape{Items: "reservationSet[].instancesSet", Fields: map[string]string{"id": "instanceId",
			"name": "tagSet[key=Name].value", "state": "instanceState.name", "ip": "ipAddress"}},
		Commands: Commands{StartRequest: query("StartInstances", "&InstanceId.1=${id}"),
			StopRequest: query("StopInstances", "&InstanceId.1=${id}"),
			SSH:         ptr(user + "@${ip}"), Tunnel: tunnel},
	}, map[string]State{"pending": Starting, "running": Running, "stopping": Stopping, "stopped": Stopped,
		"shutting-down": Stopping, "terminated": Stopped}, Making{}), nil
}

// gcpName is a Google Cloud project or zone name: lower-case letters, digits and dashes.
func gcpName(value, what string) error {
	if value == "" {
		return ConfigError("the gcp-compute-api preset needs a " + what)
	}
	for _, r := range value {
		if !(r >= 'a' && r <= 'z' || r >= '0' && r <= '9' || r == '-') {
			return ConfigError("the gcp-compute-api preset's " + what + " is lower-case letters, digits and dashes")
		}
	}
	return nil
}

// gcpStartup is a new VM's startup script. Compute Engine runs it as root at every boot, so
// it does its work once: it makes a user, agents, gives it the keys in the VM's
// agents-ssh-keys metadata, and installs Agents as that user (a host never runs as root).
// The keys are not in Google's ssh-keys metadata, whose user the guest agent puts in
// google-sudoers. Linger starts the agents user's systemd at boot, so the host starts with
// the VM.
const gcpStartup = `#!/bin/sh
[ -f /var/lib/agents-first-boot-done ] && exit 0
touch /var/lib/agents-first-boot-done
id -u agents >/dev/null 2>&1 || useradd -m -s /bin/bash agents
mkdir -p /home/agents/.ssh
curl -fsS -H 'Metadata-Flavor: Google' \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/agents-ssh-keys \
  >> /home/agents/.ssh/authorized_keys 2>/dev/null
chown -R agents:agents /home/agents/.ssh
chmod 700 /home/agents/.ssh
chmod 600 /home/agents/.ssh/authorized_keys
loginctl enable-linger agents
uid=$(id -u agents)
i=0
while [ ! -S "/run/user/$uid/bus" ] && [ $i -lt 30 ]; do sleep 1; i=$((i + 1)); done
cat > /home/agents/first-boot.sh <<'FIRSTBOOT'
${firstBoot}
FIRSTBOOT
chown agents:agents /home/agents/first-boot.sh
su - agents -c "XDG_RUNTIME_DIR=/run/user/$uid sh ~/first-boot.sh"
rm -f /home/agents/first-boot.sh
`

// gcpComputeAPI is Compute Engine VMs with a label, in one project and zone, through the
// Compute Engine API with a service account's key in GOOGLE_SERVICE_ACCOUNT_KEY (#1346):
// nothing to install. Each is reached by plain ssh to its external address. New Machine…
// makes a VM with the label whose startup script installs Agents once, reachable as agents
// with the keys in sshKeys (public key lines); Delete deletes it.
// Only labelled VMs are listed, so a VM without the label is never started, stopped or
// deleted.
func gcpComputeAPI(o map[string]any) (Config, error) {
	project, _ := o["project"].(string)
	if err := gcpName(project, "project"); err != nil {
		return Config{}, err
	}
	zone, _ := o["zone"].(string)
	if err := gcpName(zone, "zone"); err != nil {
		return Config{}, err
	}
	label, ok := o["label"].(string)
	if !ok || label == "" {
		label = "agents"
	}
	if err := gcpName(label, "label"); err != nil {
		return Config{}, err
	}
	base, err := api(o, "https://compute.googleapis.com", "gcp-compute-api")
	if err != nil {
		return Config{}, err
	}
	user, ok := o["user"].(string)
	if !ok || user == "" {
		user = "agents"
	}
	tunnel, _ := o["tunnel"].(bool)
	auth := &GoogleAuth{Scope: "https://www.googleapis.com/auth/compute"}
	instances := base + "/compute/v1/projects/" + project + "/zones/" + zone + "/instances"
	metadata := []any{map[string]any{"key": "startup-script", "value": gcpStartup}}
	if keys := strings_(o["sshKeys"]); len(keys) > 0 {
		metadata = append(metadata, map[string]any{"key": "agents-ssh-keys", "value": strings.Join(keys, "\n") + "\n"})
	}
	text := func(title, value, description string) map[string]any {
		return map[string]any{"type": "string", "title": title, "default": value, "description": description}
	}
	return newConfig(nil, &Listing{
		Request: &Request{Method: "GET", URL: instances + "?filter=" + url.QueryEscape("labels."+label+":*"), Google: auth},
		Shape: Shape{Items: "items", Fields: map[string]string{"id": "name", "name": "name", "state": "status",
			"ip": "networkInterfaces[0].accessConfigs[0].natIP"}},
		Commands: Commands{
			StartRequest: &Request{Method: "POST", URL: instances + "/${id}/start", Google: auth},
			StopRequest:  &Request{Method: "POST", URL: instances + "/${id}/stop", Google: auth},
			SSH:          ptr(user + "@${ip}"), Tunnel: tunnel},
	}, map[string]State{"provisioning": Starting, "staging": Starting, "running": Running, "stopping": Stopping,
		"suspending": Stopping, "terminated": Stopped, "stopped": Stopped, "suspended": Stopped}, Making{
		CreateRequest: &Request{Method: "POST", URL: instances, Google: auth, Body: map[string]any{
			"name":        "${name}",
			"machineType": "zones/" + zone + "/machineTypes/${machineType}",
			"labels":      map[string]any{label: ""},
			"disks": []any{map[string]any{"boot": true, "autoDelete": true,
				"initializeParams": map[string]any{"sourceImage": "${image}", "diskSizeGb": "${diskSizeGb}"}}},
			"networkInterfaces": []any{map[string]any{"network": "global/networks/default",
				"accessConfigs": []any{map[string]any{"type": "ONE_TO_ONE_NAT", "name": "External NAT"}}}},
			"metadata": map[string]any{"items": metadata},
		}},
		DeleteRequest: &Request{Method: "DELETE", URL: instances + "/${id}", Google: auth},
		Options: map[string]any{"type": "object", "properties": map[string]any{
			"machineType": text("Machine type", "e2-small", "Such as e2-small or e2-standard-2."),
			"image": text("Image", "projects/debian-cloud/global/images/family/debian-12",
				"An image with systemd, such as projects/debian-cloud/global/images/family/debian-12."),
			"diskSizeGb": text("Disk (GB)", "20", "The boot disk's size."),
		}},
	}), nil
}
