import Foundation

/// What identifies "the place the user is looking at", sampled at every clipboard poll.
public struct ContextIdentity: Sendable, Equatable {
    public var pid: Int32
    /// Opaque identity of the focused window (hash of its AX element); `nil` when none.
    public var window: Int?
    public var windowTitle: String?
    public var url: URL?
    public var isPrivateBrowsing: Bool

    public init(pid: Int32, window: Int?, windowTitle: String?, url: URL?, isPrivateBrowsing: Bool) {
        self.pid = pid
        self.window = window
        self.windowTitle = windowTitle
        self.url = url
        self.isPrivateBrowsing = isPrivateBrowsing
    }
}

/// Something that may have moved the user to another app, window or tab.
public enum ContextEvent: Sendable, Equatable {
    case appActivated
    case focusedWindowChanged
    case titleChanged
    /// Fires constantly while typing; recorded for completeness but never a context switch.
    case valueChanged
    /// The frontmost app's AX observer just attached: switches before this moment were not
    /// observed, so it counts as a switch for any copy whose interval started earlier.
    case observerAttached

    /// Maps the AX notification names the scheduler observes.
    public init?(axNotification name: String) {
        switch name {
        case "AXFocusedWindowChanged": self = .focusedWindowChanged
        case "AXTitleChanged": self = .titleChanged
        case "AXValueChanged": self = .valueChanged
        default: return nil
        }
    }

    var isContextSwitch: Bool { self != .valueChanged }
}

/// Decides whether a clipboard change detected at a poll can be attributed to the context
/// sampled at that poll.
///
/// The copy happened at some point after the previous poll's pasteboard read, and the
/// context is only sampled at poll times (each sample arriving a little after its read), so
/// attribution is safe only if nothing moved in between. Fails closed: a copy is dropped when
///   - there is no previous sample, or either sample is unknown;
///   - the sampled identity (app, window, title, URL, private flag) differs between polls;
///   - a context-switch event (app activation, focused-window change, title change, AX
///     observer attachment) happened
///     at or after the previous pasteboard read, or within the last poll interval. Events
///     catch what sampling cannot: a switch before the previous sample arrived, and A→B→A
///     round trips between samples.
///
/// Times are monotonic (`ContinuousClock`) so wall-clock changes cannot reorder them.
public struct ClipboardAttribution: Sendable {
    public typealias Instant = ContinuousClock.Instant

    public let pollInterval: Duration
    private var previous: (identity: ContextIdentity?, pasteboardReadAt: Instant)?
    private var lastContextSwitch: Instant?

    public init(pollInterval: Duration) {
        self.pollInterval = pollInterval
    }

    public mutating func record(_ event: ContextEvent, at instant: Instant) {
        guard event.isContextSwitch else { return }
        lastContextSwitch = max(lastContextSwitch ?? instant, instant)
    }

    /// Records this poll's sample. `pasteboardReadAt` is when the pasteboard was checked,
    /// `identity` the context read right after (nil if unknown), `now` when it arrived.
    /// Returns true if a copy detected at this poll may be stored under `identity`.
    public mutating func completePoll(identity: ContextIdentity?, pasteboardReadAt: Instant,
                                      now: Instant) -> Bool {
        defer { previous = (identity, pasteboardReadAt) }
        guard let identity, let previous, previous.identity == identity else { return false }
        if let change = lastContextSwitch,
           change >= previous.pasteboardReadAt || change.duration(to: now) <= pollInterval {
            return false
        }
        return true
    }
}
