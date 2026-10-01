---
diataxis: how-to
devices: [mac, iphone, ipad]
description: See an HTML file an agent wrote, such as a report or a wireframe, as a page beside the conversation, with its stylesheet and pictures.
---

# Look at an HTML page an agent wrote

Agents often write HTML: reports, wireframes, coverage output and generated docs. The
files pane shows an `.html` or `.htm` file as a page, with the stylesheets, pictures and
scripts beside it, and redraws it as the agent rewrites it.

## Steps

1. Ask for the page, and ask to see it. For example:

   ```text
   Write report.html with a stylesheet and a chart beside it, and show it to me.
   ```

   The agent opens it with `show_file`, and it opens as a page. You can also click any
   HTML file in the files pane.

2. Watch it change. Each time the agent rewrites the page, or a stylesheet or picture
   beside it, the page is drawn again where you were reading.

3. Switch between **Page** and **Source** in the pane's bar. The choice stays for the
   pane, for every HTML file you open, until you change it. An agent showing you a page
   switches it back to **Page**.

## What a page can and cannot do

What an agent writes is treated as untrusted:

- **Scripts are off.** Click **{}** (Allow scripts) in the bar to let this one file run
  its scripts. It lasts until the window closes.
- **No network.** Nothing is loaded from the internet: no remote stylesheets, fonts,
  pictures or scripts, and scripts cannot fetch or open sockets, even when allowed.
- **Only files beside it.** The page reaches files inside the agent's folder, read
  through the agent's host, so it works the same for a project on a server. A path with
  `..` in it is refused. A file opened from outside the agent's folder reaches only its
  own folder.
- **Links go outside.** A web link opens in the Browser pane (on the iPhone and iPad, in
  your browser), a mail link in your mail app, and a link to another file in the folder
  opens that file in the files pane. Nothing else loads in place of the page.
- **Nothing kept.** Cookies and storage are thrown away with the page, and the page has
  no way to talk to the app.

## Things to know

- **Large files show as source.** A page bigger than the pane reads (128 KB) shows its
  source with a note saying how much is shown.
- **Fonts and other files** that are neither text nor pictures are not carried to the
  page, so a page using its own font falls back to a standard one.

## See also

- [Follow a live document](follow-a-live-document.md), for Markdown
- [Tools the app gives agents](../reference/agent-tools.md), for `show_file`
