// Made by scripts/design.sh icons from design/icons.json (#4976); do not edit.
// Lucide 1.72.0 (ISC), at a 1.5 stroke.

/// The one icon set (Paper v2): Lucide's symbols in Icons.xcassets, by meaning.
enum LucideIcons {
    /// Lucide's version, pinned in design/icons.json.
    static let version = "1.72.0"

    /// Every symbol in Icons.xcassets.
    static let names: [String] = [
        "lucide.circle-help",
        "lucide.loader-circle",
        "lucide.circle-pause",
        "lucide.circle-check",
        "lucide.circle-x",
        "lucide.archive",
        "lucide.message-circle",
        "lucide.messages-square",
        "lucide.message-circle-question-mark",
        "lucide.folder",
        "lucide.folder-open",
        "lucide.folder-search",
        "lucide.folder-plus",
        "lucide.workflow",
        "lucide.circle-dot",
        "lucide.git-pull-request",
        "lucide.git-branch",
        "lucide.git-merge",
        "lucide.laptop",
        "lucide.monitor",
        "lucide.server",
        "lucide.hard-drive",
        "lucide.smartphone",
        "lucide.cpu",
        "lucide.user",
        "lucide.circle-user",
        "lucide.users",
        "lucide.user-plus",
        "lucide.user-x",
        "lucide.user-key",
        "lucide.contact",
        "lucide.plug",
        "lucide.puzzle",
        "lucide.layout-grid",
        "lucide.layers",
        "lucide.package",
        "lucide.file-text",
        "lucide.file",
        "lucide.file-question-mark",
        "lucide.file-search",
        "lucide.copy",
        "lucide.clipboard-paste",
        "lucide.square-terminal",
        "lucide.code",
        "lucide.braces",
        "lucide.globe",
        "lucide.compass",
        "lucide.image",
        "lucide.camera",
        "lucide.link",
        "lucide.scan-qr-code",
        "lucide.tag",
        "lucide.building-2",
        "lucide.landmark",
        "lucide.mail",
        "lucide.mail-open",
        "lucide.bell",
        "lucide.bell-off",
        "lucide.house",
        "lucide.calendar",
        "lucide.hammer",
        "lucide.settings",
        "lucide.list-checks",
        "lucide.list-ordered",
        "lucide.list",
        "lucide.menu",
        "lucide.chart-pie",
        "lucide.chart-column",
        "lucide.target",
        "lucide.lightbulb",
        "lucide.brain",
        "lucide.paintbrush",
        "lucide.eye",
        "lucide.eye-off",
        "lucide.wifi-off",
        "lucide.radio",
        "lucide.cloud",
        "lucide.sun",
        "lucide.sunrise",
        "lucide.battery-low",
        "lucide.hourglass",
        "lucide.ticket",
        "lucide.sticky-note",
        "lucide.scroll-text",
        "lucide.at-sign",
        "lucide.hash",
        "lucide.panel-left",
        "lucide.panel-right",
        "lucide.mouse-pointer-click",
        "lucide.hand",
        "lucide.pointer",
        "lucide.ear",
        "lucide.keyboard",
        "lucide.keyboard-off",
        "lucide.droplet",
        "lucide.dot",
        "lucide.square-dot",
        "lucide.chart-gantt",
        "lucide.phone",
        "lucide.clock-fading",
        "lucide.square-pen",
        "lucide.pencil",
        "lucide.arrow-up",
        "lucide.arrow-down",
        "lucide.circle-arrow-down",
        "lucide.arrow-right",
        "lucide.circle-arrow-right",
        "lucide.square-arrow-right",
        "lucide.arrow-up-to-line",
        "lucide.corner-down-right",
        "lucide.arrow-up-down",
        "lucide.maximize-2",
        "lucide.undo-2",
        "lucide.paperclip",
        "lucide.mic",
        "lucide.audio-waveform",
        "lucide.search",
        "lucide.text-search",
        "lucide.zoom-in",
        "lucide.zoom-out",
        "lucide.ellipsis",
        "lucide.circle-ellipsis",
        "lucide.pin",
        "lucide.pin-off",
        "lucide.external-link",
        "lucide.app-window",
        "lucide.rectangle-vertical",
        "lucide.rotate-cw",
        "lucide.refresh-cw",
        "lucide.repeat",
        "lucide.history",
        "lucide.circle-stop",
        "lucide.play",
        "lucide.circle-play",
        "lucide.check",
        "lucide.x",
        "lucide.chevron-right",
        "lucide.chevron-left",
        "lucide.chevron-down",
        "lucide.chevron-up",
        "lucide.chevrons-up-down",
        "lucide.plus",
        "lucide.circle-plus",
        "lucide.square-plus",
        "lucide.circle-minus",
        "lucide.square-minus",
        "lucide.diff",
        "lucide.trash-2",
        "lucide.inbox",
        "lucide.archive-restore",
        "lucide.square-check",
        "lucide.square",
        "lucide.square-dashed",
        "lucide.circle",
        "lucide.circle-dashed",
        "lucide.ban",
        "lucide.sparkles",
        "lucide.zap",
        "lucide.info",
        "lucide.triangle-alert",
        "lucide.circle-alert",
        "lucide.octagon-alert",
        "lucide.shield-check",
        "lucide.shield-alert",
        "lucide.shield-x",
        "lucide.shield",
        "lucide.badge-check",
        "lucide.key",
        "lucide.lock",
        "lucide.coins",
        "lucide.clock",
        "lucide.clock-alert",
        "lucide.alarm-clock",
    ]

    /// The Lucide symbol for each SF Symbol it replaces, by meaning.
    static let bySystemName: [String: String] = [
        "questionmark.circle": "lucide.circle-help", // Needs you: a question or an approval waits
        "exclamationmark.circle.fill": "lucide.circle-help", // Needs you: a question or an approval waits
        "pause.circle": "lucide.circle-pause", // Waiting: on a check, a lease, a time
        "dot.radiowaves.left.and.right": "lucide.circle-pause", // Waiting: on a check, a lease, a time
        "checkmark.circle": "lucide.circle-check", // Done
        "checkmark.circle.fill": "lucide.circle-check", // Done
        "xmark.circle": "lucide.circle-x", // Failed
        "xmark.circle.fill": "lucide.circle-x", // Failed
        "multiply.circle": "lucide.circle-x", // Failed
        "xmark.octagon.fill": "lucide.circle-x", // Failed
        "archivebox": "lucide.archive", // Archived
        "bubble.left": "lucide.message-circle", // Session
        "bubble.left.fill": "lucide.message-circle", // Session
        "message": "lucide.message-circle", // Session
        "text.bubble": "lucide.message-circle", // Session
        "bubble.left.and.bubble.right": "lucide.messages-square", // Conversations, channels
        "bubble.left.and.text.bubble.right": "lucide.messages-square", // Conversations, channels
        "questionmark.bubble": "lucide.message-circle-question-mark", // A question in the chat
        "folder": "lucide.folder", // Folder
        "folder.fill": "lucide.folder-open", // An open folder
        "questionmark.folder": "lucide.folder-search", // A folder that is not found
        "folder.badge.questionmark": "lucide.folder-search", // A folder that is not found
        "folder.badge.plus": "lucide.folder-plus", // Add a folder
        "flowchart": "lucide.workflow", // Workflow
        "point.3.connected.trianglepath.dotted": "lucide.workflow", // Workflow
        "smallcircle.filled.circle": "lucide.circle-dot", // Issue; a chosen option
        "circle.circle": "lucide.circle-dot", // Issue; a chosen option
        "largecircle.fill.circle": "lucide.circle-dot", // Issue; a chosen option
        "arrow.triangle.pull": "lucide.git-pull-request", // Pull request
        "arrow.triangle.branch": "lucide.git-branch", // Branch, worktree
        "arrow.triangle.merge": "lucide.git-merge", // Merge
        "laptopcomputer": "lucide.laptop", // Machine
        "desktopcomputer": "lucide.monitor", // A desktop machine, a screen
        "display": "lucide.monitor", // A desktop machine, a screen
        "server.rack": "lucide.server", // Server
        "internaldrive": "lucide.hard-drive", // Disk
        "iphone": "lucide.smartphone", // Phone
        "cpu": "lucide.cpu", // Processor
        "person": "lucide.user", // Person
        "person.fill": "lucide.user", // Person
        "person.crop.circle": "lucide.circle-user", // A person's account
        "person.crop.circle.fill": "lucide.circle-user", // A person's account
        "person.2": "lucide.users", // People
        "person.3": "lucide.users", // People
        "person.badge.plus": "lucide.user-plus", // Add a person
        "person.crop.circle.badge.xmark": "lucide.user-x", // A person removed or refused
        "person.crop.circle.badge.exclamationmark": "lucide.user-x", // A person removed or refused
        "person.badge.key": "lucide.user-key", // A person's key
        "person.crop.rectangle.stack": "lucide.contact", // Accounts
        "bolt.horizontal.circle": "lucide.plug", // Connector
        "puzzlepiece.extension": "lucide.puzzle", // Plugin
        "square.grid.2x2": "lucide.layout-grid", // Project; a view
        "square.stack.3d.up": "lucide.layers", // A stack, a plan
        "shippingbox": "lucide.package", // Package, release
        "doc.text": "lucide.file-text", // File, doc
        "doc.richtext": "lucide.file-text", // File, doc
        "doc": "lucide.file", // A file
        "doc.questionmark": "lucide.file-question-mark", // A file that is not found
        "doc.text.magnifyingglass": "lucide.file-search", // Search in a file
        "doc.on.doc": "lucide.copy", // Copy
        "square.on.square": "lucide.copy", // Copy
        "doc.on.clipboard": "lucide.clipboard-paste", // Paste
        "apple.terminal": "lucide.square-terminal", // Terminal, command
        "terminal": "lucide.square-terminal", // Terminal, command
        "chevron.left.forwardslash.chevron.right": "lucide.code", // Code
        "curlybraces": "lucide.braces", // Data, JSON
        "globe": "lucide.globe", // Web page
        "safari": "lucide.compass", // Browser
        "photo": "lucide.image", // Picture
        "camera": "lucide.camera", // Camera
        "link": "lucide.link", // Link
        "qrcode.viewfinder": "lucide.scan-qr-code", // Scan a code to pair
        "tag": "lucide.tag", // Label
        "building.2": "lucide.building-2", // Organisation
        "building.columns": "lucide.landmark", // Institution
        "envelope": "lucide.mail", // Email
        "envelope.badge": "lucide.mail", // Email
        "envelope.open": "lucide.mail-open", // Email, read
        "bell": "lucide.bell", // Notification
        "bell.slash": "lucide.bell-off", // Muted
        "house": "lucide.house", // Home
        "calendar": "lucide.calendar", // Date
        "hammer": "lucide.hammer", // Build, tool
        "gearshape": "lucide.settings", // Settings
        "gearshape.2": "lucide.settings", // Settings
        "checklist": "lucide.list-checks", // Checklist
        "list.number": "lucide.list-ordered", // Numbered list, prompts
        "list.bullet.rectangle": "lucide.list", // List
        "line.3.horizontal": "lucide.menu", // Drag to reorder
        "chart.pie": "lucide.chart-pie", // Share of a whole
        "chart.bar": "lucide.chart-column", // Chart
        "target": "lucide.target", // Goal
        "scope": "lucide.target", // Goal
        "lightbulb": "lucide.lightbulb", // Idea, suggestion
        "brain": "lucide.brain", // Thoughts, the agent's reasoning
        "paintbrush": "lucide.paintbrush", // Look
        "eye": "lucide.eye", // Show
        "eye.slash": "lucide.eye-off", // Hide
        "wifi.slash": "lucide.wifi-off", // Offline
        "antenna.radiowaves.left.and.right": "lucide.radio", // Broadcast, live
        "cloud": "lucide.cloud", // Cloud
        "cloud.fill": "lucide.cloud", // Cloud
        "sun.max": "lucide.sun", // Awake, held
        "sun.horizon": "lucide.sunrise", // Morning
        "battery.25": "lucide.battery-low", // On battery
        "hourglass": "lucide.hourglass", // Takes time
        "ticket": "lucide.ticket", // Ticket
        "note": "lucide.sticky-note", // Note
        "scroll": "lucide.scroll-text", // Log, record
        "at": "lucide.at-sign", // Mention
        "number": "lucide.hash", // Number
        "sidebar.left": "lucide.panel-left", // Left sidebar
        "sidebar.trailing": "lucide.panel-right", // Right sidebar
        "sidebar.right": "lucide.panel-right", // Right sidebar
        "cursorarrow.rays": "lucide.mouse-pointer-click", // Click, control the screen
        "hand.raised": "lucide.hand", // Stop and ask; a hand raised
        "hand.raised.fill": "lucide.hand", // Stop and ask; a hand raised
        "hand.tap": "lucide.pointer", // Tap
        "ear": "lucide.ear", // Listen
        "keyboard": "lucide.keyboard", // Keyboard, type
        "keyboard.chevron.compact.down": "lucide.keyboard-off", // Hide the keyboard
        "drop": "lucide.droplet", // Drop
        "circle.fill": "lucide.dot", // A running mark
        "dot.square": "lucide.square-dot", // A changed file
        "timeline.selection": "lucide.chart-gantt", // Timeline
        "phone.bubble": "lucide.phone", // Phone, messaging
        "person.crop.circle.badge.clock": "lucide.clock-fading", // Background work
        "square.and.pencil": "lucide.square-pen", // New session
        "pencil": "lucide.pencil", // Edit
        "pencil.circle": "lucide.pencil", // Edit
        "arrow.up": "lucide.arrow-up", // Send
        "arrow.down": "lucide.arrow-down", // Down
        "arrow.down.circle": "lucide.circle-arrow-down", // Download, to the end
        "arrow.right": "lucide.arrow-right", // Go on
        "arrow.right.circle": "lucide.circle-arrow-right", // Go on, in a circle
        "arrow.right.square": "lucide.square-arrow-right", // Move to
        "arrow.up.to.line": "lucide.arrow-up-to-line", // To the top
        "arrow.turn.down.right": "lucide.corner-down-right", // Reply, a thread
        "arrow.up.and.down": "lucide.arrow-up-down", // Sort
        "arrow.up.left.and.arrow.down.right": "lucide.maximize-2", // Expand
        "arrow.uturn.backward": "lucide.undo-2", // Undo, go back
        "arrow.uturn.left": "lucide.undo-2", // Undo, go back
        "arrowshape.turn.up.left": "lucide.undo-2", // Undo, go back
        "arrow.uturn.backward.circle": "lucide.undo-2", // Undo, go back
        "arrow.uturn.up": "lucide.undo-2", // Undo, go back
        "paperclip": "lucide.paperclip", // Attach
        "microphone": "lucide.mic", // Voice
        "mic.fill": "lucide.mic", // Voice
        "waveform": "lucide.audio-waveform", // Voice mode
        "waveform.circle": "lucide.audio-waveform", // Voice mode
        "magnifyingglass": "lucide.search", // Search
        "text.magnifyingglass": "lucide.text-search", // Find in the text
        "plus.magnifyingglass": "lucide.zoom-in", // Zoom in
        "minus.magnifyingglass": "lucide.zoom-out", // Zoom out
        "ellipsis": "lucide.ellipsis", // More
        "ellipsis.circle": "lucide.circle-ellipsis", // More, in a circle
        "pin": "lucide.pin", // Pin
        "pin.fill": "lucide.pin", // Pin
        "pin.slash": "lucide.pin-off", // Unpin
        "arrow.up.right.square": "lucide.external-link", // Open outside the app
        "macwindow.badge.plus": "lucide.app-window", // Open in a new window
        "rectangle.portrait": "lucide.rectangle-vertical", // Open alone, full screen
        "arrow.clockwise": "lucide.rotate-cw", // Retry
        "arrow.clockwise.circle": "lucide.rotate-cw", // Retry
        "arrow.triangle.2.circlepath": "lucide.refresh-cw", // Again and again, sync
        "arrow.trianglehead.2.clockwise": "lucide.refresh-cw", // Again and again, sync
        "repeat": "lucide.repeat", // Repeat
        "clock.arrow.circlepath": "lucide.history", // History
        "stop.circle": "lucide.circle-stop", // Stop
        "stop": "lucide.circle-stop", // Stop
        "stop.fill": "lucide.circle-stop", // Stop
        "play": "lucide.play", // Run
        "play.fill": "lucide.play", // Run
        "play.circle": "lucide.circle-play", // Run, in a circle
        "checkmark": "lucide.check", // Approve
        "xmark": "lucide.x", // Close, deny
        "chevron.right": "lucide.chevron-right", // Open, go in
        "chevron.compact.right": "lucide.chevron-right", // Open, go in
        "forward": "lucide.chevron-right", // Open, go in
        "arrow.up.forward.app": "lucide.chevron-right", // Open, go in
        "chevron.left": "lucide.chevron-left", // Back
        "chevron.backward": "lucide.chevron-left", // Back
        "chevron.down": "lucide.chevron-down", // Fold, menu
        "chevron.up": "lucide.chevron-up", // Up
        "chevron.up.chevron.down": "lucide.chevrons-up-down", // Choose
        "plus": "lucide.plus", // Add
        "plus.circle": "lucide.circle-plus", // Add, in a circle
        "plus.square": "lucide.square-plus", // Add, in a square
        "minus.circle": "lucide.circle-minus", // Remove
        "minus.square": "lucide.square-minus", // Remove, in a square
        "plusminus": "lucide.diff", // Changes
        "trash": "lucide.trash-2", // Delete
        "tray": "lucide.inbox", // Inbox, nothing here
        "tray.full": "lucide.inbox", // Inbox, nothing here
        "tray.and.arrow.up": "lucide.archive-restore", // Unarchive
        "checkmark.square": "lucide.square-check", // A box that is checked
        "square": "lucide.square", // A box that is not checked
        "square.dashed": "lucide.square-dashed", // An empty place
        "questionmark.square.dashed": "lucide.square-dashed", // An empty place
        "circle": "lucide.circle", // An option not chosen
        "circle.dashed": "lucide.circle-dashed", // Not started
        "circle.dotted": "lucide.circle-dashed", // Not started
        "slash.circle": "lucide.ban", // Not allowed
        "nosign": "lucide.ban", // Not allowed
        "hand.raised.slash": "lucide.ban", // Not allowed
        "sparkle": "lucide.sparkles", // Suggested by an agent
        "sparkles": "lucide.sparkles", // Suggested by an agent
        "bolt": "lucide.zap", // Fast, now
        "info": "lucide.info", // For your information
        "info.circle": "lucide.info", // For your information
        "exclamationmark.triangle": "lucide.triangle-alert", // Warning: it may go wrong
        "exclamationmark.triangle.fill": "lucide.triangle-alert", // Warning: it may go wrong
        "exclamationmark.circle": "lucide.circle-alert", // Error: it went wrong
        "exclamationmark.octagon": "lucide.octagon-alert", // Stopped by a rule
        "checkmark.shield": "lucide.shield-check", // Trust: approve a device, a tool
        "exclamationmark.shield": "lucide.shield-alert", // A trust problem
        "xmark.shield": "lucide.shield-x", // Trust refused
        "lock.shield": "lucide.shield", // Protected
        "checkmark.seal": "lucide.badge-check", // Vouched for
        "checkmark.seal.fill": "lucide.badge-check", // Vouched for
        "key": "lucide.key", // A secret
        "key.horizontal": "lucide.key", // A secret
        "lock": "lucide.lock", // Locked, signed in
        "lock.fill": "lucide.lock", // Locked, signed in
        "dollarsign.circle": "lucide.coins", // Cost
        "clock": "lucide.clock", // Time, a schedule
        "clock.badge.questionmark": "lucide.clock-alert", // A time that waits on you
        "alarm": "lucide.alarm-clock", // Reminder
    ]
}
