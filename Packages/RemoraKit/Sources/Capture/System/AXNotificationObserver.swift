import ApplicationServices

/// Observes AX notifications posted by one application; the handler runs on the main run loop
/// and receives the notification name (e.g. `kAXTitleChangedNotification`).
///
/// Registration (`AXObserverAddNotification` is IPC to the target app) happens on the reader's
/// serial AX queue with a bounded messaging timeout, so a hung app never blocks the main
/// thread. Only the run-loop source lives on the main run loop. Dropping the last reference
/// (on the main actor) removes the source, after which the handler is never called again.
///
/// `@unchecked Sendable`: all stored properties are immutable CF references; the instance is
/// created on the AX queue, handed to the main actor once, and released there.
public final class AXNotificationObserver: @unchecked Sendable {
    private let observer: AXObserver
    private let source: CFRunLoopSource
    private let box: HandlerBox
    /// The notification names that were actually registered (a subset of those requested).
    public let registered: Set<String>

    private init(observer: AXObserver, source: CFRunLoopSource, box: HandlerBox,
                 registered: Set<String>) {
        self.observer = observer
        self.source = source
        self.box = box
        self.registered = registered
    }

    deinit {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
    }

    /// Registers `notifications` on the application element of `pid`. Returns `nil` if the
    /// observer cannot be created or none of the notifications could be registered (no
    /// Accessibility permission, app gone, or app unresponsive); otherwise `registered` says
    /// which ones took.
    public static func observe(pid: pid_t, notifications: [String],
                               handler: @escaping @MainActor @Sendable (String) -> Void) async
        -> AXNotificationObserver? {
        let box = HandlerBox(handler)
        return await withCheckedContinuation { continuation in
            FrontmostWindowReader.queue.async {
                continuation.resume(returning: register(pid: pid, notifications: notifications, box: box))
            }
        }
    }

    private static func register(pid: pid_t, notifications: [String], box: HandlerBox)
        -> AXNotificationObserver? {
        var created: AXObserver?
        let status = AXObserverCreate(pid, { _, _, notification, refcon in
            guard let refcon else { return }
            let box = Unmanaged<HandlerBox>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            // The source is only ever added to the main run loop.
            MainActor.assumeIsolated { box.handler(name) }
        }, &created)
        guard status == .success, let observer = created else { return nil }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, axMessagingTimeout)
        // Unretained: `box` is owned by the returned observer, whose deinit removes the
        // source before the box can go away.
        let refcon = Unmanaged.passUnretained(box).toOpaque()
        var registered: Set<String> = []
        for name in notifications {
            let error = AXObserverAddNotification(observer, app, name as CFString, refcon)
            if error == .success || error == .notificationAlreadyRegistered { registered.insert(name) }
            if error == .cannotComplete { break }  // app unresponsive: don't wait per name
        }
        guard !registered.isEmpty else { return nil }

        let source = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return AXNotificationObserver(observer: observer, source: source, box: box,
                                      registered: registered)
    }

    private final class HandlerBox: Sendable {
        let handler: @MainActor @Sendable (String) -> Void
        init(_ handler: @escaping @MainActor @Sendable (String) -> Void) { self.handler = handler }
    }
}
