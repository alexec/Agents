# Feature Specification: A Project From a Git URL

**Feature Branch**: `027-project-from-git-url`

**Created**: 2026-09-24

**Status**: Draft

**Input**: User description: "Creating a project from a Git URL instead of a path. Basically, checkout the URL into ~/ and that's the project."

## Why this feature exists

A project is a folder. Today the only way to make one is New project in the Projects column, which
opens a folder picker, so the folder has to be on the Mac already. When the work you want an agent
to do lives in a repository you have not cloned yet, you leave the app, open a terminal, work out
where to put it, clone it, come back, click New project, and find the folder you just made.

The app already knows where the folder should go — your home folder, named after the repository —
and nothing about cloning needs a decision from you. So New project should take a Git URL as well as
a folder, clone it into your home folder, and add what it cloned as the project, selected and ready
to be told what to do.

**This feature does not change what a project is.** A project made from a URL is an ordinary
project whose folder happens to have been cloned by the app. Once it exists, nothing treats it
differently.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Paste a URL, get a project (Priority: P1)

Someone has a repository URL — copied from a browser, a chat, an issue. They click New project and
paste the URL instead of choosing a folder. The app clones the repository into their home folder,
in a folder named after the repository, adds that folder as a project, and selects it. They type
what they want done.

**Why this priority**: It is the whole of the request. Everything else is what happens when the
simple case does not hold.

**Independent Test**: With `~/Hello-World` absent, click New project, paste
`https://github.com/octocat/Hello-World.git`, and confirm. Confirm `~/Hello-World` now exists and is
a checkout of that repository, the project list shows it selected, and an agent started in it works
in that folder.

**Acceptance Scenarios**:

1. **Given** the Projects column, **When** the person clicks New project, **Then** they can either choose a folder, as today, or give a Git URL.
2. **Given** a Git URL for a repository they can read, **When** they confirm it, **Then** the repository is cloned into their home folder, in a folder named after the repository, on its default branch.
3. **Given** the clone has finished, **When** it succeeds, **Then** the cloned folder is added as a project and selected, exactly as if it had been chosen with the folder picker.
4. **Given** a clone in progress, **When** the person looks at the Projects column, **Then** they can see that a clone is under way and for which repository, until it finishes or fails.
5. **Given** the clone finished, **When** the person opens the project, **Then** its files pane and agents behave exactly as they do for any other project.

---

### User Story 2 - A clone that cannot happen says why (Priority: P2)

The URL is mistyped, or the repository is private and the Mac has no access to it, or the network is
down, or the folder it would go to is already taken. The person is told, in a sentence, what went
wrong — and nothing half-made is left behind as a project.

**Why this priority**: A clone that fails silently, or leaves an empty folder in the project list,
is worse than not having the feature: the person would go back to the terminal and not trust the
button again.

**Independent Test**: Try each of a malformed URL, a URL to a repository that does not exist, and a
URL whose folder name is already taken in the home folder by something unrelated. Confirm each is
refused with a message naming the problem, no project is added, and nothing already in the home
folder is changed.

**Acceptance Scenarios**:

1. **Given** text that is not a Git URL, **When** the person tries to confirm it, **Then** they are told it is not a URL the app can clone, before anything is attempted.
2. **Given** a URL the clone cannot reach or is not allowed to read, **When** the clone fails, **Then** the person is shown why in plain words, and no project is added.
3. **Given** a clone that failed partway, **When** it has failed, **Then** no partial folder is left in the home folder.
4. **Given** the folder the clone would go to already exists and is not a checkout of that repository, **When** the person confirms the URL, **Then** the app refuses, names the folder that is in the way, and leaves it untouched.

---

### User Story 3 - A repository already cloned becomes the project (Priority: P3)

The person pastes the URL of a repository they cloned into their home folder months ago. There is
nothing to clone. The app sees that the folder is already a checkout of that repository and adds
it as the project, without fetching, pulling, or changing it.

**Why this priority**: It turns the most likely collision into the result the person wanted, and it
means the URL can always be the way in, not only the first time.

**Independent Test**: Clone a repository into `~/` by hand. Paste its URL into New project. Confirm
it becomes the project straight away, and the folder's branch, working changes and history are
exactly as they were.

**Acceptance Scenarios**:

1. **Given** the folder the clone would go to is already a checkout whose remote is the same repository, **When** the person confirms the URL, **Then** that folder is added as the project and selected, and no clone is made.
2. **Given** that folder is already a project, **When** the person confirms the URL, **Then** the existing project is selected, as adding a folder twice does today.
3. **Given** that folder is an archived project, **When** the person confirms the URL, **Then** it is brought back and selected, as adding it by folder does today.
4. **Given** the existing checkout, **When** it is used, **Then** nothing in it — branch, working changes, commits — is altered.

---

### Edge Cases

- **Two spellings of the same repository**: an HTTPS URL and an SSH URL for the same host and path,
  with or without a trailing `.git`, count as the same repository for User Story 3.
- **Folder name**: taken from the last part of the URL's path with any `.git` removed, keeping its
  case (`Hello-World.git` → `~/Hello-World`). A URL with no usable last part is refused as not a
  URL the app can clone.
- **Two clones at once**: the person may start a second clone while one is running. Two clones into
  the same folder are not allowed; the second is refused as the folder being in the way.
- **The person quits or the daemon restarts mid-clone**: the partial folder is removed and no
  project is added. The clone is not resumed; the person pastes the URL again.
- **A very large repository**: the clone runs as long as it needs to; the progress in the Projects
  column is how the person knows it is still going.
- **Credentials**: the clone needs a password or passphrase it cannot get without asking. It fails
  with a message saying the repository needs credentials the Mac does not have, rather than waiting
  for input nobody can see.
- **Empty repository**: a repository with no commits clones to an empty checkout; that is still a
  valid project.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: New project MUST offer, beside choosing a folder, a way to give a Git URL.
- **FR-002**: The app MUST accept HTTPS URLs, SSH URLs (`ssh://…` and the `git@host:path` form), and MUST refuse anything else before starting a clone.
- **FR-003**: A URL MUST be cloned into the person's home folder, in a folder named after the last part of the URL's path with any `.git` suffix removed.
- **FR-004**: The clone MUST be of the repository's default branch, with its full history.
- **FR-005**: When the clone succeeds, the cloned folder MUST be added as a project and selected, through the same path as adding a folder by hand, so that everything true of an added folder is true of it.
- **FR-006**: While a clone is running, the Projects column MUST show that it is running and for which repository.
- **FR-007**: When a clone fails, the person MUST be shown the reason in plain words, no project MUST be added, and any folder the clone created MUST be removed.
- **FR-008**: If the destination folder exists and is a checkout of the same repository, it MUST be added as the project without cloning, fetching, or changing it.
- **FR-009**: If the destination folder exists and is anything else, the app MUST refuse, name the folder, and leave it untouched. The app MUST NOT overwrite, merge into, or rename anything already in the home folder.
- **FR-010**: A clone MUST use the credentials the person's Mac already has for Git (keychain, SSH agent, configured helpers) and MUST NOT wait on an interactive prompt; one that would need one fails as FR-007.
- **FR-011**: A clone interrupted by the app or daemon stopping MUST leave no partial folder and no project behind.
- **FR-012**: A project made from a URL MUST be indistinguishable afterwards from one added by folder.

### Key Entities

- **Git URL**: what the person gives instead of a folder. Names a host and a repository path; determines the destination folder's name.
- **Clone in progress**: a repository being fetched into the home folder. Has a URL, a destination folder, and ends in either a project or a stated failure. Not a project until it succeeds.
- **Project**: unchanged — a folder the app works in. A clone that succeeds becomes one.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: From a copied URL to a selected project ready for a prompt takes one click, one paste, and one confirmation, with no terminal and no folder picker.
- **SC-002**: A small repository (under 10 MB) becomes a project within 15 seconds on an ordinary connection.
- **SC-003**: In every failure case listed in User Story 2 and Edge Cases, zero projects are added and zero files outside the clone's own folder are created, changed, or removed.
- **SC-004**: Pasting the URL of a repository already cloned into the home folder selects it as the project in under 2 seconds, with the checkout byte-for-byte unchanged.
- **SC-005**: Every failure shows a message a person can act on without reading a log.

## Assumptions

- **The home folder, directly** (`~/<name>`), as the request says — not a subfolder such as `~/Developer` or `~/src`. Choosing a different parent is out of scope for this version.
- **Mac only.** The phone and iPad do not add projects today, and this does not change that.
- **Git is installed** on the Mac; if it is not, the clone fails with a message saying so (FR-007).
- **No choice of branch, depth or folder name.** The default branch, full history, the name from the URL. A person who wants otherwise can still clone by hand and choose the folder.
- **No new credential handling.** Access to private repositories is whatever the Mac's Git already has.
- **Submodules** are not initialised; that is left to the person or an agent.
- **A clone belongs to the Mac, not the window**: like adding a project today, a clone started in one window shows in every window, and closing the window does not cancel it.
