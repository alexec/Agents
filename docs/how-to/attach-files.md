---
diataxis: how-to
devices: [mac, iphone, ipad]
description: Give an agent files and pictures with a prompt, by dragging, pasting, the paperclip or an @ mention.
---

# Attach files and pictures to a prompt

Anything you attach goes to the agent with the prompt you send. Files are sent as a
reference the agent can open; pictures are sent as the picture itself, to runtimes that
take them.

## Before you start

- An agent open, or a project's page with the prompt ready for a new one.
- Which runtimes take pictures and file contents differs; see
  [Reference](../reference/index.md) for the table.

## Steps

**On the Mac**

1. Attach in whichever way is closest:
   - **Drag** files from Finder onto the prompt.
   - **Paste** with **⌘V**: a screenshot or picture you copied, or files copied in
     Finder.
   - Click the **paperclip** (**Attach a file or a picture**) beside the prompt, choose
     one or more files, and click **Attach**.
   - Type **@** and the start of a file's name in the prompt. A list of matching files in
     the agent's folder appears; use the arrow keys and press Return, or click one. The
     name goes into your prompt and the file is attached.

   Each attachment shows above the prompt with its name. Click its **×** to remove it.
2. Type the prompt and send it.

A picture (PNG, JPEG, GIF, HEIC or WebP) goes as a picture when the runtime takes
pictures, and as a file otherwise.

**On iPhone and iPad**

1. Tap the **paperclip** beside the prompt and choose:
   - **Photo Library**, to pick one or more photos or screenshots.
   - **Files**, to pick a file from the Files app. Pictures and text files can be
     attached; anything else has to be attached on the Mac.
   - **Paste Picture**, to attach a picture you copied. It is there only when there is a
     picture to paste.
2. In a conversation, to attach a file that is already in the project on the Mac, type
   **@** and the start of its name in the prompt, and choose it from the list.
3. Type the prompt and send it.

Pictures from a phone are made smaller before they go. Everything attached from a phone
together can be up to 900 KB.

## If it doesn't work

A line in red under an attachment says why it will not go:

- **This runtime does not take pictures.** Remove the picture, or start the agent with a
  runtime that takes pictures.
- **This runtime does not take file contents. Attach the file itself.** On the Mac,
  attach the file from Finder or with **@** rather than pasting its contents.
- **This runtime does not take file contents, so this can only be attached on the Mac.**
  The file is on the phone and the runtime can only open files on the Mac. Put it in the
  project and attach it with **@**.
- **From a phone, attachments can be 900 KB in all, and these are …** Remove one to send.
