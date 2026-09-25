import SwiftTerm
import UIKit

/// The keys a shell needs and a touch keyboard has not got, in a row above it (034).
///
/// SwiftTerm has its own row, and its Control is a key that waits for the next one:
/// Control-C there is two taps. Interrupting something is the one key a person reaches
/// for in a hurry, so it is a key of its own here, and one tap (SC-005). Escape, Tab and
/// the arrows are one tap each too. Control stays, for every other control key.
///
/// The arrows are sent as the terminal asks for them — the application form while a
/// full-screen program holds the screen — which is what makes them work in `vim` and
/// `top` as well as at a prompt.
final class ShellKeys: UIInputView, UIInputViewAudioFeedback {
    private weak var terminal: TerminalView?
    private let control = UIButton(type: .system)

    var enableInputClicksWhenVisible: Bool { true }

    init(terminal: TerminalView) {
        self.terminal = terminal
        let short = UIDevice.current.userInterfaceIdiom == .phone
        super.init(frame: CGRect(x: 0, y: 0, width: 320, height: short ? 40 : 48), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        build()
        NotificationCenter.default.addObserver(self, selector: #selector(controlWasUsed),
                                               name: Self.controlReset, object: terminal)
    }

    required init?(coder: NSCoder) { fatalError("made in code") }

    /// What SwiftTerm posts when it lets go of Control after the key it modified. Its own
    /// name for it is not public; the string is.
    private static let controlReset = Notification.Name("SwiftTerm.TerminalView.controlModifierReset")

    // MARK: The keys

    fileprivate enum Key {
        case bytes(String, [UInt8], hint: String)
        case arrow(String, Direction)
        case control

        enum Direction { case up, down, left, right }
    }

    private static let keys: [Key] = [
        .bytes("^C", [0x03], hint: "Interrupts what is running"),
        .bytes("esc", [0x1B], hint: "Escape"),
        .bytes("tab", [0x09], hint: "Tab"),
        .control,
        .arrow("←", .left),
        .arrow("↑", .up),
        .arrow("↓", .down),
        .arrow("→", .right),
        .bytes("|", Array("|".utf8), hint: "Pipe"),
        .bytes("~", Array("~".utf8), hint: "Tilde"),
        .bytes("/", Array("/".utf8), hint: "Slash"),
        .bytes("-", Array("-".utf8), hint: "Hyphen"),
    ]

    private func build() {
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 6
        row.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(row)

        for (index, key) in Self.keys.enumerated() {
            let button = key.isControl ? control : UIButton(type: .system)
            var configuration = UIButton.Configuration.gray()
            configuration.title = key.title
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12)
            configuration.baseForegroundColor = .label
            button.configuration = configuration
            button.tag = index
            button.accessibilityLabel = key.accessibilityLabel
            button.addTarget(self, action: #selector(pressed(_:)), for: .touchUpInside)
            row.addArrangedSubview(button)
        }

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -8),
        ])
    }

    @objc private func pressed(_ sender: UIButton) {
        UIDevice.current.playInputClick()
        guard let terminal, Self.keys.indices.contains(sender.tag) else { return }
        switch Self.keys[sender.tag] {
        case .bytes(_, let bytes, _):
            terminal.send(bytes)
        case .arrow(_, let direction):
            let app = terminal.getTerminal().applicationCursor
            switch direction {
            case .up: terminal.send(app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
            case .down: terminal.send(app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
            case .left: terminal.send(app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
            case .right: terminal.send(app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
            }
        case .control:
            terminal.controlModifier.toggle()
            showControl()
        }
    }

    /// The terminal let go of Control after the key it modified.
    @objc private func controlWasUsed() {
        showControl()
    }

    private func showControl() {
        let on = terminal?.controlModifier ?? false
        control.configuration?.baseBackgroundColor = on ? .tintColor : nil
        control.configuration?.baseForegroundColor = on ? .white : .label
        control.accessibilityValue = on ? "On" : "Off"
    }
}

private extension ShellKeys.Key {
    var isControl: Bool {
        if case .control = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .bytes(let title, _, _), .arrow(let title, _): title
        case .control: "ctrl"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .bytes(let title, _, let hint): title == "^C" ? "Control C" : hint
        case .arrow(_, let direction):
            switch direction {
            case .up: "Up arrow"
            case .down: "Down arrow"
            case .left: "Left arrow"
            case .right: "Right arrow"
            }
        case .control: "Control"
        }
    }
}
