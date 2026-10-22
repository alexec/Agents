---
diataxis: how-to
devices: [mac, iphone, ipad, web]
description: Stop the notifications for one session or for a workflow's runs, and keep the session in Needs You.
---

# Mute the notifications for a session

Mute a session when you do not want an alert each time it needs you. Mute stops only
the alerts. It does not hide the session.

A muted session:

- sends no notification on the Mac, no push to your iPhone or iPad and no banner;
- still goes under **Needs You** when it needs you;
- still counts on the Dock badge, the app icon badge, the widget and the tab's title;
- shows a bell with a slash (🔕) beside its title.

You can also mute a workflow. Then each of its runs is a muted session.

## Before you start

- A host that can mute. An older host does not show the **Mute Notifications** item.

## Mute a session

1. Find the session in the sidebar.
2. Open its menu:
   - On the Mac, right-click its row, or choose **Session ▸ Mute Notifications** with the
     session open.
   - On the iPhone and iPad, touch and hold its row, or open the chat and tap **···**.
   - In a browser, open the chat and click **···**.
3. Choose **Mute Notifications**. The bell with a slash shows beside the title.

To send its notifications again, do the same steps and choose **Unmute Notifications**.

## Mute a workflow's runs

1. Open the workflow's menu in the sidebar, or open its page.
2. Choose **Mute Notifications**. On the workflow's page on the iPhone and iPad, turn on
   **Mute Notifications**.

The app writes `muted: true` into the workflow's file. Its next runs start muted, and
its runs that are not archived are muted too. Unmute takes it out again.

## Related

- [Statuses and groups](../reference/statuses.md#muted): the mark, and what counts on
  the badge.
- [See what needs you from your Home Screen](see-what-needs-you-from-your-home-screen.md)
