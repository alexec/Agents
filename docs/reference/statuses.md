---
diataxis: reference
devices: [mac, iphone, ipad]
description: Every status an agent can have, the group it is listed under, and what you can do from there.
---

# Statuses and groups

This page lists every status an agent can show, and the group it sits under on its
project's page. The groups appear in this order: **Needs attention**, **Blocked**,
**Waiting**, **Working**, **Complete**, **Stopped**, **Parked**. A group with no agents in it is not
shown. **Archived** is folded away at the bottom until you open it.

The status is what the agent's icon says when you hover over it, and what a screen reader
reads. The Mac, iPhone and iPad use the same words. Only **Needs attention** is drawn in
colour.

| Status | Group | What it means | What you can do |
| --- | --- | --- | --- |
| **Starting** | Working | The agent has been made and its first turn is about to begin. | **Stop**, **Park**, **Archive**, **Branch**. |
| **Working** | Working | A turn is in progress. | **Stop**, **Park**, **Archive**, **Branch**. A prompt you send waits until the turn ends, unless you click **Send now** on it. |
| **Coming back after a restart** | Working | The app is bringing the conversation back by itself after the app or the Mac restarted. | **Stop**. |
| **Waiting on you** | Needs attention | The agent has asked you something in the middle of its turn, such as permission to run a command, and is paused until you answer. | Answer the card above the prompt. **Stop**, **Park**, **Archive**, **Branch**. It stays under Needs attention until you answer. |
| **Waiting on your answer** | Needs attention | The turn ended with a question for you. | Reply in the prompt. **Park**, **Archive**, **Branch**. |
| **Partly done** | Needs attention | The turn ended with some of the work done; the rest needs a decision from you. | Reply in the prompt. **Park**, **Archive**, **Branch**. |
| **Stuck** | Needs attention | The turn ended without the work done, and the agent says why. | Reply in the prompt. **Park**, **Archive**, **Branch**. |
| Any status but Stopped, Parked or Archived, once the agent has shown you a file | Needs attention | The agent opened a file for you to look at, and you have not looked. | Open the conversation. |
| **Blocked** | Blocked | The turn ended blocked on something the app cannot watch, such as a review, and the agent named no agents and gave no time to check again. Nothing carries it on but you. Its icon is a raised hand. | **Carry on**, once the block has gone. **Stop**, **Park**, **Archive**, **Branch**. |
| **Waiting** | Waiting | The agent is waiting on something the app watches: agents it started, a time to check again, or an event such as checks passing. The card says what it is waiting for. It carries on by itself when that comes, so you need not do anything. Its icon is an hourglass. | **Carry on**, to tell it the wait is over early. **Stop**, so it does not carry on. **Park**, **Archive**, **Branch**. |
| **Complete** | Complete | The agent did what was asked. On the project page and sessions list, Complete is drawn as **Unread** (finished since you last looked) above **Read**. | Reply in the prompt. **Park**, **Archive**, **Branch**. |
| **Nothing to do** | Complete | The agent looked and found nothing that needed doing. Listed under **Unread** or **Read** with the rest of Complete. | Reply in the prompt. **Park**, **Archive**, **Branch**. |
| **Finished** | Complete | The turn ended and the agent has not said how it went. Listed under **Unread** or **Read**. | Reply in the prompt. **Park**, **Archive**, **Branch**. |
| **Finished without saying how it went** | Complete | The turn ended, the app asked the agent how it went, and it still did not say. Listed under **Unread** or **Read**. | Reply in the prompt. **Park**, **Archive**, **Branch**. |
| **Stopped**, or why it stopped | Stopped | The turn was cut short. The reason is one of: **Stopped by you**, **Stopped by the agent that started it**, **Ran out of room**, **Hit its limit**, **Refused**, **The runtime crashed**, **Stopped with the daemon**, **Reached its cost limit**, **Its allowance ran out**, **Rate limited, and still limited after retrying**, **Stopped for a reason we do not know**. With a pool, a chat whose allowance ran out carries on with another runtime instead of staying here. | Reply in the prompt to start a new turn. **Park**, **Archive**, **Branch**. |
| **Waiting for an allowance** | Stopped | Every runtime in the pool was out, and the chat waits for the first that said when it is back, then carries on by itself. Its icon is grey, with a banknote mark (not the Waiting hourglass), and the Pool page lists it. | **Stop waiting** on the Pool page, or reply in the prompt. **Stop**, **Park** or **Archive** end the wait too. |
| **Parked** | Parked | You put the conversation down to come back to later. The card says when, such as **Parked 3 days ago**. It stays parked even if its turn ends wanting you, unless it asks you something mid-turn. | **Unpark**, to put it back in its group. **Archive**, **Branch**. |
| **Parks when this turn ends** | Where it is now | You parked a conversation while its turn was still going. It moves to **Parked** when the turn ends. | **Unpark**, to cancel. **Stop**, **Archive**, **Branch**. |
| **Archived** | Archived | You, or the agent that started it, put it away. If the app made a worktree for it and everything in it is committed, the worktree is removed; its branch is deleted too if it was merged. | **Bring Back**. |

**Show in Finder** is on every agent's menu on the Mac.

## The phone's connection

The line at the top of the iPhone and iPad screens says how they are reaching the Mac.

| Line | What it means | What works |
| --- | --- | --- |
| No line | On the Mac's network, connected directly. | Everything. |
| **Away** — slower, through iCloud | On another network, reaching the Mac through your iCloud. | Everything but the terminal, the live page, files and attaching pictures, which say **Needs the same network as your Mac**. |
| **Away** — slower than usual | As above, while iCloud has asked the app to slow down. | As above, more slowly. |
| The relay needs iCloud on your iPhone and your Mac | One of them is not signed in to iCloud, or not to the same account. | Only the Mac's own network. |
| iCloud is full, so the relay can't carry messages | Your iCloud storage is full. | Only the Mac's own network. |
| Last heard from your Mac … | Neither way reaches the Mac: it is asleep, or the bridge is not running. What is shown is dimmed and offers nothing. | Nothing, until it answers. |
| Not connected to your Mac yet | The app has not reached the Mac since it opened. If it has not paired, the page says **Pair with your Mac**, with a button to scan the code the Mac shows in Settings ▸ Devices. | Nothing, until it answers. |

## See also

- [How-to guides](../how-to/index.md)
- [Explanation](../explanation/index.md)
