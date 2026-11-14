import AgentsKitCore
import Foundation
import Observation
import SwiftUI
import UIKit

/// The remote's state, part of `RemoteModel` (#5383): see `RemoteModel.swift`.
extension RemoteModel {
    // MARK: Staying in touch

    /// Keep trying until the Mac answers.
    ///
    /// It retries rather than giving up because the ordinary first run fails: iOS will
    /// not let an app look at the local network until the user has said yes, and the
    /// asking happens after the first attempt has already been refused. Giving up there
    /// would mean tapping Allow and then having to quit the app to use it.
    ///
    /// It is also the right behaviour afterwards. A Mac that is asleep, or on another
    /// network, is a thing that comes back, and the screens say "last heard from" in
    /// the meantime rather than looking broken.
    ///
    /// Backing off to half a minute between tries, so a phone in a pocket with no Mac to
    /// find is not holding the radio open every second all afternoon. A model whose
    /// pairing was replaced is stopped, and never looks again (#208).
    func connect() async {
        guard !reconnect.isStopped, !reconnect.isRunning else { return }
        note("link: looking for the Mac")
        networkChanges.start()
        await reconnect.run()
    }

    /// The stale banner's Try Again (#3153): the wait before the next try is cut short,
    /// also the long one after a hosted refusal, and a stopped loop is started again.
    func tryAgainNow() {
        guard !reconnect.isStopped else { return }
        note("link: try again, from the banner")
        if backoff.nudge() == .idle, !reconnect.isRunning, !isConnected {
            Task { await connect() }
        }
    }

    /// The app came to the front, or the network changed (#82). A phone that was in a
    /// pocket may have been half a minute into a back-off, or holding a connection that
    /// died while it was suspended; either way, look now. A try already in flight is
    /// left alone.
    func goBackNow(_ reason: ReconnectTriggers.Reason) async {
        guard !reconnect.isStopped else { return }
        note("link: \(reason); connected \(isConnected), reconnecting \(reconnect.isRunning)")
        otherHostsBackoff.nudge()
        guard backoff.nudge() == .idle, isConnected, !reconnect.isRunning, !checkingConnection else { return }
        checkingConnection = true
        defer { checkingConnection = false }
        if await !client.answers(within: .seconds(4)) {
            note("link: no answer after \(reason); letting go")
            // The listener hears the connection close and reconnects.
            await client.disconnect()
        }
    }

    func tryOnce() async -> Bool {
        let began = ContinuousClock.now
        do {
            try await client.connect(startIfNeeded: false)
            // Stopped while dialling: a new pairing has the screen, and this one lets go.
            guard !reconnect.isStopped else {
                await client.disconnect()
                return false
            }
            note("link: connected after \(ContinuousClock.now - began)")
            refusals.connected()
            // A home host that is a server asks for a key as any other server does (#344).
            await client.setCredentialLender { [weak self] wanted in
                await self?.answerHomeCredentialWanted(wanted) ?? false
            }
            isConnected = true
            lastHeardFrom = Date()
            problem = nil
            controlPlaneRefusalLine = nil
            listen()
            // Each call here with a deadline: this runs inside the reconnect loop, and a
            // reply lost to a Mac restarting left the loop, and so the app, waiting for
            // good while it looked connected (073).
            await DaemonClient.$patience.withValue(Self.catchUpPatience) {
                await announce()
                await identify()
            }
            startPresence()
            presence?.connected()
            await DaemonClient.$patience.withValue(Self.catchUpPatience) {
                await files.reconnected()
                await catchUp()
                await machineBrowsers[.mac]?.rewatchIfWatching()
            }
            watchOtherHosts()
            note("link: settled after \(ContinuousClock.now - began); still connected \(isConnected)")
            return true
        } catch {
            let why = await client.lastOpenFailure
            note("link: attempt failed after \(ContinuousClock.now - began): \(error)\(why.map { " (\($0))" } ?? "")")
            let reason = ControlPlaneLink.refused.take()
            // Said every time: a refusal that forgets nothing was not in the log (#3225).
            if let reason { note("link: the control plane refused: \(reason.rawValue)") }
            // Suspended by the organisation (#1002): only that, with the pairing kept.
            signIn.refused(reason)
            // The address itself refused (suspended, over a plan's limit, #2235): its
            // words replace the stale banner's, and trying again soon is pointless.
            if let line = ControlPlaneLink.hostedRefusal.take() {
                note("link: the address refused: \(line)")
                controlPlaneRefusalLine = line
                backoff.holdOff()
            }
            if let reason, refusals.forgets(after: reason) {
                note("link: forgotten by the control plane (\(reason))")
                // Forgotten from a window, or unknown for minutes on end: this device asks
                // for a new code, and stops dialling. One "unknown" alone is a control plane
                // that could not tell yet, and is dialled again (#81).
                RemoteControl.forget()
                forgetKept()
                forgottenByControlPlane = true
                isConnected = false
                return false
            }
            isConnected = false
            return false
        }
    }
}
