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

- in the folder, for that folder's sessions;
- in `~/.agents`, for every folder on that computer.

The file name, without `.md`, is the persona's id. When the folder and `~/.agents` both have
one with the same id, the folder's is used.

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

Manage your own persona files in **Settings ▸ Agent Configuration ▸ Personas**, on the Mac, the iPhone, the iPad and the web. On the Mac, manage a folder's persona files in **Folder Settings ▸ Agent Configuration ▸ Personas**. You choose a persona on the new-session form on every client.
Choose the folder or personal scope, then open a file, create one, edit its Markdown or
delete it. The editor keeps the whole Markdown file, including front matter fields the app
does not know, so a saved persona is available to future session starts in that scope.

## Picking one

The choice is a menu under the folder's name at the top of the new-session form, on the
Mac, the Remote and the web page (#918). It shows the persona picked, or **No persona**, and
**No persona** is first in the menu. It is not shown when the folder has no personas. A file that cannot be read is listed under it with what is wrong.

Picking a persona:

- sets every setting it names, as far as the runtime offers it; a model the runtime does not
  offer leaves the model as it was;
- leaves every setting it does not name as the form had it;
- adds its labels beside any already there.

You can still change anything before you start.

When a runtime advertises ACP's session system-prompt capability, the persona prompt is appended after the app's briefing on session creation and when the app loads, resumes or forks the session. Otherwise the app uses a runtime compatibility adapter where available, or sends the persona prompt before your words in the first user prompt. It is read from the file each time, and is not shown in the transcript.
