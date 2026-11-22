import Foundation

public struct BarInteraction: Sendable {
    public enum State: Sendable, Equatable { case collapsed, peeking, open }
    public enum Input: Sendable, Equatable {
        case mouseEntered, mouseExited, hoverTimerFired, exitTimerFired, clickBar, becameKey, resignedKey, escape, toggle, openRequested
        case setPinned(Bool)
        case streaming(Bool)
    }
    public enum Effect: Sendable, Equatable {
        case expand, collapse, startHoverTimer(TimeInterval), startExitTimer(TimeInterval), cancelTimers, focusInput, stopStream
    }

    public private(set) var state: State = .collapsed
    public private(set) var pinned: Bool
    private var isStreaming = false
    private var exitPending = false
    private var hoverPending = false

    /// A pinned bar starts `.open` (pinned means "stay open"); the app expands the panel itself on launch.
    public init(pinned: Bool) {
        self.pinned = pinned
        if pinned { state = .open }
    }

    private mutating func open() {
        state = .open
        exitPending = false
        hoverPending = false
    }

    private mutating func collapse() -> [Effect] {
        state = .collapsed
        exitPending = false
        hoverPending = false
        return [.collapse, .cancelTimers]
    }

    public mutating func handle(_ i: Input, openOnHover: Bool) -> [Effect] {
        switch i {
        case .streaming(let on):
            isStreaming = on
            return []
        case .setPinned(let on):
            pinned = on
            guard on else { return [] }
            switch state {
            case .collapsed: open(); return [.cancelTimers, .expand, .focusInput]
            case .peeking: open(); return [.cancelTimers]
            case .open: return []
            }
        case .mouseEntered:
            switch state {
            case .collapsed:
                guard openOnHover else { return [] }
                hoverPending = true
                return [.startHoverTimer(0.15)]
            case .peeking: exitPending = false; return [.cancelTimers]
            case .open: return []
            }
        case .mouseExited:
            switch state {
            case .collapsed: hoverPending = false; return [.cancelTimers]
            case .peeking: exitPending = true; return [.startExitTimer(0.6)]
            case .open: return []
            }
        case .hoverTimerFired:
            guard state == .collapsed, hoverPending, openOnHover else { return [] }
            hoverPending = false
            state = .peeking
            return [.expand]
        case .exitTimerFired:
            guard state == .peeking, exitPending, !pinned else { return [] }
            return collapse()
        case .clickBar, .openRequested:
            switch state {
            case .collapsed: open(); return [.cancelTimers, .expand, .focusInput]
            case .peeking: open(); return [.cancelTimers, .focusInput]
            case .open: return i == .openRequested ? [.focusInput] : []
            }
        case .toggle:
            if state == .collapsed {
                open()
                return [.cancelTimers, .expand, .focusInput]
            }
            return collapse()
        case .becameKey:
            if state == .peeking { open() }
            return []
        case .resignedKey:
            guard state == .open, !pinned else { return [] }
            return collapse()
        case .escape:
            if isStreaming { return [.stopStream] }
            guard state != .collapsed, !pinned else { return [] }
            return collapse()
        }
    }
}
