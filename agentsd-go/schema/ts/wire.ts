export interface Wire {
    agent?:             Agent;
    listRequest?:       ListRequest;
    optionsResponse?:   OptionsResponse;
    permissionRequest?: PermissionRequest;
    projectSummary?:    ProjectSummary;
    promptRequest?:     PromptRequest;
    runtimeStatus?:     RuntimeStatus;
    startRequest?:      StartRequest;
    transcriptEntry?:   TranscriptEntry;
    transcriptPage?:    TranscriptPage;
    turnsPage?:         TurnsPage;
    [property: string]: any;
}

export interface Agent {
    additionalDirectories?: string[];
    advertisedOptions:      ConfigOption[];
    afterTurn?:             AfterTurn;
    archivedAt?:            number;
    archivedReason?:        AgentArchivedReason;
    archiveRequest?:        ArchiveRequest;
    availableCommands:      SlashCommand[];
    background?:            BackgroundItem[];
    chainDepth?:            number;
    costCeiling?:           Cost;
    costToDate?:            { [key: string]: number };
    createdAt:              number;
    cwd:                    string;
    effectiveSandbox?:      EffectiveSandbox;
    endedReason?:           EndedReason;
    eventWait?:             EventWait;
    id:                     string;
    isUnread?:              boolean;
    labels?:                SessionLabel[];
    lastActivityAt:         number;
    lastTurnUsage?:         TurnUsage;
    listsLeftOut?:          boolean;
    madeInRoot?:            string;
    mcpServers?:            MCPServer[];
    missingFolder?:         MissingFolder;
    outcomeAsked?:          boolean;
    pendingMove?:           PendingMove;
    pendingSandboxFailure?: SandboxFailureRecord;
    persona?:               string;
    plans?:                 Plan[];
    purpose?:               AgentPurpose;
    queuedPrompts?:         QueuedPrompt[];
    queuedStart?:           QueuedStart;
    report?:                WorkReport;
    reportSeenAt?:          number;
    restartPickUps?:        number;
    runtimeID:              string;
    runtimeSessionID?:      string;
    runtimeTitle?:          string;
    sandboxOverride?:       SandboxChoice;
    startedByAgent?:        string;
    startedByRun?:          string;
    startedByWorkflow?:     string;
    startingPoint?:         StartingPoint;
    startOptions:           StartOptions;
    startRequestID?:        string;
    state:                  AgentState;
    suggestedPrompts?:      SuggestedPrompt[];
    title?:                 string;
    titleIsPersons?:        boolean;
    tokenCeiling?:          number;
    tokensToDate?:          number;
    usage?:                 Usage;
    worktree?:              AgentWorktree;
}

/**
 * ConfigOption (Model/Options.swift), as its encode(to:) writes it: `type` is the kind's
 * wire name, and `options` is a flat list for one unnamed group, else the groups.
 */
export interface ConfigOption {
    category?:     string;
    currentValue?: any;
    description?:  string;
    id:            string;
    name:          string;
    options?:      ConfigChoice[];
    /**
     * "select", "boolean", or a kind this build doesn't know, carried as itself.
     */
    type: string;
}

export interface ConfigChoice {
    description?: string;
    name?:        string;
    value?:       any;
    group?:       string;
    options?:     PurpleConfigChoice[];
}

export interface PurpleConfigChoice {
    description?: string;
    name:         string;
    value:        any;
}

export type AfterTurn = "request_archive" | "archive";

export interface ArchiveRequest {
    whenTurnEnds?: WhenTurnEnds;
    requested?:    Requested;
}

export interface Requested {
    at: number;
}

export interface WhenTurnEnds {
    since: number;
}

export type AgentArchivedReason = "byUser" | "byAgent";

export interface SlashCommand {
    description?: string;
    inputHint?:   string;
    name:         string;
}

export interface BackgroundItem {
    canStop:         boolean;
    command?:        string;
    detail?:         string;
    endedAt?:        number;
    id:              string;
    isStopping:      boolean;
    kind:            BackgroundItemKind;
    lastToolName?:   string;
    name:            string;
    outputFilePath?: string;
    parentID?:       string;
    startedAt:       number;
    state:           BackgroundItemState;
    summary?:        string;
    taskType?:       string;
    toolCallID?:     string;
}

export type BackgroundItemKind = "task" | "subagent";

export type BackgroundItemState = "running" | "paused" | "completed" | "failed" | "stopped" | "disconnected";

export interface Cost {
    amount:   number;
    currency: string;
}

export interface EffectiveSandbox {
    reason?:   string;
    requested: SandboxChoice;
    state:     SandboxState;
}

export type SandboxChoice = "runtime" | "on" | "off";

export type SandboxState = "on" | "off" | "runtimeControlled" | "none";

export type EndedReason = "endTurn" | "maxTokens" | "maxTurnRequests" | "refusal" | "cancelled" | "processDied" | "daemonGone" | "costLimit" | "unrecognised" | "stoppedByAgent" | "signInRefused" | "runtimeError" | "allowanceSpent" | "rateLimited" | "sandboxFailed" | "imported";

export interface EventWait {
    deadline?:       number;
    ending?:         EventWaitEnding;
    from:            number;
    id:              string;
    patterns:        EventPattern[];
    resumePromptID?: string;
    serverEvents?:   WaitServerEvent[];
    since:           number;
}

export interface EventWaitEnding {
    matched?:      Matched;
    timedOut?:     { [key: string]: any };
    cancelled?:    Cancelled;
    couldNotWake?: CouldNotWake;
}

export interface Cancelled {
    by: EventWaitEndingCanceller;
}

export type EventWaitEndingCanceller = "agent" | "person" | "prompt" | "stopped" | "archived" | "archiveRequested";

export interface CouldNotWake {
    reason: string;
}

export interface Matched {
    extraMatches: number;
    position:     number;
}

/**
 * EventPattern (Model/EventPattern.swift), as its encode(to:) writes it (073): `filters`
 * holds every filter as one string, a list joined by `|` so an older build reads it as a
 * value that never matches, and `anyOf` holds the lists whole. Read `anyOf` over `filters`.
 */
export interface EventPattern {
    anyOf?:  { [key: string]: string[] };
    filters: { [key: string]: string };
    name:    string;
}

export interface WaitServerEvent {
    servers: string[];
    trigger: MCPEventTrigger;
}

export interface MCPEventTrigger {
    arguments: { [key: string]: any };
    event:     string;
    servers?:  string[];
}

export interface SessionLabel {
    addedAt: number;
    owner:   SessionLabelOwner;
    value:   string;
}

export type SessionLabelOwner = "person" | "agent";

export interface TurnUsage {
    cachedReadTokens?:  number;
    cachedWriteTokens?: number;
    cost?:              Cost;
    inputTokens:        number;
    outputTokens:       number;
    thoughtTokens?:     number;
    totalTokens:        number;
}

export interface MCPServer {
    name:      string;
    transport: MCPServerTransport;
}

export interface MCPServerTransport {
    stdio?: Stdio;
    http?:  Http;
    sse?:   Sse;
}

export interface Http {
    headers: { [key: string]: string };
    url:     string;
}

export interface Sse {
    headers: { [key: string]: string };
    url:     string;
}

export interface Stdio {
    args:    string[];
    command: string;
    env:     { [key: string]: string };
}

export interface MissingFolder {
    branchKept: boolean;
}

export interface PendingMove {
    askedAt:        number;
    askedBy:        SessionLabelOwner;
    discardChanges: boolean;
    removeLeft:     boolean;
    target:         MoveTarget;
}

export interface MoveTarget {
    newWorktree?:   NewWorktree;
    existing?:      MoveTargetExisting;
    projectFolder?: { [key: string]: any };
}

export interface MoveTargetExisting {
    _0: string;
}

export interface NewWorktree {
    name?: string;
}

export interface SandboxFailureRecord {
    completedToolCalls: number;
    detail:             string;
    hang:               boolean;
    recoveryOffered:    boolean;
    runtimeID:          string;
}

export interface Plan {
    at:      number;
    entries: PlanEntry[];
    planID?: string;
    state:   PlanState;
}

export interface PlanEntry {
    content:  string;
    priority: PlanEntryPriority;
    status:   PlanEntryStatus;
}

export type PlanEntryPriority = "high" | "medium" | "low";

export type PlanEntryStatus = "pending" | "in_progress" | "completed";

export type PlanState = "current" | "withdrawn";

export interface AgentPurpose {
    providerDraft: ProviderDraft;
}

export interface ProviderDraft {
    id: string;
}

export interface QueuedPrompt {
    attachments: Attachment[];
    from:        PromptOrigin;
    hops?:       number;
    id:          string;
    preface?:    string;
    queuedAt:    number;
    sender?:     MessageSender;
    text:        string;
}

export interface Attachment {
    block:       ContentBlock;
    byteCount?:  number;
    displayName: string;
    id:          string;
}

/**
 * ContentBlock (ACP/ContentBlock.swift): the protocol's own block shapes, as sent. A block
 * of a kind this build doesn't know is written back as it came, so any other `type` may
 * arrive.
 */
export interface ContentBlock {
    text?:        string;
    type:         ContentBlockType;
    data?:        string;
    mimeType?:    string;
    uri?:         string;
    annotations?: ContentBlockAnnotations;
    name?:        string;
    size?:        number;
    resource?:    Resource;
}

export interface ContentBlockAnnotations {
    audience?: string[];
    priority?: number;
}

export interface Resource {
    blob?:     string;
    mimeType?: string;
    text?:     string;
    uri:       string;
}

export type ContentBlockType = "text" | "image" | "audio" | "resource_link" | "resource";

export type PromptOrigin = "person" | "app" | "agent";

export interface MessageSender {
    agentID: string;
    title:   string;
}

export interface QueuedStart {
    labels:          string[];
    model?:          string;
    permissionMode?: string;
    runtimeID?:      string;
    worktree?:       WorktreeChoice;
}

export interface WorktreeChoice {
    new?:      { [key: string]: any };
    existing?: WorktreeChoiceExisting;
    named?:    Named;
    branch?:   Branch;
}

export interface Branch {
    _0: string;
}

export interface WorktreeChoiceExisting {
    _0: string;
}

export interface Named {
    _0: string;
}

export interface WorkReport {
    at:      number;
    block?:  Block;
    message: string;
    outcome: WorkOutcome;
}

export interface Block {
    checkAgainAt?: number;
    clearedAt?:    number;
    clearedBy?:    BlockClearing;
    waits:         Wait[];
    wakeOn?:       BlockWakeOn;
}

export type BlockClearing = "waits" | "time" | "dropped";

export interface Wait {
    agentID:      string;
    ending?:      WaitEnding;
    nameAtReport: string;
}

export interface WaitEnding {
    at:  number;
    how: WaitEndingHow;
}

export interface WaitEndingHow {
    finished?: Finished;
    stopped?:  Stopped;
    archived?: { [key: string]: any };
    gone?:     { [key: string]: any };
}

export interface Finished {
    message?: string;
    outcome?: WorkOutcome;
}

export type WorkOutcome = "done" | "nothing_to_do" | "needs_answer" | "partly_done" | "stuck" | "blocked";

export interface Stopped {
    _0?: EndedReason;
}

export type BlockWakeOn = "any" | "all";

export interface StartOptions {
    extraArguments: string[];
    values:         { [key: string]: any };
}

export interface StartingPoint {
    commit:     string;
    repository: string;
}

export type AgentState = "starting" | "running" | "waitingOnUser" | "finished" | "stopped" | "archived" | "queued";

export interface SuggestedPrompt {
    id:     string;
    label:  string;
    prompt: string;
}

export interface Usage {
    at:    number;
    cost?: Cost;
    size:  number;
    used:  number;
}

export interface AgentWorktree {
    base?:     string;
    branch?:   string;
    madeByApp: boolean;
    name:      string;
    project:   string;
    root:      string;
}

export interface ListRequest {
    after?:             ListCursor;
    agentID?:           string;
    archivedCommands:   boolean;
    archivedOnly:       boolean;
    folder?:            string;
    includeArchived:    boolean;
    lean:               boolean;
    limit?:             number;
    query?:             string;
    startedByWorkflow?: string;
}

export interface ListCursor {
    id:             string;
    lastActivityAt: number;
}

export interface OptionsResponse {
    commands: SlashCommand[];
    draftID:  string;
    options:  ConfigOption[];
}

export interface PermissionRequest {
    agentID:   string;
    askedAt:   number;
    id:        string;
    options:   PermissionOption[];
    subagent?: string;
    toolCall:  ToolCall;
}

export interface PermissionOption {
    kind:     PermissionOptionKind;
    name:     string;
    optionID: string;
}

export type PermissionOptionKind = "allow_once" | "allow_always" | "reject_once" | "reject_always" | "unknown";

export interface ToolCall {
    content:     ToolCallContent[];
    kind?:       string;
    locations:   ToolCallLocation[];
    name?:       string;
    raw?:        any;
    rawInput?:   any;
    rawOutput?:  any;
    status?:     string;
    title:       string;
    toolCallID?: string;
}

/**
 * ToolCallContent (ACP/ToolCallContent.swift): the protocol's shapes, as sent. Anything
 * else is written back as it came, so another `type` may arrive.
 */
export interface ToolCallContent {
    content?:    ContentBlock;
    type:        ToolCallContentType;
    newText?:    string;
    oldText?:    string;
    path?:       string;
    terminalId?: string;
}

export type ToolCallContentType = "content" | "diff" | "terminal";

export interface ToolCallLocation {
    line?: number;
    path:  string;
}

export interface ProjectSummary {
    approvals?:       Approval[];
    costToDate:       { [key: string]: number };
    counts:           Counts;
    exists:           boolean;
    guardedChanges?:  GuardedChange[];
    isChat?:          boolean;
    lastActivityAt:   number;
    name:             string;
    project:          Project;
    retiredCount:     number;
    unmeasuredAgents: number;
}

export interface Approval {
    actions:  ApprovalAction[];
    agentID?: string;
    digest?:  string;
    key:      string;
    kind:     ApprovalKind;
    line:     string;
    since?:   number;
    title:    string;
}

export type ApprovalAction = "approve" | "deny" | "requestChanges" | "dismiss";

export type ApprovalKind = "mcpServer" | "workflow" | "plugin" | "file" | "archive" | "workflowFailed";

export interface Counts {
    archived?:       number;
    blocked?:        number;
    finished?:       number;
    needsAttention?: number;
    running?:        number;
    stopped?:        number;
    waiting?:        number;
}

export interface GuardedChange {
    askedIn?:     string;
    byGit:        boolean;
    changedBy:    string[];
    changedByIDs: string[];
    digest?:      string;
    path:         string;
    since:        number;
}

export interface Project {
    addedAt:        number;
    archivedAt?:    number;
    diskSpace?:     DiskThresholds;
    folder:         string;
    helperLimits?:  HelperLimits;
    laidOutAt?:     number;
    layoutVersion?: number;
    pinned?:        boolean;
}

export interface DiskThresholds {
    criticalGB?: number;
    lowGB?:      number;
    lowPercent?: number;
}

export interface HelperLimits {
    agentsMayArchive?: boolean;
    notArchived?:      number;
    queued?:           number;
    running?:          number;
}

export interface PromptRequest {
    agentID:     string;
    attachments: Attachment[];
    from:        PromptOrigin;
    sendID?:     string;
    text:        string;
}

export interface RuntimeStatus {
    availability: RuntimeAvailability;
    checkedAt:    number;
    isOut?:       boolean;
    outdated:     boolean;
    poolNote?:    string;
    runtime:      Runtime;
}

export interface RuntimeAvailability {
    available?:     Available;
    missing?:       Missing;
    needsSignIn?:   NeedsSignIn;
    failed?:        RuntimeAvailabilityFailed;
    installing?:    Installing;
    installFailed?: InstallFailed;
}

export interface Available {
    path:           string;
    supportsResume: boolean;
}

export interface RuntimeAvailabilityFailed {
    reason: string;
}

export interface InstallFailed {
    reason: string;
}

export interface Installing {
    progress?: string;
}

export interface Missing {
    lookedIn: string[];
}

export interface NeedsSignIn {
    authMethods: string[];
    fixCommand?: string;
}

export interface Runtime {
    arguments:       string[];
    executable:      string;
    id:              string;
    install?:        RuntimeInstall;
    installPage:     string;
    name:            string;
    usesAppCopyOnly: boolean;
}

export interface RuntimeInstall {
    toolset?:   Toolset;
    script?:    Script;
    npmGlobal?: NpmGlobal;
}

export interface NpmGlobal {
    package: string;
}

export interface Script {
    shell: string;
    url:   string;
}

export interface Toolset {
    runtimeID: string;
}

export interface StartRequest {
    additionalDirectories: string[];
    attachments:           Attachment[];
    cwd:                   string;
    draftID?:              string;
    labels:                string[];
    mcpServers:            MCPServer[];
    persona?:              string;
    prompt:                string;
    purpose?:              AgentPurpose;
    requestID?:            string;
    runtimeID:             string;
    sandbox?:              SandboxChoice;
    startOptions:          StartOptions;
    worktree?:             WorktreeChoice;
}

export interface TranscriptEntry {
    at:          number;
    id:          string;
    kind:        TranscriptEntryKind;
    sender?:     MessageSender;
    subagentID?: string;
}

export interface TranscriptEntryKind {
    userMessage?:         UserMessage;
    agentMessage?:        AgentMessage;
    agentThought?:        AgentThought;
    toolCall?:            TranscriptEntryKindToolCall;
    toolCallUpdate?:      ToolCallUpdate;
    planUpdated?:         PlanUpdated;
    usageRecorded?:       UsageRecorded;
    servedRequest?:       ServedRequest;
    elicitationAsked?:    ElicitationAsked;
    elicitationAnswered?: ElicitationAnswered;
    compaction?:          Compaction;
    notice?:              Notice;
    permissionAsked?:     PermissionAsked;
    permissionAnswered?:  PermissionAnswered;
    optionChanged?:       OptionChanged;
    stateChanged?:        StateChanged;
    background?:          Background;
    workReported?:        WorkReported;
    runtimeNote?:         RuntimeNote;
    poolSwitch?:          PoolSwitch;
    sandboxFailure?:      SandboxFailure;
    handoff?:             Handoff;
    settingsChanged?:     SettingsChanged;
    appView?:             AppView;
    fileShown?:           FileShown;
}

export interface AgentMessage {
    blocks?:    ContentBlock[];
    messageID?: string;
    text:       string;
}

export interface AgentThought {
    messageID?: string;
    text:       string;
}

export interface AppView {
    _0: AppViewCall;
}

export interface AppViewCall {
    arguments?:  any;
    id:          string;
    pinnable?:   boolean;
    reason?:     string;
    resourceUri: string;
    result?:     any;
    server:      string;
    state:       AppViewCallState;
    tool:        string;
}

export type AppViewCallState = "running" | "done" | "cancelled";

export interface Background {
    _0: BackgroundItem;
}

export interface Compaction {
    error?:  string;
    id?:     string;
    status:  string;
    summary: ContentBlock[];
}

export interface ElicitationAnswered {
    answers?: ElicitationAnswer[];
    id:       string;
    summary:  string;
}

export interface ElicitationAnswer {
    answer:   string;
    question: string;
}

export interface ElicitationAsked {
    _0: ElicitationRequest;
}

export interface ElicitationRequest {
    agentID:        string;
    askedAt:        number;
    elicitationID?: string;
    id:             string;
    message?:       string;
    mode:           ElicitationRequestMode;
    scope:          ElicitationRequestScope;
}

export interface ElicitationRequestMode {
    form?: Form;
    url?:  Url;
}

export interface Form {
    _0: ElicitationSchema;
}

export interface ElicitationSchema {
    description?: string;
    properties:   ElicitationSchemaProperty[];
    title?:       string;
}

export interface ElicitationSchemaProperty {
    defaultValue?: any;
    description?:  string;
    isRequired:    boolean;
    kind:          ElicitationSchemaPropertyKind;
    name:          string;
    title?:        string;
}

export interface ElicitationSchemaPropertyKind {
    string?:      String;
    number?:      Number;
    integer?:     Integer;
    boolean?:     { [key: string]: any };
    multiSelect?: MultiSelect;
}

export interface Integer {
    maximum?: number;
    minimum?: number;
}

export interface MultiSelect {
    items:     ElicitationSchemaPropertyChoice[];
    maxItems?: number;
    minItems?: number;
}

export interface ElicitationSchemaPropertyChoice {
    description?: string;
    title:        string;
    value:        string;
}

export interface Number {
    maximum?: number;
    minimum?: number;
}

export interface String {
    choices?:   ElicitationSchemaPropertyChoice[];
    format?:    ElicitationSchemaPropertyFormat;
    maxLength?: number;
    minLength?: number;
}

export type ElicitationSchemaPropertyFormat = "email" | "uri" | "date" | "date-time";

export interface Url {
    _0: string;
}

export type ElicitationRequestScope = "session" | "request";

export interface FileShown {
    _0: ShownFile;
}

export interface ShownFile {
    chart?: ChartHint;
    line?:  number;
    path:   string;
}

export interface ChartHint {
    color?: string;
    mark:   ChartMark;
    title?: string;
    x:      string;
    y:      string;
}

export type ChartMark = "bar" | "line" | "point" | "area";

export interface Handoff {
    characters: number;
    markdown:   string;
}

export interface Notice {
    _0: SessionNotice;
}

export interface SessionNotice {
    detail?:  string;
    severity: string;
    title:    string;
}

export interface OptionChanged {
    id:    string;
    value: any;
}

export interface PermissionAnswered {
    optionID:    string;
    optionName?: string;
}

export interface PermissionAsked {
    _0: PermissionRequest;
}

export interface PlanUpdated {
    _0: Plan;
}

export interface PoolSwitch {
    _0: SwitchRecord;
}

export interface SwitchRecord {
    agentID:        string;
    at:             number;
    billing:        Payment;
    carried:        CarriedSetting[];
    dropped:        Dropped[];
    from:           SwitchRecordSide;
    fromReturnsAt?: number;
    id:             string;
    reason:         SwitchRecordReason;
    shortened?:     number;
    to:             SwitchRecordSide;
}

export interface Payment {
    allowance?:  Allowance;
    freeTier?:   FreeTier;
    freeCredit?: FreeCredit;
    prepaid?:    Prepaid;
}

export interface Allowance {
    label?: string;
}

export interface FreeCredit {
    amount?:  Cost;
    expires?: number;
}

export interface FreeTier {
    reset: ResetRule;
}

export interface ResetRule {
    dailyAt?: DailyAt;
    unknown?: { [key: string]: any };
}

export interface DailyAt {
    hour:     number;
    timeZone: string;
}

export interface Prepaid {
    amount?:  Cost;
    expires?: number;
}

export interface CarriedSetting {
    from?:    any;
    name:     string;
    optionID: string;
    source:   CarriedSettingSource;
    to?:      any;
}

export interface CarriedSettingSource {
    level?:           Level;
    sameValue?:       { [key: string]: any };
    poolEntry?:       { [key: string]: any };
    remembered?:      { [key: string]: any };
    runtimeDefault?:  { [key: string]: any };
    strictestMode?:   { [key: string]: any };
    closestNoLooser?: { [key: string]: any };
    person?:          { [key: string]: any };
}

export interface Level {
    _0: string;
}

export interface Dropped {
    extraArguments?:     ExtraArguments;
    alwaysAllow?:        AlwaysAllow;
    queuedSlashCommand?: QueuedSlashCommand;
}

export interface AlwaysAllow {
    count: number;
}

export interface ExtraArguments {
    _0: string[];
}

export interface QueuedSlashCommand {
    _0: string;
}

export interface SwitchRecordSide {
    entryID?:  string;
    mode?:     any;
    model?:    any;
    runtimeID: string;
}

export type SwitchRecordReason = "allowanceSpent" | "overage" | "creditUsedUp" | "rateLimitPersisted" | "runtimeFailed" | "everyoneOutResumed" | "byHand";

export interface RuntimeNote {
    _0: string;
}

export interface SandboxFailure {
    _0: SandboxFailureRecord;
}

export interface ServedRequest {
    _0: The0_Class;
}

export interface The0_Class {
    kind:    ServedRequestKind;
    outcome: ServedRequestOutcome;
}

export interface ServedRequestKind {
    readFile?:   ReadFile;
    writeFile?:  WriteFile;
    runCommand?: RunCommand;
}

export interface ReadFile {
    path: string;
}

export interface RunCommand {
    args:    string[];
    command: string;
}

export interface WriteFile {
    byteCount: number;
    path:      string;
}

export interface ServedRequestOutcome {
    served?:  { [key: string]: any };
    refused?: Refused;
    failed?:  ServedRequestOutcomeFailed;
}

export interface ServedRequestOutcomeFailed {
    message: string;
}

export interface Refused {
    reason: string;
}

export interface SettingsChanged {
    _0: SwitchRecord;
}

export interface StateChanged {
    _0:      AgentState;
    reason?: EndedReason;
}

export interface TranscriptEntryKindToolCall {
    _0: ToolCall;
}

export interface ToolCallUpdate {
    _0: ToolCall;
}

export interface UsageRecorded {
    _0: TurnUsage;
}

export interface UserMessage {
    _0:      string;
    blocks?: ContentBlock[];
    from?:   PromptOrigin;
}

export interface WorkReported {
    _0: WorkReport;
}

export interface TranscriptPage {
    entries:    TranscriptEntry[];
    firstIndex: number;
    total:      number;
}

export interface TurnsPage {
    firstTurn: number;
    openStart: number;
    turns:     TurnSummary[];
}

export interface TurnSummary {
    ask?:     TranscriptEntry;
    concise?: TranscriptEntry[];
    end:      number;
    id:       string;
    last?:    TranscriptEntry;
    outcome?: TranscriptEntry[];
    start:    number;
    steps?:   number;
    usage?:   TurnUsage;
}
