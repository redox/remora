import Foundation

public struct TapThresholds: Sendable {
    public var tapMax: TimeInterval = 0.35
    public var doubleTapGap: TimeInterval = 0.30
    public var holdMin: TimeInterval = 0.40
    public init() {}
}

/// The rewrite key's clean-tap state machine. Pure: times are passed in (seconds on any monotonic
/// clock), and `tick` must be called at `nextDeadline`.
///
/// - A clean tap is a down→up within `tapMax` with no other input in between.
/// - With `doubleTap`, a clean tap waits `doubleTapGap`: a second clean tap → `.doubleTap`, the
///   deadline → `.singleTap`, any other key, modifier or mouse input → cancelled (no output).
/// - With `hold`, a clean press held to `holdMin` → `.holdArmed` at the deadline (provisional: the
///   UI may show a hint). A clean release then commits `.holdReleased`; any other input while it
///   is still held → `.holdCancelled`, and the release is swallowed.
/// - Any other modifier, key or mouse input while the trigger is down makes the press dirty: it
///   produces nothing until a fresh press.
public struct TapDetector: Sendable {
    public enum Input: Sendable, Equatable { case triggerDown, triggerUp, otherModifier, otherKey, mouse }
    public enum Output: Sendable, Equatable { case singleTap, doubleTap, holdArmed, holdReleased, holdCancelled }

    private enum State: Sendable, Equatable {
        case idle
        /// Trigger down since `at`; `second` when it is the second press of a double tap.
        case pressed(at: TimeInterval, clean: Bool, second: Bool, start: TimeInterval)
        /// A clean press reached `holdMin` and awaits its release.
        case armed(start: TimeInterval)
        /// An armed hold was spoiled by other input: swallow the release.
        case holdSpoiled
        /// A clean tap ended; `.singleTap` at `until` unless a second tap comes first.
        case awaitingSecond(until: TimeInterval, start: TimeInterval)
    }

    private let thresholds: TapThresholds
    private let doubleTap: Bool
    private let hold: Bool
    private var state: State = .idle

    public init(thresholds: TapThresholds = .init(), doubleTap: Bool, hold: Bool) {
        self.thresholds = thresholds; self.doubleTap = doubleTap; self.hold = hold
    }

    public var nextDeadline: TimeInterval? {
        switch state {
        case .pressed(let at, true, _, _) where hold: at + thresholds.holdMin
        case .awaitingSecond(let until, _): until
        default: nil
        }
    }

    /// When the first press of the gesture in progress went down (nil when idle). Lets the caller
    /// check that no other input happened since then, even input it never saw.
    public var gestureStart: TimeInterval? {
        switch state {
        case .pressed(_, _, _, let start), .armed(let start), .awaitingSecond(_, let start): start
        case .idle, .holdSpoiled: nil
        }
    }

    public mutating func handle(_ input: Input, at t: TimeInterval, allowsDoubleTap: Bool = true) -> Output? {
        switch (state, input) {
        case (.idle, .triggerDown):
            state = .pressed(at: t, clean: true, second: false, start: t)
            return nil
        case (.idle, _):
            return nil

        case (.pressed, .triggerDown):
            return nil  // repeated flags event for the same press
        case (.pressed(let at, _, let second, let start), _) where input != .triggerUp:
            state = .pressed(at: at, clean: false, second: second, start: start)
            return nil
        case (.pressed(let at, let clean, let second, let start), _):  // .triggerUp
            state = .idle
            guard clean else { return nil }
            let duration = t - at
            if duration <= thresholds.tapMax {
                if second { return .doubleTap }
                if doubleTap && allowsDoubleTap {
                    state = .awaitingSecond(until: t + thresholds.doubleTapGap, start: start)
                    return nil
                }
                return .singleTap
            }
            // Held long enough but the deadline tick came late: a clean hold all the same.
            return hold && duration >= thresholds.holdMin ? .holdReleased : nil

        case (.armed, .triggerUp):
            state = .idle
            return .holdReleased
        case (.armed, .triggerDown):
            return nil
        case (.armed, _):
            state = .holdSpoiled
            return .holdCancelled

        case (.holdSpoiled, .triggerUp):
            state = .idle
            return nil
        case (.holdSpoiled, _):
            return nil

        case (.awaitingSecond(let until, let start), .triggerDown):
            if t <= until {
                state = .pressed(at: t, clean: true, second: true, start: start)
                return nil
            }
            // The deadline passed without a tick: report the pending tap and start a new press.
            state = .pressed(at: t, clean: true, second: false, start: t)
            return .singleTap
        case (.awaitingSecond, .triggerUp):
            return nil
        case (.awaitingSecond, _):
            state = .idle  // typing, clicking or a shortcut right after a tap cancels it
            return nil
        }
    }

    public mutating func tick(at t: TimeInterval) -> Output? {
        switch state {
        case .pressed(let at, true, _, let start) where hold && t >= at + thresholds.holdMin:
            state = .armed(start: start)
            return .holdArmed
        case .awaitingSecond(let until, _) where t >= until:
            state = .idle
            return .singleTap
        default:
            return nil
        }
    }

    /// Back to idle (e.g. after the caller rejected the gesture).
    public mutating func reset() { state = .idle }
}

/// Input the monitors cannot see: a key or click consumed by another app's event tap (Raycast,
/// Alfred hot keys) still updates the HID system state. A gesture is interrupted when any such
/// event is younger than the gesture itself.
public enum GestureGuard {
    /// Ages are seconds since the last HID key-down / mouse-down (`CGEventSource.secondsSinceLastEventType`).
    public static func interrupted(lastKeyDownAge: TimeInterval, lastMouseDownAge: TimeInterval,
                                   gestureDuration: TimeInterval) -> Bool {
        min(lastKeyDownAge, lastMouseDownAge) < gestureDuration
    }
}
