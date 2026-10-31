---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Add AWS EC2, Google Compute Engine, Google Cloud Workstations, DigitalOcean, GitHub Codespaces or Coder as a machine provider, with the credentials each one needs and where they go.
---

# Set up a cloud machine provider

A machine provider starts and stops the machines that your hosts run on. It runs on the
control plane, not on a host, so it can start a host that is down. This page tells you how
to add one for a cloud, and which credentials each cloud needs.

Most clouds have an **API preset**: you give a token or a key, and there is nothing to
install. A **CLI preset** uses the cloud's own CLI, which must be installed and signed in
on the Mac that runs the control plane.

| Cloud | Through its API | Through its CLI | Its machines |
| --- | --- | --- | --- |
| AWS EC2 Instances | an IAM user's access key | no | instances with a tag, in one region |
| Google Compute Engine VMs | a service account's JSON key | no | VMs with a label, in one zone |
| Google Cloud Workstations | no | `gcloud` | one cluster and configuration's workstations |
| DigitalOcean Droplets | an API token | `doctl` | droplets with a tag |
| GitHub Codespaces | a GitHub token | `gh` | your codespaces, or one repository's |
| Coder Machines | a session token | `coder` | your Coder machines |

## Where to add one

- **On the Mac:** **Settings ▸ Control plane ▸ Providers**, then **Add Provider…**. Choose
  the cloud. For DigitalOcean, Codespaces and Coder, **Reach it with** offers **Its API**
  (first) and **Its CLI**. The Mac also adds Docker, your own commands and MCP servers.
- **On the iPhone or iPad:** **Settings ▸ Machine providers**, then **Add Provider…**.
- **On the web page:** the **Machine providers** section of Settings, then
  **Add Provider…**.

The Remote and the web page offer only the API presets: DigitalOcean, Codespaces, Coder,
AWS EC2 and Compute Engine. A CLI preset needs a shell where the control plane runs, to
install and sign in the CLI, and a person on a phone or in a browser has none there.

Each form fills in its own name, such as "AWS EC2 Instances". Change it in **Name** when
you add more than one of a kind.

**New Machine…**, which makes a new machine from a provider's card, is on the Mac. On all
three clients, **Start a Machine from a Repository…** makes a machine for one repository
from a provider that can make machines.

## Where the credentials go

You type a token or a key once. It goes to the control plane and is never shown again. The
device that you typed it on does not keep it. The control plane keeps it in its store,
sealed with the key that seals your secrets (a KMS on a cloud machine), so no value is in
the store in clear, and a store copy or a backup keeps it. It is never sent to a host or a
client, and never logged. An API preset sends it only in
a request's header, never in an address.

To change it later, choose **Edit…** on the provider's card. An empty field keeps the one
it has.

## AWS EC2 Instances

You need an IAM user's access key. Give the user the smallest policy: it lists the
instances, and starts and stops only the ones with the tag (here `agents`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "ec2:DescribeInstances", "Resource": "*" },
    { "Effect": "Allow", "Action": ["ec2:StartInstances", "ec2:StopInstances"],
      "Resource": "arn:aws:ec2:*:*:instance/*",
      "Condition": { "Null": { "aws:ResourceTag/agents": "false" } } }
  ]
}
```

AWS allows `ec2:DescribeInstances` on all instances or none, so it can't be limited.

1. Make the IAM user and its access key in the AWS console.
2. In the form, give **Access key ID** and **Secret access key**.
3. Give the **Region**, such as `us-east-1`.
4. Give the tag key in **Instances tagged** (the Mac) or **Tag** (the Remote and the web
   page). The default is `agents`. Put that tag on each instance that you want.
5. Give the ssh user in **ssh as** or **ssh user**. The default is `ec2-user`.

The control plane signs each request with AWS's Signature Version 4. The secret key is
never sent. Agents reaches each instance with plain ssh to its public address. The preset
makes and deletes no instances.

## Google Compute Engine VMs

You need a service account's JSON key. Give the service account the smallest role:

- To list, start and stop: `compute.instances.list`, `compute.instances.start` and
  `compute.instances.stop`.
- To make and delete VMs with **New Machine…** as well: `compute.instances.create`,
  `compute.instances.delete`, `compute.instances.setMetadata`,
  `compute.instances.setLabels`, `compute.disks.create`, `compute.subnetworks.use` and
  `compute.subnetworks.useExternalIp`.

1. Make the service account and a JSON key for it in the Google Cloud console.
2. Give the key. On the Mac, choose **Choose Key File…** next to **Service account key**.
   On the Remote and the web page, paste the key's JSON in **Service account key (JSON)**.
3. Give the **Folder** and the **Zone**, such as `europe-west2-a`.
4. Give the label key in **VMs labelled** (the Mac) or **Label**. The default is `agents`.
5. Give the ssh user. The default is `agents`.
6. To make VMs from Agents, give a public key in **ssh key for new VMs** (the Mac) or
   **ssh public key**. A new VM lets in that key for the `agents` user.

The control plane gets an access token from the key, and keeps the token until a minute
before it ends. The key itself is never sent. ssh goes to each VM's external address, so
the network must let in port 22. A static address keeps the address the same after a stop.

A VM made with **New Machine…** makes the user `agents` with your key on its first boot,
and installs Agents as that user, never as root. Its boot disk is deleted with the VM.

## Google Cloud Workstations

This one is on the Mac only, through `gcloud`. It has no API preset.

1. On the Mac that runs the control plane, install `gcloud` and sign it in.
2. Add a host to your ssh config that reaches the workstation's port 22 through
   `gcloud workstations start-tcp-tunnel`.
3. In the form, give the **Cluster**, the **Configuration** and the **Region**. **Folder**
   is optional: without it, `gcloud`'s default is used.
4. In **ssh**, give the host from your ssh config.

A workstation makes a new ssh host key each time it starts. After a Start that the control
plane made, its ssh start takes the new key and pins it again. At any other time a changed
key is refused. See [Integrations](../reference/integrations.md#machine-providers) for
its state.

## DigitalOcean Droplets

Through its API, you need a DigitalOcean API token with custom scopes: droplet read and
update. To make and delete droplets from Agents, add droplet create and delete.

1. Make the token in the DigitalOcean control panel, under API.
2. Give it in **API token**.
3. Give the tag in **Droplets tagged** (the Mac) or **Tag**. The default is `agents`.
4. Give the ssh user. The default is `root`.

**New Machine…** makes a droplet with the tag, in the region, size and image that you
choose. Choose an image with systemd, such as `ubuntu-24-04-x64`. Its first boot makes a
user `agents` with root's ssh keys and installs Agents as that user, never as root.

Through its CLI, install `doctl` and sign it in on the Mac that runs the control plane.

## GitHub Codespaces

Through its API, you need a GitHub token: a fine-grained one with Codespaces lifecycle
admin (read and write), or a classic one with the `codespace` scope.

1. Make the token on github.com, under Settings ▸ Developer settings.
2. Give it in **Token** (the Mac) or **GitHub token**.
3. In **Repository**, give `owner/name` for one repository's codespaces, or leave it empty
   for all of yours.
4. On the Mac that runs the control plane, run
   `gh codespace ssh --config >> ~/.ssh/config`.

A codespace has no ssh port of its own, so ssh still goes through `gh`. The provider's card
says "needs gh for ssh". It can make a codespace from a repository, but it can't install
Agents on its first boot: add it with **Add as Host…** on the Mac.

Through its CLI, install `gh` and sign it in.

## Coder Machines

Through its API, you need your deployment's address and a session token.

1. Make the token with `coder tokens create`.
2. Give the address in **Deployment**, such as `https://coder.example.com`.
3. Give the token in **Session token**.
4. On the Mac that runs the control plane, run `coder config-ssh`.

ssh still goes through `coder`, so the card says "needs coder for ssh".

Through its CLI, install `coder`, sign it in, and run `coder config-ssh`.

## After you add it

When you choose **Add**, the control plane checks that the provider lists its machines.
If it can't, it says why, in the cloud's own words. The provider's card then shows its
machines, and you can link each one to a host. See
[Start machines from Agents](start-machines-from-agents.md).

Machine providers need a control plane with one copy, such as the one on your Mac. A
control plane with several copies does not run them yet.

## See also

- [Add a machine provider](add-a-machine-provider.md): your own commands, a tool map,
  or a server of your own.
- [Machine providers](../reference/machine-providers.md): every preset's parameters
  and the contract.
- [Start machines from Agents](start-machines-from-agents.md)
