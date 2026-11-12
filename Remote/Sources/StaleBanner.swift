import AgentsKitCore
import SwiftUI

/// A banner at the top when the Mac has stopped answering (#4737): neutral, and attention
/// when the person must pair, or when the control plane's address refused and its account
/// page is offered.
///
/// Information, not an error. A Mac asleep in another room is the ordinary case, and
/// the remote's job is to say when it last heard rather than to look broken. What sits
/// under it is dimmed and marked stale, and nothing on those screens offers an action
/// while this is showing (FR-035).
struct StaleBanner: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        // The organisation stopped all agent work, or the Mac follows no policy it can trust
        // (#998): on every page, under whatever says how the Mac is reached.
        VStack(spacing: 0) {
            reach
            if !model.needsPairing, !model.isStale { OrgPolicyStrip(state: model.policyState) }
        }
        .remoteBannerGround()
        .animation(.easeOut(duration: 0.2), value: model.isStale)
        .animation(.easeOut(duration: 0.2), value: model.needsPairing)
    }

    @ViewBuilder
    private var reach: some View {
        if model.needsPairing {
            // Never paired, or forgotten by the Mac: the list below may still be what it
            // last knew, so the one thing to do is said here, on every screen.
            PaneBanner(tone: .attention, symbol: "qrcode.viewfinder", "Scan the code on your Mac to connect")
                .paneBannerInset()
        } else if let refusal = model.controlPlaneRefusalLine, model.isStale {
            // The control plane's address refused (suspended, over a plan's limit): a
            // fault to act on, not a Mac asleep (#3153). Its account page, when it names
            // one, and a try now rather than at the end of the long wait. Attention when
            // the account page is there to open, as the window's `ControlAwayStrip`.
            let account = ControlRefusal.link(in: refusal)
            PaneBanner(tone: account == nil ? .neutral : .attention, refusal) {
                if let account {
                    Button("Open Account") { openURL(account) }
                }
                Button("Try Again") { model.tryAgainNow() }
            }
            .paneBannerInset()
        } else if model.isStale {
            PaneBanner(tone: .neutral, symbol: MessageTone.offlineSymbol, staleLine)
                .paneBannerInset()
        }
    }

    private var staleLine: String {
        guard let last = model.lastHeard else { return "Not connected to your Mac yet" }
        return "Last heard from your Mac \(last)"
    }
}

extension View {
    /// The ground under the Remote's banners at the top of a page: what scrolls under the
    /// inset does not show between them (#4737).
    func remoteBannerGround() -> some View {
        frame(maxWidth: .infinity).background(Paper.ground)
    }
}

/// What a screen looks like while it cannot be trusted: still readable, plainly not
/// current, and not offering anything.
extension View {
    func markedStale(_ isStale: Bool) -> some View {
        disabled(isStale)
            .opacity(isStale ? 0.55 : 1)
            .animation(.default, value: isStale)
    }
}
