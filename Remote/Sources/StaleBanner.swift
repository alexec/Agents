import AgentsKitCore
import SwiftUI

/// A strip at the top when the Mac has stopped answering (#5034): grey, and orange when the
/// person must pair, or when the control plane's address refused and its account page is
/// offered.
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
        .animation(ResponseMotion.response, value: model.isStale)
        .animation(ResponseMotion.response, value: model.needsPairing)
    }

    @ViewBuilder
    private var reach: some View {
        if model.needsPairing {
            // Never paired, or forgotten by the Mac: the list below may still be what it
            // last knew, so the one thing to do is said here, on every screen.
            Strip(tone: .warning, symbol: "qrcode.viewfinder", line: "Scan the code on your Mac to connect")
                .paneBannerInset()
        } else if let refusal = model.controlPlaneRefusalLine, model.isStale {
            // The control plane's address refused (suspended, over a plan's limit): a
            // fault to act on, not a Mac asleep (#3153). Its account page, when it names
            // one, and a try now rather than at the end of the long wait. Attention when
            // the account page is there to open, as the window's `ControlAwayStrip`.
            let account = ControlRefusal.link(in: refusal)
            let read = model.lastReadAt
            LastUpdateTimeline(read: read ?? .distantPast) { now in
                Strip(tone: account == nil ? .neutral : .warning, line: LastUpdate.banner(refusal, read: read, now: now),
                      primary: StripButton(title: "Try Again") { model.tryAgainNow() },
                      second: account.map { url in StripButton(title: "Open Account") { openURL(url) } })
            }
            .paneBannerInset()
        } else if model.isStale {
            // The Mac, or the control plane where it runs elsewhere (#4916), and how old what
            // is shown is (#5141), ticking.
            let read = model.lastReadAt
            LastUpdateTimeline(read: read ?? .distantPast) { now in
                Strip(tone: .neutral, symbol: MessageTone.offlineSymbol,
                      line: model.controlPlaneReach.banner(read: read, now: now))
            }
            .paneBannerInset()
        }
    }
}

extension View {
    /// The banner at the top of a page that shows what was last read (#5147): every page says
    /// when the Mac stopped answering and how old what it shows is, not only the chat.
    func staleBanner() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { StaleBanner() }
    }

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
            .animation(ResponseMotion.response, value: isStale)
    }
}
