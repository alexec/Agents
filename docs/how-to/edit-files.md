---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Open a file in an agent's folder, type in it, and see what the file's language server finds and suggests.
---

# Edit files

You can change a file in an agent's folder yourself, beside the conversation. Every text
file opens in an editor, so a small fix does not need a prompt or another app. When a
language server for the file's language is on the agent's host, the editor also lists
the problems it finds and offers completions as you type.

## Before you start

- A session whose folder has the file. See the [tutorials](../tutorials/index.md).
- The agent's host is online. While it is not, the file shows, but you cannot type in it.

## Open a file

**Mac**

1. Open the session's conversation.
2. Click **Files** at the top of the sidebar on the right, or choose **View ▸ Files**
   (Command-1).
3. Click the file.

To find a file by name, choose **Go ▸ Open File…** (Command-P) and type part of its name.

**iPhone and iPad**

1. Open the session's conversation.
2. On an iPad, tap **Panes** at the top, then choose **Files**. On an iPhone, open the
   **Actions** menu and choose **Files**.
3. Tap the file.

**Open File…** in the **Actions** menu finds a file by name. With a keyboard attached,
Command-P does the same.

**Web page**

1. Open the session's conversation.
2. Click **Files** in the chat's header. On a narrow page, choose **Files** in the
   **···** menu.
3. Click the file.

**Open File…** in the **···** menu finds a file by name. Command-P or Ctrl+P does the
same.

Markdown, HTML, charts and Mermaid diagrams open as pages, not in this editor. See
[Follow a live document](follow-a-live-document.md) and
[Look at an HTML page](look-at-an-html-page.md). A very large file that is only partly
read opens with numbered lines and no editing, because a save would cut it short.

## Type and save

1. Click or tap in the file and type.
2. Stop typing. The editor saves the file a moment later, and again when you leave the
   file. There is no **Save** button, so there is no save to forget.

If a save fails, the editor says why above the text and keeps what you typed.

**When the file changes on disk while you type**

An agent can write the same file while you type. The editor never saves over a change it
did not see:

- If nothing you typed waits to be saved, the editor takes the new file in place.
- If something you typed waits, the editor says **This file changed on disk while you were
  typing. Nothing was saved over it.** Choose one:
  - **Compare** shows your text beside the file on disk. **Hide Comparison** closes it.
  - **Keep Mine** saves your text over the file on disk.
  - **Take Theirs** takes the file on disk. The editor then says **You took the version on
    disk.**, and **Undo** gives your text back.

## See problems from the language server

About a second after you stop typing, the editor asks the file's language server what is
wrong with the text as you have it, saved or not. The answer shows under the text:

- **2 problems · gopls**: one row for each problem, with its line, its column and what the
  server said. Click or tap a row to move the caret to that line.
- **No problems · ‹server›**: the server answered and found nothing.
- **Starting ‹server›…**: the server has not answered yet. A server can take a minute to
  start on a large folder.
- **Couldn't ask ‹server›: ‹why›**: the request failed.
- **‹server› is not installed on this host, so this file is not checked.** Install it on
  the agent's host. See below.

A file of a language with no server shows no list. The list is the same on the Mac,
iPhone, iPad and the web page.

## Ask for a completion

The language server can also say what to write at the caret.

- **Mac**: press Option-Escape or F5, or choose **Edit ▸ Complete**. The editor's own list
  of words shows. Keep typing to filter it.
- **iPhone and iPad**: stop typing in the middle of a word. A row of words shows above the
  keyboard. Tap one to put it in place of the word you are typing. With a keyboard
  attached, Control-Space asks too; the up and down arrows choose a word, Return or Tab
  puts it in, and Escape closes the row.
- **Web page**: press Ctrl+Space or Alt+Esc. A hint under the text names both keys,
  because a Mac uses Ctrl+Space to change the input source. A list shows under the text.
  The up and down arrows choose a word, Enter or Tab puts it in, and Escape closes it.

A completion puts in only the start of a snippet, and a function call only up to its
**(**, so you type the rest yourself.

When you ask and nothing comes, the editor says why under the text for a few seconds:
**No language server for this kind of file.**, **No completions here.**, or the reason
the request failed.

## Which language servers

The language servers run on the agent's host, the Mac or server where the agent works,
not on the device you type on. Agents does not install them. It looks for each one in
the folders of the host's login shell:

| Files | Language server |
| --- | --- |
| `.go` | `gopls` |
| `.swift` | `sourcekit-lsp` (also through `xcrun`, from Xcode) |
| `.ts`, `.tsx`, `.js`, `.jsx`, `.mjs`, `.cjs` | `typescript-language-server` |
| `.py` | `pyright-langserver`, or `pylsp` |
| `.rs` | `rust-analyzer` |

To add one, install it on the host so that your login shell finds it, then open the file
again.

The host starts a server the first time a file needs it, one for each folder and
language. It keeps at most four running and stops one after ten minutes with no requests,
so servers do not hold memory for files you closed. A host made before this feature says
**This host needs an update to do this.** in place of the list. See
[Versions](../explanation/versions.md).

## See also

- [Read an agent's changes](read-an-agents-changes.md)
- [Follow a live document](follow-a-live-document.md)
- [Use a shell in an agent's folder](use-a-shell.md)
- [Keyboard shortcuts](../reference/keyboard-shortcuts.md)
