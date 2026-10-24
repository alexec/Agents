---
diataxis: reference
devices: [mac, iphone, ipad, web]
description: The persona file format, where personas live, and what picking one does.
---

# Personas

A persona is a kind of session you pick when you start an agent. It sets the new session's
runtime, model, effort, permission mode and labels in one go, and gives the agent a prompt
of its own.

## Where they live

A persona is one Markdown file in a `.agents/personas` folder:

- in the project, for that project's sessions;
- in `~/.agents`, for every project on that computer.

The file name, without `.md`, is the persona's id. When the project and `~/.agents` both have
one with the same id, the project's is used.

No runtime reads these folders as skills, so an agent cannot pick a persona up half way
through a session.

## The file

```markdown
---
name: Reviewer
description: Reads a change and says what is wrong with it.
runtime: codex
model: gpt-5.5
effort: high
permission-mode: read-only
labels: [review]
---

You review changes. Use the code-review skill, and say what you would change before
changing anything.
```

| Key | What it sets |
|---|---|
| `name` | The name on the choice. The id when left out. |
| `description` | The line shown under the choice once it is picked. |
| `runtime`, `model`, `effort`, `permission-mode`, `options`, `labels` | The same settings, with the same values, as in a [workflow](workflows.md). |

Every key is optional, and so is the front matter: a file with none is all prompt.

The body is the persona's prompt. It can name the skills the persona relies on.

## Manage them in Agents

On the Mac, manage persona files in **Settings ▸ Agent Configuration ▸ Other files** for personal files, or **Project Settings ▸ Agent Configuration ▸ Other files** for project files. The iPhone, iPad and web keep persona management on the new-session form because they do not have agent-file configuration pages. You can still choose a persona on the new-session form on every client.
Choose the project or personal scope, then open a file, create one, edit its Markdown or
delete it. The editor keeps the whole Markdown file, including front matter fields the app
does not know, so a saved persona is available to future session starts in that scope.

## Picking one

The choice is a menu under the project's name at the top of the new-session form, on the
Mac, the Remote and the web page (#918). It shows the persona picked, or **No persona**, and
**No persona** is first in the menu. It is not shown when the project has no personas. A file that cannot be read is listed under it with what is wrong.

Picking a persona:

- sets every setting it names, as far as the runtime offers it; a model the runtime does not
  offer leaves the model as it was;
- leaves every setting it does not name as the form had it;
- adds its labels beside any already there.

You can still change anything before you start.

On Claude and Grok, the prompt goes in the session's system prompt, after the app's
briefing, and is given again each time the conversation is picked back up. On the other
runtimes, it is sent with the agent's first prompt, before your words, and again whenever the
conversation starts over. It is read from the file each time, and is not shown in the
transcript.
