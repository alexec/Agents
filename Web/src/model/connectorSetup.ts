// The words of a folder's Connectors set-up and the one Connect sheet (#1336), ported from
// ConnectorSetupWords in AgentsKitCore so the Mac, the Remote and the page say the same.
import type {
  Connection, ConnectionProvider, ConnectionSignIn, ConnectionSignInCompleteRequest, UUID, ConnectorEvents, ConnectorProof, ConnectorSetup, ConnectorSlot, ConnectorSlotKind,
} from "../protocol/generated";
import { fromWireDate } from "../protocol/dates";

export const connectTitle = "Connect GitHub once: issues, pull requests and Actions.";
export const connectNote = "Your connection, for every folder. You choose on github.com which repositories Agents can see.";
export const abilities = [
  "Read and write issues",
  "Read and write pull requests and reviews",
  "Read checks and Actions runs",
  "Read and push code",
];
export const sheetSubtitle = "For you, in every folder. Agents talks to GitHub's API directly.";
export const sheetChoose = "On github.com you choose which repositories. You can take it back there, or with Disconnect on Connectors.";
export const sheetFoot = "The token is kept by the machine, never in a log.";
export const continueButton = "Continue on github.com";
/** Where the person sees and changes which repositories the App reaches, as the Mac's (#1685). */
export const installationsURL = "https://github.com/settings/installations";
export const otherProvidersElsewhere = "Other providers are set up on the Mac.";
export const disconnectNote = "Disconnect deletes the machine's tokens. Every folder's GitHub slots wait for a connection again. To revoke the App too, go to github.com ▸ Settings ▸ Applications.";

export function intro(folder: string, repository: string | undefined, site = "github.com"): string {
  if (!repository) return `What agents in ${folder} can reach. It has no GitHub or GitLab remote.`;
  return `What agents in ${folder} can reach. Repository ${site}/${repository}, from its git remote.`;
}

// The forge (#1632): GitHub or GitLab fills Tasks, Code review and CI, as the Mac's words.

/** The forge, GitHub when the host did not say. */
export function forgeOf(setup: ConnectorSetup): ConnectionProvider {
  return setup.forge ?? "github";
}

export function connectTitleFor(forge: ConnectionProvider): string {
  return forge === "gitlab" ? "Connect GitLab once: issues, merge requests and pipelines." : connectTitle;
}

export function connectNoteFor(forge: ConnectionProvider): string {
  return forge === "gitlab" ? "Your connection, for every folder. It reaches what your GitLab account can see." : connectNote;
}

export function connectAgain(forge: ConnectionProvider): string {
  return `${name(forge)} asks you to connect again.`;
}

export function comesWith(forge: ConnectionProvider): string {
  return `Comes with the ${name(forge)} connection.`;
}

export const noRemote = "No GitHub or GitLab remote";

/** The button on a refused slot, and where it goes: the App's install on GitHub, the folder on GitLab. */
export function grantButton(setup: ConnectorSetup): string {
  return forgeOf(setup) === "gitlab" ? `Open on ${setup.site ?? "gitlab.com"}` : "Grant on github.com";
}

export function grantURL(setup: ConnectorSetup): string | undefined {
  return forgeOf(setup) === "gitlab" ? setup.repositoryURL : setup.installURL;
}

export function connected(c: Connection): string {
  return c.state === "signInAgain" ? `${name(c.provider)} asks you to sign in again` : `Connected to ${name(c.provider)} as ${c.login ?? "you"}`;
}

export function connectedNote(setup: ConnectorSetup): string {
  const parts = ["Your connection, for every folder"];
  if (setup.repositories != null) parts.push(setup.repositories === 1 ? "sees 1 repository" : `sees ${setup.repositories} repositories`);
  return parts.join(" · ");
}

export function notInstalled(repository: string): string {
  return `The Agents app is not installed on ${repository}, so agents can't write there.`;
}

export function setUpHeading(setup: ConnectorSetup): string {
  return `Set up · ${setup.done} of ${setup.slots.length}`;
}

export function heading(kind: ConnectorSlotKind): string {
  return { tasks: "Tasks", codeReview: "Code review", ci: "CI", workspace: "Where agents run" }[kind];
}

export function title(slot: ConnectorSlot): string {
  if (slot.state === "skipped") return "Skipped";
  if (slot.state === "noRemote" && slot.slot === "tasks") return "Choose a tracker";
  return slot.choice;
}

export function line(slot: ConnectorSlot, folder: string, repository: string | undefined, onMac: boolean,
  forge: ConnectionProvider = "github"): string {
  const repo = repository ?? folder;
  const gitlab = forge === "gitlab";
  switch (slot.state) {
    case "skipped":
      return {
        tasks: "Agents won't use issues here. Nothing is turned on.",
        codeReview: gitlab ? "Agents won't use merge requests here. Nothing is turned on." : "Agents won't use pull requests here. Nothing is turned on.",
        ci: "Agents won't wait on checks here. Nothing is turned on.",
        workspace: "Agents run on this Mac.",
      }[slot.slot];
    case "noRemote":
      return `${folder} has no GitHub or GitLab remote, so ${slot.choice} can't be read for it.`;
    case "failed":
    case "refused":
      return slot.message ?? "The read didn't work.";
    case "notRead":
      return "Reading…";
    case "read":
      return {
        tasks: `No issues yet in ${repo}.`,
        codeReview: gitlab ? `No merge requests yet in ${repo}.` : `No pull requests yet in ${repo}.`,
        ci: gitlab ? `No pipelines yet in ${repo}.` : `No workflow runs yet in ${repo}.`,
        workspace: onMac ? "Nothing to set up. Other places are set up in Providers." : otherProvidersElsewhere,
      }[slot.slot];
    case "notConnected":
      return {
        tasks: `Agents read, file and close issues in ${repo}. ${comesWith(forge)}`,
        codeReview: gitlab ? `Agents read merge requests and answer their comments. ${comesWith(forge)}`
          : `Agents open pull requests and answer reviews. ${comesWith(forge)}`,
        ci: gitlab ? `Agents see pipelines pass and fail, and wait on them. ${comesWith(forge)}`
          : `Agents see checks pass and fail, and wait on them. ${comesWith(forge)}`,
        workspace: "Nothing to set up.",
      }[slot.slot];
  }
}

export function proofLead(kind: ConnectorSlotKind): string {
  return kind === "ci" ? "Last run" : "Newest";
}

export function ago(at: Date, now: Date = new Date()): string {
  const seconds = Math.max(0, (now.getTime() - at.getTime()) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.floor(seconds / 60)} min ago`;
  if (seconds < 86_400) {
    const h = Math.floor(seconds / 3600);
    return h === 1 ? "1 hour ago" : `${h} hours ago`;
  }
  const d = Math.floor(seconds / 86_400);
  return d === 1 ? "yesterday" : `${d} days ago`;
}

export function proofText(proof: ConnectorProof, now: Date = new Date()): string {
  let text = proof.title;
  if (proof.outcome) text += `, ${proof.outcome}`;
  if (proof.number == null && proof.at != null) text += ` ${ago(fromWireDate(proof.at as never), now)}`;
  return text;
}

export function proof(slot: ConnectorSlot, now: Date = new Date()): string | undefined {
  if (!slot.proof) return undefined;
  const number = slot.proof.number != null ? `#${slot.proof.number} ` : "";
  return `${proofLead(slot.slot)}: ${number}${proofText(slot.proof, now)}`;
}

export function eventsLead(events: ConnectorEvents, forge: ConnectionProvider = "github"): string {
  switch (events.state) {
    case "on": return "On for Agents:";
    case "off": return `Off. They go on once a slot has read from ${name(forge)}.`;
    default: return events.message ?? "Not turned on.";
  }
}

export function eventNouns(names: string[]): string[] {
  const nouns: string[] = [];
  for (const name of names) {
    const noun = `${name.split(".")[0]}.*`;
    if (!nouns.includes(noun)) nouns.push(noun);
  }
  return nouns;
}

export function workflowsLead(events: ConnectorEvents): string {
  return events.workflows.length === 0 ? "No workflow here starts on them yet." : "Now usable by";
}

/** The Tasks slot's way to Linear (#1682): the connection first, then its connector. */
export const connectLinear = "Connect Linear…";

/** The Tasks slot's other trackers: the page has no catalogue. */
export function otherTrackers(linearConnected: boolean): string {
  return linearConnected ? "Linear and other trackers: Add Connector on the Mac."
    : "Then add its connector, or another tracker's, with Add Connector on the Mac.";
}

/** The providers a person connects, in the order Connectors shows them. */
export const providers: ConnectionProvider[] = ["github", "linear", "gitlab", "email"];

/** The providers that host can connect: Email only when it has connections.email/1 (#1780). */
export function providersFor(hasEmail: boolean): ConnectionProvider[] {
  return hasEmail ? providers : providers.filter((p) => p !== "email");
}

/** The provider's name: GitHub, Linear, GitLab, Email. */
export function name(p: ConnectionProvider): string {
  return { github: "GitHub", linear: "Linear", gitlab: "GitLab", email: "Email" }[p];
}

/** The provider's letters on its mark. */
export function letters(p: ConnectionProvider): string {
  return { github: "GH", linear: "L", gitlab: "GL", email: "EM" }[p];
}

/** The device page's site, for "Open github.com Again". Email has no device page. */
export function site(p: ConnectionProvider): string {
  return { github: "github.com", linear: "linear.app", gitlab: "gitlab.com", email: "" }[p];
}

export function connectionTitle(c: Connection): string {
  return c.login ? `${name(c.provider)} · ${c.login}` : name(c.provider);
}

export function connectionNote(c: Connection, now: Date = new Date()): string {
  // An email connection: the IMAP server and an app password, which does not end (#1780).
  if (c.provider === "email") return [c.workspace, email.passwordLabel].filter((x): x is string => !!x).join(" · ");
  if (c.state === "signInAgain") {
    return c.expiresAt === undefined ? `${name(c.provider)} refused the renewal: sign in again`
      : "The access token ended: connect again with a new one";
  }
  const how = c.expiresAt === undefined ? "OAuth · renews by itself" : `Access token · ${tokenEnds(fromWireDate(c.expiresAt), now)}`;
  return [c.workspace, how].filter((x): x is string => !!x).join(" · ");
}

/** When an access token ends, such as "ends 18 Oct 2027", as the Mac says it. */
export function tokenEnds(at: Date, now: Date = new Date()): string {
  if (at <= now) return "ended";
  // The host keeps the end of GitLab's last day (midnight after it): say that day.
  return `ends ${new Date(at.getTime() - 1000).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" })}`;
}

/** A provider with no connection yet, on Connectors. */
export function notConnectedNote(p: ConnectionProvider): string {
  return {
    github: "Issues, pull requests and Actions in every folder.",
    linear: "Linear issues in every folder, and their events.",
    gitlab: "Merge requests, pipelines and issues on gitlab.com or your own GitLab.",
    email: "One mailbox for agents: they wait for mail, such as a sign-up code, and read it.",
  }[p];
}

/** The button that opens the Connect sheet for a provider. */
export function connectButtonFor(p: ConnectionProvider): string {
  return `Connect ${name(p)}…`;
}

export function disconnectNoteFor(p: ConnectionProvider): string {
  if (p === "github") return disconnectNote;
  if (p === "gitlab") return gitlab.disconnectNote;
  if (p === "email") return email.disconnectNote;
  return "Disconnect deletes the machine's tokens. Linear's events stop until you connect again or set LINEAR_API_KEY. To revoke Agents too, go to linear.app ▸ Settings ▸ Security & access.";
}

/** Connect Linear (#1343, frame H): the same sheet, its own list. */
export const linear = {
  abilities: [
    "Read and write issues",
    "Read folders and cycles",
    "Comment as you",
  ],
  subtitle: "For you, in every folder. Agents talks to Linear's API directly.",
  choose: "On linear.app you choose the workspace. You can take it back there, or with Disconnect on Connectors.",
  continueButton: "Continue on linear.app",
  waiting: "Waiting for linear.app… Approve there, and Agents comes back by itself.",
  finishing: "Finishing the sign-in…",
};

/** gitlab.com: the field's example, and where Make a Token goes with no address. */
export const gitlabCom = "https://gitlab.com";

/** Connect GitLab (#1630): gitlab.com by its device page, or any GitLab by an access token. */
export const gitlab = {
  abilities: [
    "Read and write merge requests and their comments",
    "Read pipelines and jobs",
    "Read and write issues",
  ],
  subtitle: "For you, in every folder. Agents talks to GitLab's API directly.",
  choose: "GitLab asks for the api scope. You can take it back on GitLab ▸ Preferences ▸ Applications, or with Disconnect on Connectors.",
  continueButton: "Continue on gitlab.com",
  signInWay: "gitlab.com",
  tokenWay: "Access token",
  tokenIntro: "For a self-managed GitLab, or gitlab.com without the sign-in: make a personal access token with the api scope, and paste it here.",
  addressLabel: "GitLab address",
  addressPrompt: gitlabCom,
  tokenLabel: "Access token",
  tokenPrompt: "glpat-…",
  tokenButton: "Connect",
  checking: "Checking the token with GitLab…",
  disconnectNote: "Disconnect deletes the machine's token. Every folder's GitLab slots wait for a connection again. GitLab's events stop until you connect again or set GITLAB_TOKEN. To revoke it too, go to GitLab ▸ Preferences ▸ Applications or Access tokens.",
};

/**
 * How Connect Again… opens for an ended GitLab connection (#1865): on Access token, with its
 * GitLab's address, when it was an access token or a self-managed GitLab; on the gitlab.com
 * sign-in when it was that sign-in. The Mac's ConnectorSetupWords.GitLab.again.
 */
export function gitlabAgain(c: Connection): { withToken: boolean; address: string } {
  if (c.workspace) return { withToken: true, address: `${new URL(gitlabCom).protocol}//${c.workspace}` };
  return c.expiresAt === undefined ? { withToken: false, address: "" } : { withToken: true, address: gitlabCom };
}

/** Where the person makes a token on the GitLab at address (gitlab.com when empty), opened in a new tab. */
export function newGitLabTokenURL(address: string): string {
  const typed = address.trim();
  let root = new URL(gitlabCom);
  if (typed) {
    try {
      root = new URL(typed.includes("://") ? typed : `${root.protocol}//${typed}`);
    } catch {
      // Not an address: gitlab.com's page.
    }
  }
  const path = root.pathname.replace(/\/+$/, "").replace(/\/api\/v4$/, "");
  return `${root.origin}${path}/-/user_settings/personal_access_tokens?name=Agents&scopes=api`;
}

/** Connect Email (#1780): one IMAP mailbox, by an app password that goes to the host only. */
export const email = {
  sheetFoot: "The app password is kept by the machine, never in a log.",
  abilities: [
    "Know when mail comes, by sender and subject",
    "List, search and read messages",
    "Mark messages read and move them to another folder",
  ],
  subtitle: "For you, in every folder. Agents reads the mailbox over IMAP and never sends mail.",
  intro: "Use a mailbox made for agents, not your own. Make an app password for Agents at your mail provider, and give its IMAP server.",
  serverLabel: "IMAP server",
  serverPrompt: "imap.fastmail.com",
  userLabel: "User",
  userPrompt: "agents@example.com",
  passwordLabel: "App password",
  passwordPrompt: "App password",
  button: "Connect",
  checking: "Signing in to the mail server…",
  choose: "Agents can read every message in this mailbox. It never sends, answers or deletes mail. Take the app password back at your mail provider, or with Disconnect on Connectors.",
  disconnectNote: "Disconnect deletes the machine's app password. The email server's events stop until you connect again or set EMAIL_PASSWORD. To revoke it too, delete the app password at your mail provider.",
  failed: "The mail server did not take the sign-in.",
};

/** The connections/sign-in/email request, with the server and the user trimmed. The password goes as typed. */
export function emailRequest(server: string, user: string, password: string): { server: string; user: string; password: string } | undefined {
  const s = server.trim();
  const u = user.trim();
  if (!s || !u || !password) return undefined;
  return { server: s, user: u, password };
}

/** The sheet's subtitle, list and button, by provider. */
export function sheetSubtitleFor(p: ConnectionProvider): string {
  return { github: sheetSubtitle, linear: linear.subtitle, gitlab: gitlab.subtitle, email: email.subtitle }[p];
}

export function abilitiesFor(p: ConnectionProvider): string[] {
  return { github: abilities, linear: linear.abilities, gitlab: gitlab.abilities, email: email.abilities }[p];
}

export function sheetChooseFor(p: ConnectionProvider): string {
  return { github: sheetChoose, linear: linear.choose, gitlab: gitlab.choose, email: email.choose }[p];
}

export function continueButtonFor(p: ConnectionProvider): string {
  return { github: continueButton, linear: linear.continueButton, gitlab: gitlab.continueButton, email: email.button }[p];
}

export function sheetStatus(s: ConnectionSignIn): string {
  switch (s.status) {
    case "waiting":
      return s.grant === "authorizationCode" ? linear.waiting : `Waiting for ${site(s.provider)}… Type the code there, then approve.`;
    case "connected": return "Connected.";
    case "expired": return s.message ?? "The code expired before it was approved. Try again.";
    case "denied": return s.message ?? `The sign-in was cancelled on ${name(s.provider)}.`;
    case "cancelled": return "Cancelled.";
    case "failed": return s.message ?? "The sign-in didn't work.";
  }
}

/** The origin of the hand-back page (deploy/site/www/oauth/callback.js). */
export const oauthCallbackOrigin = "https://oauth.agentloops.dev";

/**
 * The hand-back page's message, as connections/sign-in/complete takes it. Undefined for each
 * other message: one from another origin, of another type, without a state, or for another
 * sign-in (when `state` is given, the state must be the same).
 */
export function oauthCallback(
  event: { origin: string; data: unknown }, flowID: UUID, state?: string,
): ConnectionSignInCompleteRequest | undefined {
  if (event.origin !== oauthCallbackOrigin) return undefined;
  const data = event.data;
  if (!data || typeof data !== "object") return undefined;
  const d = data as { type?: unknown; code?: unknown; state?: unknown; error?: unknown };
  if (d.type !== "agents-oauth-callback" || typeof d.state !== "string" || !d.state) return undefined;
  if (state && d.state !== state) return undefined;
  const answer: ConnectionSignInCompleteRequest = { flowID, state: d.state };
  if (typeof d.code === "string" && d.code) answer.code = d.code;
  if (typeof d.error === "string" && d.error) answer.error = d.error;
  return answer;
}

/** The state in a provider's authorize address, to match the hand-back page's message. */
export function authorizeState(verificationURL: string): string | undefined {
  try {
    return new URL(verificationURL).searchParams.get("state") ?? undefined;
  } catch {
    return undefined;
  }
}
