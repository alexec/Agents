// The words of a folder's Connectors set-up and the one Connect sheet (#1336), ported from
// ConnectorSetupWords in AgentsKitCore so the Mac, the Remote and the page say the same.
import type {
  Connection, ConnectionBot, ConnectionBotCompleteRequest, ConnectionProvider, ConnectionSignIn, ConnectionSignInCompleteRequest, UUID, ConnectorEvents, ConnectorProof, ConnectorSetup, ConnectorSlot, ConnectorSlotKind, DocsServer, MessagingServer,
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
  if (!repository) return `What agents in ${folder} can reach. It has no GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps remote.`;
  return `What agents in ${folder} can reach. Repository ${site}/${repository}, from its git remote.`;
}

// The forge (#1632, #3752, #3785, #3802): GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps fills Tasks, Code review and CI, as the Mac's words.

/** The forge, GitHub when the host did not say. */
export function forgeOf(setup: ConnectorSetup): ConnectionProvider {
  return setup.forge ?? "github";
}

/** The forge's name when this page does not know it (a newer host's, #3802), else undefined. */
export function unknownForgeOf(setup: ConnectorSetup): string | undefined {
  const f: string | undefined = setup.forge;
  return f !== undefined && !(providers as readonly string[]).includes(f) ? f : undefined;
}

/** The card in place of Connect for a forge this page can't connect: the Mac's ConnectorSetupWords.unknownForge. */
export function unknownForge(setup: ConnectorSetup): string {
  return `${setup.site ?? "github.com"} is on a forge this version of Agents can't connect (${unknownForgeOf(setup) ?? "unknown"}). Update Agents to set it up here.`;
}

export function connectTitleFor(forge: ConnectionProvider): string {
  if (forge === "forgejo") return forgejo.connectTitle;
  if (forge === "bitbucket") return bitbucket.connectTitle;
  if (forge === "azuredevops") return azureDevOps.connectTitle;
  return forge === "gitlab" ? "Connect GitLab once: issues, merge requests and pipelines." : connectTitle;
}

export function connectNoteFor(forge: ConnectionProvider): string {
  return forge === "gitlab" || forge === "forgejo" || forge === "bitbucket" || forge === "azuredevops" ? `Your connection, for every folder. It reaches what your ${name(forge)} account can see.` : connectNote;
}

export function connectAgain(forge: ConnectionProvider): string {
  return `${name(forge)} asks you to connect again.`;
}

export function comesWith(forge: ConnectionProvider): string {
  return `Comes with the ${name(forge)} connection.`;
}

export const noRemote = "No GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps remote";

/** The button on a refused slot, and where it goes: the App's install on GitHub, the repository on GitLab, Forgejo, Bitbucket and Azure DevOps. */
export function grantButton(setup: ConnectorSetup): string {
  return forgeOf(setup) === "github" ? "Grant on github.com" : `Open on ${setup.site ?? site(forgeOf(setup))}`;
}

export function grantURL(setup: ConnectorSetup): string | undefined {
  return forgeOf(setup) === "github" ? setup.installURL : setup.repositoryURL;
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
  return { tasks: "Tasks", codeReview: "Code review", ci: "CI", docs: "Docs", messaging: "Messaging", workspace: "Where agents run" }[kind];
}

/** The slots a folder's project can set (#2669): the forge's three, not Docs or Where agents run. */
export function isProjects(kind: ConnectorSlotKind): boolean {
  return kind === "tasks" || kind === "codeReview" || kind === "ci";
}

/** The Docs slot (#3248), as the window's ConnectorSetupWords.Docs. */
export const docs = {
  question: "Where do your docs live?",
  none: "No docs yet in specs/, docs/ or a *.md file at the top.",
  /** The docs connectors the page has no catalogue for (#3425): on the Mac, or not here yet. */
  addElsewhere: (hasMac: boolean): string => hasMac
    ? "Confluence, Notion, Google Drive and other docs connectors: add them on the Mac, in Add Connector…."
    : "Confluence, Notion, Google Drive and other docs connectors: the web page cannot add them yet.",
  servers: (names: string[]): string | undefined => names.length ? `Connectors: ${names.join(", ")}` : undefined,
  /** One docs connector's line (#3307): the first doc its one search found, or why not. */
  serverLine: (s: DocsServer): string => `${s.name}: ${{
    read: s.proof ? `found “${s.proof.title}”` : "searched, and found no doc.",
    notRead: "searching…",
    noMap: "no map of its search yet. Ask an agent to map it (the map-a-docs-server skill).",
    failed: s.message ?? "the search didn't work.",
  }[s.state]}`,
};

/** The Messaging slot (#1787), as the window's ConnectorSetupWords.Messaging. */
export const messaging = {
  question: "Where do agents reach you?",
  /** The chat connectors the page has no catalogue for: on the Mac, or not here yet. */
  addElsewhere: (hasMac: boolean): string => hasMac
    ? "Slack, Email, Google Chat and other chat connectors: add them on the Mac, in Add Connector…."
    : "Slack, Email, Google Chat and other chat connectors: the web page cannot add them yet.",
  noneNote: "Agents reach you in the app only.",
  /** The line of a slot that is None: with no connector yet, or skipped with some. */
  noneLine: (skipped: boolean): string => skipped
    ? "Agents reach you in the app only. Its connectors stay, and their events with them."
    : "Agents reach you in the app only. Add a Slack, email or chat connector to reach you there too.",
  /** One messaging connector's line: what its one read found and the events it declares, or why not. */
  serverLine: (s: MessagingServer): string => {
    const label = s.word === s.name ? s.name : `${s.word} (${s.name})`;
    let words = {
      read: `read ${s.proof?.title ?? "it"}`,
      notRead: "reading…",
      failed: s.message ?? "the read didn't work.",
    }[s.state];
    if (s.state === "read" && s.events?.length) words += `; events ${s.events.join(", ")}`;
    return `${label}: ${words}`;
  },
};

export function title(slot: ConnectorSlot): string {
  if (slot.state === "skipped" && slot.slot === "messaging") return "None";
  if (slot.state === "skipped") return "Skipped";
  if (slot.state === "noRemote" && slot.slot === "tasks") return "Choose a tracker";
  return slot.choice;
}

export function line(slot: ConnectorSlot, folder: string, repository: string | undefined, onMac: boolean,
  forge: ConnectionProvider = "github"): string {
  const repo = repository ?? folder;
  const gitlab = forge === "gitlab", checks = forge === "forgejo" || forge === "bitbucket", azure = forge === "azuredevops";
  switch (slot.state) {
    case "skipped":
      return {
        tasks: "Agents won't use issues here. Nothing is turned on.",
        codeReview: gitlab ? "Agents won't use merge requests here. Nothing is turned on." : "Agents won't use pull requests here. Nothing is turned on.",
        ci: "Agents won't wait on checks here. Nothing is turned on.",
        docs: "Agents won't look for docs before they work. Nothing is turned on.",
        messaging: messaging.noneLine((slot.servers ?? []).length > 0),
        workspace: "Agents run on this Mac.",
      }[slot.slot];
    case "noRemote":
      return `${folder} has no GitHub, GitLab, Forgejo, Bitbucket or Azure DevOps remote, so ${slot.choice} can't be read for it.`;
    case "failed":
    case "refused":
      return slot.message ?? "The read didn't work.";
    case "notRead":
      return "Reading…";
    case "read":
      return {
        tasks: azure ? `No work items yet in ${repo}'s project.` : `No issues yet in ${repo}.`,
        codeReview: gitlab ? `No merge requests yet in ${repo}.` : `No pull requests yet in ${repo}.`,
        ci: gitlab ? `No pipelines yet in ${repo}.` : azure ? `No builds yet in ${repo}.` : checks ? `No checks yet on ${repo}'s default branch.` : `No workflow runs yet in ${repo}.`,
        docs: docs.none,
        messaging: "",
        workspace: onMac ? "Nothing to set up. Other places are set up in Providers." : otherProvidersElsewhere,
      }[slot.slot];
    case "notConnected":
      return {
        tasks: azure ? `Agents read, file and close work items in ${repo}'s project. ${comesWith(forge)}`
          : `Agents read, file and close issues in ${repo}. ${comesWith(forge)}`,
        codeReview: gitlab ? `Agents read merge requests and answer their comments. ${comesWith(forge)}`
          : `Agents open pull requests and answer reviews. ${comesWith(forge)}`,
        ci: gitlab || azure ? `Agents see pipelines pass and fail, and wait on them. ${comesWith(forge)}`
          : `Agents see checks pass and fail, and wait on them. ${comesWith(forge)}`,
        docs: docs.none,
        messaging: messaging.noneLine(false),
        workspace: "Nothing to set up.",
      }[slot.slot];
  }
}

export function proofLead(kind: ConnectorSlotKind): string {
  return kind === "ci" ? "Last run" : kind === "messaging" ? "Read" : "Newest";
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

/** The Tasks slot's way to Jira (#3304): the Atlassian connection first, then its connector. */
export const connectJira = "Connect Jira…";
/** The Messaging slot's Email (#1787): the connection its connector reads. */
export const connectEmail = "Connect Email…";

/** The Tasks slot's other trackers: the page has no catalogue. With no Mac, it says so (#3425). */
export function otherTrackers(linearConnected: boolean, hasMac: boolean): string {
  if (!hasMac) return "The web page cannot add a tracker's connector yet.";
  return linearConnected ? "Linear and other trackers: Add Connector on the Mac."
    : "Then add its connector, or another tracker's, with Add Connector on the Mac.";
}

/** Where agents run, with GitHub connected: Codespaces is a provider, on the Mac or here (#3425). */
export function codespacesElsewhere(hasMac: boolean): string {
  return hasMac ? "GitHub Codespaces: Set up on the Mac."
    : "GitHub Codespaces: add it in Settings ▸ Machine providers, with Add Provider….";
}

/** The providers a person connects, in the order Connectors shows them. */
export const providers: ConnectionProvider[] = ["github", "linear", "gitlab", "email", "atlassian", "forgejo", "bitbucket", "azuredevops"];

/**
 * The providers that host can connect, in this page's order: the ones its connections/list says (#3824),
 * less any this page does not know. A host older than #3824 says none: it connects GitHub, Linear,
 * GitLab, Atlassian and, when it has connections.email/1 (#1780), Email.
 */
export function providersFor(hasEmail: boolean, hostProviders?: readonly string[]): ConnectionProvider[] {
  const takes: readonly string[] = hostProviders ?? ["github", "linear", "gitlab", "atlassian", ...(hasEmail ? ["email"] : [])];
  return providers.filter((p) => takes.includes(p));
}

/** The connections to providers this page knows: a newer host's other ones are left out (#3802). */
export function knownConnections(list: readonly Connection[]): Connection[] {
  return list.filter((c) => (providers as readonly string[]).includes(c.provider));
}

/** The provider's name: GitHub, Linear, GitLab, Email, Atlassian (Jira and Confluence, #3304), Forgejo, Bitbucket, Azure DevOps. */
export function name(p: ConnectionProvider): string {
  return { github: "GitHub", linear: "Linear", gitlab: "GitLab", email: "Email", atlassian: jira.provider, forgejo: forgejo.name, bitbucket: bitbucket.name, azuredevops: azureDevOps.name }[p];
}

/** The provider's letters on its mark. */
export function letters(p: ConnectionProvider): string {
  return { github: "GH", linear: "L", gitlab: "GL", email: "EM", atlassian: jira.letters, forgejo: forgejo.letters, bitbucket: bitbucket.letters, azuredevops: azureDevOps.letters }[p];
}

/** The device page's site, for "Open github.com Again". Email has no device page; Forgejo's is Codeberg's, Bitbucket's bitbucket.org, Azure DevOps's dev.azure.com. */
export function site(p: ConnectionProvider): string {
  return { github: "github.com", linear: "linear.app", gitlab: "gitlab.com", email: "", atlassian: jira.site, forgejo: "codeberg.org", bitbucket: "bitbucket.org", azuredevops: "dev.azure.com" }[p];
}

export function connectionTitle(c: Connection): string {
  return c.login ? `${name(c.provider)} · ${c.login}` : name(c.provider);
}

/**
 * The kind of token a GitHub connection uses (#3857), as the Mac's `GitHubTokens`. The App's user
 * token is the default: it can do only what both the person and the App can, and each post shows
 * the App's badge. A personal access token, the fallback, has all the rights the person gave it.
 */
export const githubTokens = {
  app: "App user token · renews by itself · posts show the App",
  personal: "Personal access token · posts show no App",
};

export function connectionNote(c: Connection, now: Date = new Date()): string {
  // An email connection: the IMAP server and an app password, which does not end (#1780).
  if (c.provider === "email") return [c.workspace, email.passwordLabel].filter((x): x is string => !!x).join(" · ");
  if (c.state === "signInAgain") {
    return c.expiresAt === undefined ? `${name(c.provider)} refused the renewal: sign in again`
      : "The access token ended: connect again with a new one";
  }
  // GitHub says which token it uses (#3857): the App's user token, or the person's own.
  if (c.provider === "github") {
    return c.byToken ? githubTokens.personal + (c.expiresAt !== undefined ? ` · ${tokenEnds(fromWireDate(c.expiresAt), now)}` : "")
      : githubTokens.app;
  }
  const how = c.expiresAt !== undefined ? `Access token · ${tokenEnds(fromWireDate(c.expiresAt), now)}`
    : c.provider === "forgejo" ? forgejo.how : c.provider === "bitbucket" ? bitbucket.how
    : c.provider === "azuredevops" ? azureDevOps.how : c.byToken ? jira.tokenWay : "OAuth · renews by itself";
  return [c.workspace, how].filter((x): x is string => !!x).join(" · ");
}

/** When an access token ends, such as "ends 18 Oct 2027", as the Mac says it. */
export function tokenEnds(at: Date, now: Date = new Date()): string {
  if (at <= now) return "ended";
  // The host keeps the end of GitLab's last day (midnight after it): say that day.
  return `ends ${new Date(at.getTime() - 1000).toLocaleDateString("en-GB", { day: "numeric", month: "short", year: "numeric", timeZone: "UTC" })}`;
}

/** Whether a connection ended (#3407): the provider refused its renewal, or its token's end has passed. As the Mac's `hasEnded`. */
export function hasEnded(c: Connection, now: Date = new Date()): boolean {
  return c.state === "signInAgain" || (c.expiresAt !== undefined && fromWireDate(c.expiresAt) <= now);
}

/** The connections that ended, in the list's order. */
export function endedConnections(list: readonly Connection[], now: Date = new Date()): Connection[] {
  return list.filter((c) => hasEnded(c, now));
}

/** What a Connectors row's tooltip says of them: "Your GitLab connection ended". Undefined with none. */
export function endedLine(ended: readonly Connection[]): string | undefined {
  const names = ended.map((c) => name(c.provider));
  if (names.length === 0) return undefined;
  if (names.length === 1) return `Your ${names[0]} connection ended`;
  return `Your ${names.slice(0, -1).join(", ")} and ${names[names.length - 1]} connections ended`;
}

/** A provider with no connection yet, on Connectors. */
export function notConnectedNote(p: ConnectionProvider): string {
  return {
    github: "Issues, pull requests and Actions in every folder.",
    linear: "Linear issues in every folder, and their events.",
    gitlab: "Merge requests, pipelines and issues on gitlab.com or your own GitLab.",
    email: "One mailbox for agents: they wait for mail, such as a sign-up code, and read it.",
    atlassian: jira.notConnectedNote,
    forgejo: forgejo.notConnectedNote,
    bitbucket: bitbucket.notConnectedNote,
    azuredevops: azureDevOps.notConnectedNote,
  }[p];
}

/** The button that opens the Connect sheet for a provider. */
export function connectButtonFor(p: ConnectionProvider): string {
  return p === "atlassian" ? connectJira : `Connect ${name(p)}…`;
}

export function disconnectNoteFor(p: ConnectionProvider): string {
  if (p === "github") return disconnectNote;
  if (p === "gitlab") return gitlab.disconnectNote;
  if (p === "email") return email.disconnectNote;
  if (p === "atlassian") return jira.disconnectNote;
  if (p === "forgejo") return forgejo.disconnectNote;
  if (p === "bitbucket") return bitbucket.disconnectNote;
  if (p === "azuredevops") return azureDevOps.disconnectNote;
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

/** codeberg.org: the field's example, and where Make a Token goes with no address. */
export const codeberg = "https://codeberg.org";

/**
 * Connect Forgejo (#3752): an access token on Codeberg or any Forgejo or Gitea. Forgejo has no
 * device page, so the dialog has one way in. The Mac's ConnectorSetupWords.Forgejo.
 */
export const forgejo = {
  name: "Forgejo",
  letters: "FJ",
  title: "Connect Forgejo",
  connectTitle: "Connect Forgejo once: issues, pull requests and checks.",
  notConnectedNote: "Pull requests, checks and issues on Codeberg or your own Forgejo or Gitea.",
  subtitle: "For you, in every folder. Agents talks to Forgejo's API directly.",
  abilities: [
    "Read and write pull requests and their comments",
    "Read checks (commit statuses)",
    "Read and write issues",
  ],
  tokenIntro: "Codeberg, or your own Forgejo or Gitea: make an access token with read and write on repository and issue, and read on user, and paste it here.",
  addressLabel: "Forgejo address",
  addressPrompt: codeberg,
  tokenLabel: "Access token",
  tokenPrompt: "Paste the token",
  tokenButton: "Connect",
  newTokenButton: "Make a Token on Forgejo",
  checking: "Checking the token with Forgejo…",
  choose: "The token does not end. You can take it back on Forgejo ▸ Settings ▸ Applications, or with Disconnect on Connectors.",
  how: "Access token",
  disconnectNote: "Disconnect deletes the machine's token. Every folder's Forgejo slots wait for a connection again. Forgejo's events stop until you connect again or set FORGEJO_TOKEN. To revoke it too, go to Forgejo ▸ Settings ▸ Applications.",
};

/** The address Connect Again… opens with: the connection's Forgejo. The Mac's ConnectorSetupWords.Forgejo.again. */
export function forgejoAgain(c: Connection): string {
  return c.workspace ? `${new URL(codeberg).protocol}//${c.workspace}` : "";
}

/** Where the person makes a token on the Forgejo at address (Codeberg when empty), opened in a new tab. */
export function newForgejoTokenURL(address: string): string {
  const typed = address.trim();
  let root = new URL(codeberg);
  if (typed) {
    try {
      root = new URL(typed.includes("://") ? typed : `${root.protocol}//${typed}`);
    } catch {
      // Not an address: Codeberg's page.
    }
  }
  const path = root.pathname.replace(/\/+$/, "").replace(/\/api\/v1$/, "");
  return `${root.origin}${path}/user/settings/applications`;
}

/**
 * Connect Bitbucket (#3785): a token on Bitbucket Cloud, as the bitbucket server takes it: an
 * Atlassian API token with its account's email, or a repository, project or workspace access
 * token with no email. Bitbucket has no device page. The Mac's ConnectorSetupWords.Bitbucket.
 */
export const bitbucket = {
  name: "Bitbucket",
  letters: "BB",
  title: "Connect Bitbucket",
  connectTitle: "Connect Bitbucket once: issues, pull requests and checks.",
  notConnectedNote: "Pull requests, checks and issues on Bitbucket Cloud.",
  subtitle: "For you, in every folder. Agents talks to Bitbucket Cloud's API directly.",
  abilities: [
    "Read and write pull requests and their comments",
    "Read checks (Pipelines and other commit statuses)",
    "Read and write issues",
  ],
  tokenIntro: "Make an Atlassian API token with the Bitbucket scopes and give its account's email. Or paste a repository, project or workspace access token, and leave the email empty.",
  emailLabel: "Atlassian email",
  emailPrompt: "Empty for an access token",
  tokenLabel: "Token",
  tokenPrompt: "Paste the token",
  tokenButton: "Connect",
  newTokenButton: "Make an API Token on Atlassian",
  newTokenURL: "https://id.atlassian.com/manage-profile/security/api-tokens",
  checking: "Checking the token with Bitbucket…",
  choose: "An API token ends on the date you gave it. You can take it back at id.atlassian.com ▸ Security ▸ API tokens (an access token in the repository's settings), or with Disconnect on Connectors.",
  how: "Token",
  disconnectNote: "Disconnect deletes the machine's token. Every folder's Bitbucket slots wait for a connection again. Bitbucket's events stop until you connect again or set BITBUCKET_TOKEN. To revoke it too, go to id.atlassian.com ▸ Security ▸ API tokens, or the repository's Access tokens.",
};

/**
 * Connect Azure DevOps (#3802): a personal access token on one organization of dev.azure.com or
 * one collection of an Azure DevOps Server. No device page for Agents. The Mac's
 * ConnectorSetupWords.AzureDevOps.
 */
export const azureDevOps = {
  name: "Azure DevOps",
  letters: "AZ",
  title: "Connect Azure DevOps",
  connectTitle: "Connect Azure DevOps once: work items, pull requests and pipelines.",
  notConnectedNote: "Pull requests, pipelines and work items on dev.azure.com or your own Azure DevOps Server.",
  subtitle: "For you, in every folder. Agents talks to Azure DevOps's API directly.",
  abilities: [
    "Read and write pull requests and their comments",
    "Read Azure Pipelines builds",
    "Read and write Azure Boards work items",
  ],
  tokenIntro: "In your organization, open User settings ▸ Personal access tokens, make a token with Code (read and write), Build (read) and Work Items (read and write), and paste it here with the organization.",
  addressLabel: "Organization",
  addressPrompt: "dev.azure.com/your-organization",
  tokenLabel: "Personal access token",
  tokenPrompt: "Paste the token",
  tokenButton: "Connect",
  newTokenButton: "Make a Token on Azure DevOps",
  checking: "Checking the token with Azure DevOps…",
  choose: "The token ends on the date you gave it. You can take it back in User settings ▸ Personal access tokens, or with Disconnect on Connectors.",
  how: "Personal access token",
  disconnectNote: "Disconnect deletes the machine's token. Every folder's Azure DevOps slots wait for a connection again. Azure DevOps's and Azure Boards' events stop until you connect again or set AZURE_DEVOPS_TOKEN. To revoke it too, go to User settings ▸ Personal access tokens in the organization.",
};

/** Azure DevOps Services: Make a Token's page with no organization. */
export const azureDevOpsServices = "https://dev.azure.com";

/**
 * Where the person makes a token in the organization at address: its User settings ▸ Personal
 * access tokens (dev.azure.com's own when no organization is given). The Mac's AzureDevOps.newTokenURL.
 */
export function newAzureDevOpsTokenURL(address: string): string {
  const services = `${azureDevOpsServices}/`;
  let typed = address.trim();
  if (!typed) return services;
  if (!/[./:]/.test(typed)) typed = `dev.azure.com/${typed}`;
  let url: URL;
  try {
    url = new URL(typed.includes("://") ? typed : `${new URL(azureDevOpsServices).protocol}//${typed}`);
  } catch {
    return services;
  }
  const host = url.hostname.toLowerCase();
  let parts = url.pathname.split("/").filter((p) => p);
  let origin = url.origin;
  if (host.endsWith(".visualstudio.com") && host !== "vs-ssh.visualstudio.com") {
    parts = [host.slice(0, -".visualstudio.com".length)];
    origin = azureDevOpsServices;
  } else if (host === "dev.azure.com") {
    parts = parts.slice(0, 1);
  }
  return `${origin}/${[...parts, "_usersSettings", "tokens"].join("/")}`;
}

/**
 * The one token sheet (#3802): Connect Forgejo, Connect Bitbucket and Connect Azure DevOps, each
 * with its own words and its one field beside the token (an address, sent as url, or an email,
 * sent as user). The Mac's ConnectorSetupWords.TokenSheet.
 */
export interface TokenSheet {
  provider: ConnectionProvider;
  title: string;
  intro: string;
  field: "url" | "user";
  fieldLabel: string;
  fieldPrompt: string;
  fieldType: "url" | "email" | "text";
  tokenLabel: string;
  tokenPrompt: string;
  newTokenButton: string;
  checking: string;
  newTokenURL: (field: string) => string;
  again: (c: Connection) => string;
}

/** The token sheet of a provider that has one: Forgejo, Bitbucket and Azure DevOps. */
export function tokenSheet(p: ConnectionProvider): TokenSheet | undefined {
  switch (p) {
    case "forgejo":
      return { provider: p, title: forgejo.title, intro: forgejo.tokenIntro, field: "url", fieldLabel: forgejo.addressLabel,
        fieldPrompt: forgejo.addressPrompt, fieldType: "url", tokenLabel: forgejo.tokenLabel, tokenPrompt: forgejo.tokenPrompt,
        newTokenButton: forgejo.newTokenButton, checking: forgejo.checking, newTokenURL: newForgejoTokenURL, again: forgejoAgain };
    case "bitbucket":
      return { provider: p, title: bitbucket.title, intro: bitbucket.tokenIntro, field: "user", fieldLabel: bitbucket.emailLabel,
        fieldPrompt: bitbucket.emailPrompt, fieldType: "email", tokenLabel: bitbucket.tokenLabel, tokenPrompt: bitbucket.tokenPrompt,
        newTokenButton: bitbucket.newTokenButton, checking: bitbucket.checking, newTokenURL: () => bitbucket.newTokenURL, again: () => "" };
    case "azuredevops":
      return { provider: p, title: azureDevOps.title, intro: azureDevOps.tokenIntro, field: "url", fieldLabel: azureDevOps.addressLabel,
        fieldPrompt: azureDevOps.addressPrompt, fieldType: "text", tokenLabel: azureDevOps.tokenLabel, tokenPrompt: azureDevOps.tokenPrompt,
        newTokenButton: azureDevOps.newTokenButton, checking: azureDevOps.checking, newTokenURL: newAzureDevOpsTokenURL,
        again: (c) => c.workspace ?? "" };
    default:
      return undefined;
  }
}

/** A token sheet's connections/sign-in/token request: the field as its url or user, left out when empty. */
export function tokenRequest(sheet: TokenSheet, field: string, token: string):
  { provider: ConnectionProvider; url?: string; user?: string; token: string } | undefined {
  const value = field.trim(), typed = token.trim();
  if (!typed) return undefined;
  return value ? { provider: sheet.provider, [sheet.field]: value, token: typed } : { provider: sheet.provider, token: typed };
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

/**
 * Connect Jira (#3304): one Atlassian sign-in for Jira and Confluence (#3248), by Atlassian
 * Cloud's page, or a token on one Jira site. The connection is Atlassian's; the sheet says Jira.
 * The same words as the Mac's (ConnectorSetupWords.Jira).
 */
export const jira = {
  provider: "Atlassian",
  letters: "JI",
  title: "Connect Jira",
  site: "atlassian.com",
  notConnectedNote: "Jira issues and Confluence docs, with one sign-in.",
  subtitle: "For you, in every folder. One Atlassian sign-in for Jira and Confluence.",
  abilities: [
    "Read Jira issues, their comments and their history",
    "Read Confluence pages and spaces, for the Docs slot",
    "Know your account, to find the issues assigned to you",
  ],
  choose: "On atlassian.com you choose the site. You can take it back at id.atlassian.com ▸ Connected apps, or with Disconnect on Connectors.",
  continueButton: "Continue on atlassian.com",
  waiting: "Waiting for atlassian.com… Approve there, and Agents comes back by itself.",
  signInWay: "Atlassian Cloud",
  tokenWay: "API token",
  tokenIntro: "For Jira Data Center, or Jira Cloud without the sign-in. On Jira Cloud, make an API token at id.atlassian.com and give your email. On Data Center, make a personal access token and leave the email empty.",
  siteLabel: "Jira site",
  sitePrompt: "example.atlassian.net",
  emailLabel: "Email",
  emailPrompt: "you@example.com (Jira Cloud only)",
  tokenLabel: "Token",
  tokenPrompt: "API token or personal access token",
  tokenButton: "Connect",
  newTokenURL: "https://id.atlassian.com/manage-profile/security/api-tokens",
  newTokenButton: "Make an API Token on Atlassian",
  checking: "Checking the token with Jira…",
  disconnectNote: "Disconnect deletes the machine's tokens. Jira's events stop until you connect again or set JIRA_API_TOKEN. To revoke Agents too, go to id.atlassian.com ▸ Connected apps.",
  tasksNote: (hasMac: boolean): string => hasMac ? "Connect Jira, then add its connector on the Mac."
    : "Connect Jira. The web page cannot add its connector yet.",
  done: "Done",
};

/** The sheet's line once Jira is connected: where, and as whom. */
export function jiraConnected(c: Connection): string {
  return `Connected${c.workspace ? ` to ${c.workspace}` : ""} as ${c.login ?? "you"}.`;
}

/** The one real read that proves the Jira connection: the site's newest issue. */
export function jiraProof(c: Connection, now: Date = new Date()): string {
  return c.newest ? `Newest issue: ${proofText(c.newest, now)}` : "No issues read yet: the site has none, or the token cannot see them.";
}

/** The connections/sign-in/token request for Jira: the site and the token trimmed, the email only when given. */
export function jiraTokenRequest(site: string, email: string, token: string): { provider: "atlassian"; url: string; user?: string; token: string } | undefined {
  const url = site.trim(), user = email.trim(), typed = token.trim();
  if (!url || !typed) return undefined;
  return user ? { provider: "atlassian", url, user, token: typed } : { provider: "atlassian", url, token: typed };
}

/** The connections/sign-in/email request, with the server and the user trimmed. The password goes as typed. */
export function emailRequest(server: string, user: string, password: string): { server: string; user: string; password: string } | undefined {
  const s = server.trim();
  const u = user.trim();
  if (!s || !u || !password) return undefined;
  return { server: s, user: u, password };
}

/** The sheet's subtitle, list and button, by provider. */
export function sheetSubtitleFor(p: ConnectionProvider): string {
  return { github: sheetSubtitle, linear: linear.subtitle, gitlab: gitlab.subtitle, email: email.subtitle, atlassian: jira.subtitle, forgejo: forgejo.subtitle, bitbucket: bitbucket.subtitle, azuredevops: azureDevOps.subtitle }[p];
}

export function abilitiesFor(p: ConnectionProvider): string[] {
  return { github: abilities, linear: linear.abilities, gitlab: gitlab.abilities, email: email.abilities, atlassian: jira.abilities, forgejo: forgejo.abilities, bitbucket: bitbucket.abilities, azuredevops: azureDevOps.abilities }[p];
}

export function sheetChooseFor(p: ConnectionProvider): string {
  return { github: sheetChoose, linear: linear.choose, gitlab: gitlab.choose, email: email.choose, atlassian: jira.choose, forgejo: forgejo.choose, bitbucket: bitbucket.choose, azuredevops: azureDevOps.choose }[p];
}

export function continueButtonFor(p: ConnectionProvider): string {
  return { github: continueButton, linear: linear.continueButton, gitlab: gitlab.continueButton, email: email.button, atlassian: jira.continueButton, forgejo: forgejo.tokenButton, bitbucket: bitbucket.tokenButton, azuredevops: azureDevOps.tokenButton }[p];
}

export function sheetStatus(s: ConnectionSignIn): string {
  switch (s.status) {
    case "waiting":
      if (s.grant === "authorizationCode") return s.provider === "atlassian" ? jira.waiting : linear.waiting;
      return `Waiting for ${site(s.provider)}… Type the code there, then approve.`;
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

/**
 * The person's agents' bot (#3858): a GitHub App of their own, so agents post as
 * <login>-agents[bot] and not as the person. ConnectorSetupWords.Bot's words.
 */
export const botWords = {
  title: "Agents' bot",
  makeButton: "Make My Agents' Bot…",
  sheetTitle: "Make your agents' bot",
  notMade: "Your agents post as you. A bot of their own posts as <login>-agents[bot], and names you.",
  abilities: [
    "Read and write code, on branches and pull requests",
    "Open and comment on issues and pull requests",
    "Read checks and statuses, and run workflows again",
  ],
  never: "Never: change workflows, secrets, environments, settings or members. Those stay yours.",
  publicToggle: "Organisations can install it",
  publicHelp: "Turn on to use the bot on an organisation's repositories. The organisation's owner approves the install.",
  keyNote: "GitHub gives the bot's key to this machine only. It never goes to Agents' servers.",
  continueButton: "Continue on github.com",
  waiting: "Waiting for github.com… Choose Create GitHub App there, and Agents comes back by itself.",
  finishing: "Taking the bot's key on this machine…",
  installButton: "Install on Repositories…",
  removeButton: "Forget the Bot…",
  removeTitle: "Forget your agents' bot?",
  removeMessage: "This machine deletes the bot's key, and agents post as you again. The App stays on GitHub until you delete it there.",
};

/** The bot's line under the GitHub row: its name, and where it is installed. */
export function botNote(bot: ConnectionBot): string {
  if (!bot.made) return botWords.notMade;
  const name = bot.name ?? "Your bot";
  const list = bot.installations;
  if (!list) return bot.message ?? `${name}. GitHub could not be asked where it is installed.`;
  if (list.length === 0) return `${name}, not installed yet: install it on the repositories agents work on.`;
  return `${name}, on ${list.map((i) => `${i.account} (${i.all ? "all" : "chosen"} repositories)`).join(", ")}.`;
}

/** The hand-back page's message after GitHub made the App, for the setup with state only. */
export function botCallback(event: { origin: string; data: unknown }, state: string): ConnectionBotCompleteRequest | undefined {
  const answer = oauthCallback(event, "" as unknown as UUID, state);
  if (!answer) return undefined;
  const out: ConnectionBotCompleteRequest = { state: answer.state };
  if (answer.code) out.code = answer.code;
  if (answer.error) out.error = answer.error;
  return out;
}
