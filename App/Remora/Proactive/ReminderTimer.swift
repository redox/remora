import AppKit
import Assistant
import Foundation
import os

/// The only caller of `ReminderDispatcher.fire()`, so firings are serialized: one one-shot `Timer`
/// armed at `ReminderEngine.nextFireAt()` (`ReminderArming.delay`: never more than 5 minutes
/// away, a safety net), and at most one `fire()` in flight. It fires at `start` (the dispatcher's
/// recovery sweep runs first thing in `fire()`), on expiry, and on wake, clock and time-zone
/// changes (overdue reminders fire at once, recurring ones keep local time). `rearm` (a reminder
/// was created, cancelled or changed) only re-reads the next firing time. Delivered messages
/// reach the app through `ProactiveInbox.onDelivered`. Logs counts only.
@MainActor
final class ReminderTimer {
    private let dispatcher: ReminderDispatcher
    private let engine: ReminderEngine
    private var timer: Timer?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var started = false
    private var firing = false
    /// A fire was asked for while one ran: run once more after it.
    private var fireAgain = false
    /// Drops stale `nextFireAt` reads when two re-arms overlap.
    private var armToken = 0
    private static let log = Logger(subsystem: "dev.remora", category: "reminders")

    init(dispatcher: ReminderDispatcher, engine: ReminderEngine) {
        self.dispatcher = dispatcher; self.engine = engine
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification)
        observe(.default, .NSSystemClockDidChange)
        observe(.default, .NSSystemTimeZoneDidChange)
        observe(.default, NSApplication.willTerminateNotification, fire: false)
        fire()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        for (center, o) in observers { center.removeObserver(o) }
        observers = []
        started = false
    }

    /// Reminders changed: re-read the next firing time (a firing in flight re-arms when done).
    func rearm() {
        guard started, !firing else { return }
        arm()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, fire: Bool = true) {
        let o = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if fire { self?.fire() } else { self?.stop() }
            }
        }
        observers.append((center, o))
    }

    private func fire() {
        guard started else { return }
        guard !firing else { fireAgain = true; return }
        firing = true
        timer?.invalidate()
        timer = nil
        let dispatcher = dispatcher
        Task { [weak self] in
            let delivered = await Task.detached(priority: .utility) { await dispatcher.fire() }.value
            guard let self else { return }
            if !delivered.isEmpty { Self.log.info("reminder timer delivered \(delivered.count, privacy: .public)") }
            firing = false
            if fireAgain {
                fireAgain = false
                fire()
            } else {
                arm()
            }
        }
    }

    private func arm() {
        guard started else { return }
        armToken += 1
        let token = armToken, engine = engine
        Task { [weak self] in
            let next: Date?
            do { next = try await engine.nextFireAt() } catch {
                Self.log.error("next reminder unreadable: \(String(describing: type(of: error)), privacy: .public)")
                next = nil  // the safety net still wakes in 5 minutes
            }
            guard let self, started, !firing, token == armToken else { return }
            schedule(after: ReminderArming.delay(nextFireAt: next, now: .now))
        }
    }

    private func schedule(after delay: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.fire() }
        }
        timer.tolerance = min(1, delay / 10)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
