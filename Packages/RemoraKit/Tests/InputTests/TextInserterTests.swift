import Foundation
import Synchronization
import Testing
@testable import Input

// MARK: - Fakes

final class FakeField: FieldHandle, Sendable {
    struct State {
        var value: String?
        var selection: NSRange?
        var focused = true
        var calls: [String] = []
        /// A paste becomes visible only this long after ⌘V (a slow app).
        var pendingPaste: (value: String, visibleAt: ContinuousClock.Instant)?
        /// Reads after an AX write that still return the old value (the app applies it late).
        var staleReads = 0
        var staleValue: String?
        var writes = 0
        /// The selection set through AX shows up only after this many reads.
        var selectionLagReads = 0
        var laggedSelection: NSRange?
        /// AX writes still to be mangled.
        var mangles = 0
    }
    let pid: pid_t = 42
    let canSetValue: Bool
    let canSetSelectedText: Bool
    /// AX setters report success without changing anything (some web views do this).
    let lies: Bool
    /// The first `mangleWrites` AX writes (either setter) turn the value into this instead (an app
    /// that mangles writes).
    let mangle: String?
    let selectRangeWorks: Bool
    /// setSelectedRange reports success without moving the selection.
    let selectRangeLies: Bool
    let selectionLag: Int
    /// After an AX write, every read shows one more typed character (the user keeps typing).
    let drifts: Bool
    let lateReads: Int
    let pasteLatency: Duration
    let state: Mutex<State>

    init(value: String?, selection: NSRange? = nil, settable: Bool = true, selectedTextSettable: Bool? = nil,
         lies: Bool = false, mangle: String? = nil, mangleWrites: Int = 1,
         selectRangeWorks: Bool = true, selectRangeLies: Bool = false, focused: Bool = true, drifts: Bool = false,
         lateReads: Int = 0, pasteLatency: Duration = .zero, selectionLag: Int = 0) {
        self.selectionLag = selectionLag
        canSetValue = settable; canSetSelectedText = selectedTextSettable ?? settable; self.lies = lies; self.mangle = mangle
        self.selectRangeWorks = selectRangeWorks; self.selectRangeLies = selectRangeLies; self.drifts = drifts
        self.lateReads = lateReads; self.pasteLatency = pasteLatency
        state = Mutex(State(value: value, selection: selection, focused: focused, mangles: mangle == nil ? 0 : mangleWrites))
    }

    var calls: [String] { state.withLock { $0.calls } }
    var currentValue: String? { value() }
    func setFocused(_ f: Bool) { state.withLock { $0.focused = f } }
    func setCurrentValue(_ v: String) { state.withLock { $0.value = v } }

    func value() -> String? {
        state.withLock { st in
            if let p = st.pendingPaste, ContinuousClock.now >= p.visibleAt { st.value = p.value; st.pendingPaste = nil }
            if st.staleReads > 0 { st.staleReads -= 1; return st.staleValue }
            if drifts, st.writes > 0, let v = st.value { st.value = v + "x" }
            return st.value
        }
    }
    func selectedRange() -> NSRange? {
        state.withLock { st in
            if st.selectionLagReads > 0, let lagged = st.laggedSelection {
                st.selectionLagReads -= 1
                if st.selectionLagReads == 0 { st.selection = lagged; st.laggedSelection = nil; return st.selection }
                return st.selection
            }
            return st.selection
        }
    }
    func isFocused() -> Bool { state.withLock { $0.focused } }

    private func wrote(_ st: inout State, old: String?) { st.writes += 1; st.staleReads = lateReads; st.staleValue = old }

    func setValue(_ s: String) -> Bool {
        state.withLock { st in
            st.calls.append("setValue")
            guard canSetValue else { return false }
            if lies { return true }
            let old = st.value
            if let m = mangle, st.mangles > 0 { st.mangles -= 1; st.value = m } else { st.value = s }
            wrote(&st, old: old)
            return true
        }
    }

    func setSelectedRange(_ r: NSRange) -> Bool {
        state.withLock { st in
            st.calls.append("setSelectedRange")
            guard selectRangeWorks else { return false }
            if selectRangeLies { return true }
            if selectionLag > 0 {
                st.laggedSelection = r; st.selectionLagReads = selectionLag
            } else {
                st.selection = r
            }
            return true
        }
    }

    func setSelectedText(_ s: String) -> Bool {
        state.withLock { st in
            st.calls.append("setSelectedText")
            guard canSetSelectedText else { return false }
            if lies { return true }
            if let m = mangle, st.mangles > 0 { st.mangles -= 1; let old = st.value; st.value = m; wrote(&st, old: old); return true }
            guard let v = st.value, let sel = st.selection else { return false }
            st.value = (v as NSString).replacingCharacters(in: sel, with: s)
            st.selection = NSRange(location: sel.location + s.utf16.count, length: 0)
            wrote(&st, old: v)
            return true
        }
    }

    /// What ⌘V does in the app: replace the selection with the pasteboard text.
    func paste(_ text: String) {
        state.withLock { st in
            st.calls.append("paste")
            guard let v = st.value, let sel = st.selection else { return }
            let pasted = (v as NSString).replacingCharacters(in: sel, with: text)
            if pasteLatency > .zero {
                st.pendingPaste = (pasted, ContinuousClock.now + pasteLatency)
            } else {
                st.value = pasted
            }
        }
    }

    func selectAll() {
        state.withLock { st in
            st.calls.append("selectAll")
            st.selection = NSRange(location: 0, length: (st.value ?? "").utf16.count)
        }
    }
}

final class FakePasteboard: PasteboardAccess, Sendable {
    struct State {
        var items: [[PasteboardEntry]]
        var changeCount = 100
        var writes = 0
        var restores = 0
        var written: String?
        var restoredAt: ContinuousClock.Instant?
    }
    let original: PasteboardContents
    let state: Mutex<State>

    init(items: [[PasteboardEntry]]) {
        original = PasteboardContents(items: items)
        state = Mutex(State(items: items))
    }

    var current: PasteboardContents { state.withLock { PasteboardContents(items: $0.items) } }
    var writes: Int { state.withLock { $0.writes } }
    var restores: Int { state.withLock { $0.restores } }
    var written: String? { state.withLock { $0.written } }
    var restoredAt: ContinuousClock.Instant? { state.withLock { $0.restoredAt } }

    /// Someone else (the user) copied something.
    func userCopy(_ s: String) {
        state.withLock { $0.items = [[e("public.utf8-plain-text", s)]]; $0.changeCount += 1 }
    }

    var changeCount: Int { state.withLock { $0.changeCount } }
    func snapshot() -> PasteboardContents { current }
    func write(text: String) -> Int {
        state.withLock {
            $0.items = [[e("public.utf8-plain-text", text)]]
            $0.writes += 1; $0.written = text; $0.changeCount += 1
            return $0.changeCount
        }
    }
    func restore(_ c: PasteboardContents) -> Int {
        state.withLock {
            $0.items = c.items; $0.restores += 1; $0.changeCount += 1; $0.restoredAt = .now
            return $0.changeCount
        }
    }
}

final class FakeKeys: KeySynthesizing, Sendable {
    let log = Mutex<[String]>([])
    let resolves: Bool
    let onCommandV: @Sendable () -> Void
    let onCommandA: @Sendable () -> Void
    let pastedAt = Mutex<ContinuousClock.Instant?>(nil)
    init(resolves: Bool = true, onCommandV: @escaping @Sendable () -> Void = {}, onCommandA: @escaping @Sendable () -> Void = {}) {
        self.resolves = resolves; self.onCommandV = onCommandV; self.onCommandA = onCommandA
    }
    var calls: [String] { log.withLock { $0 } }
    func commandV() async -> Bool {
        guard resolves else { return false }
        log.withLock { $0.append("⌘V") }
        pastedAt.withLock { $0 = .now }
        onCommandV()
        return true
    }
    func commandA() async -> Bool {
        guard resolves else { return false }
        log.withLock { $0.append("⌘A") }
        onCommandA()
        return true
    }
}

final class FakeApps: AppActivating, Sendable {
    let front: Mutex<pid_t?>
    let activations = Mutex(0)
    init(front: pid_t? = 42) { self.front = Mutex(front) }
    func frontmostPID() -> pid_t? { front.withLock { $0 } }
    func activate(pid: pid_t) async -> Bool {
        activations.withLock { $0 += 1 }
        front.withLock { $0 = pid }
        return true
    }
}

private func e(_ type: String, _ s: String) -> PasteboardEntry { PasteboardEntry(type: type, data: Data(s.utf8)) }
private let png = PasteboardEntry(type: "public.png", data: Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3]))
private let tiff = PasteboardEntry(type: "public.tiff", data: Data([0x4D, 0x4D, 0, 42, 9]))
private let rtf = e("public.rtf", "{\\rtf1 a}")
private let ownPID: pid_t = 1

private func inserter(_ pb: FakePasteboard, keys: FakeKeys = FakeKeys(), apps: FakeApps = FakeApps()) -> TextInserter {
    TextInserter(pasteboard: pb, keys: keys, apps: apps, pasteWait: .milliseconds(100), pollInterval: .milliseconds(25),
                 axSettle: .milliseconds(75), ownPID: ownPID, sleep: { _ in })
}

/// Keys wired to a field so ⌘V/⌘A act on it like the real app would.
private func keys(for field: FakeField, pb: FakePasteboard) -> FakeKeys {
    FakeKeys(onCommandV: { field.paste(pb.written ?? "") }, onCommandA: { field.selectAll() })
}

// MARK: - AX path

@Test func axWriteVerifiedSkipsPasteboard() async {
    let pb = FakePasteboard(items: [[e("public.utf8-plain-text", "clip")]])
    let k = FakeKeys()
    let field = FakeField(value: "Hello world", selection: NSRange(location: 6, length: 5))
    let out = await inserter(pb, keys: k).insert("there", target: .range(NSRange(location: 6, length: 5)), expectedValue: "Hello world",
                                                  into: field, preferPaste: false)
    #expect(out == .ax)
    #expect(field.currentValue == "Hello there")
    #expect(pb.writes == 0 && k.calls.isEmpty)
    let whole = FakeField(value: "old")
    #expect(await inserter(pb, keys: k).insert("new", target: .whole, expectedValue: "old", into: whole, preferPaste: false) == .ax)
    #expect(whole.currentValue == "new" && pb.writes == 0)
}

@Test func wholeAXWriteReplacesTheSelectionSoItCanBeUndone() async {
    // Select-all + selected text keeps the app's undo and its attributed-text handling; setValue does not.
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old text")
    let out = await inserter(pb).insert("new", target: .whole, expectedValue: "old text", into: field, preferPaste: false)
    #expect(out == .ax && field.currentValue == "new")
    #expect(field.calls == ["setSelectedRange", "setSelectedText"])
}

@Test func wholeAXWriteUsesSetValueWhenSelectedTextIsNotSettable() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old", selectedTextSettable: false)
    let out = await inserter(pb).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: false)
    #expect(out == .ax && field.currentValue == "new")
    #expect(field.calls == ["setValue"])
}

@Test func wholeAXWriteUsesSetValueWhenTheSelectionDoesNotCoverTheField() async {
    // Writing the selected text over a partial selection would leave the rest of the old text.
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old", selection: NSRange(location: 1, length: 0), selectRangeLies: true)
    let out = await inserter(pb).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: false)
    #expect(out == .ax && field.currentValue == "new")
    #expect(!field.calls.contains("setSelectedText") && field.calls.contains("setValue"))
}

@Test func wholeAXWriteNeverReplacesAnUnverifiedSelection() async {
    // The app ignores the selection change and exposes no selection: the caret could be anywhere.
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old", selectRangeLies: true)
    let out = await inserter(pb).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: false)
    #expect(out == .ax && field.currentValue == "new")
    #expect(!field.calls.contains("setSelectedText") && field.calls.contains("setValue"))
    // Without a settable value it goes to the paste path instead.
    let noValue = FakeField(value: "old", settable: false, selectedTextSettable: true, selectRangeLies: true)
    let k = FakeKeys()
    _ = await inserter(pb, keys: k).insert("new", target: .whole, expectedValue: "old", into: noValue, preferPaste: false)
    #expect(!noValue.calls.contains("setSelectedText") && !noValue.calls.contains("setValue") && k.calls.contains("⌘V"))
}

@Test func lateAXWriteIsReReadBeforePasting() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old", lateReads: 1)
    let k = keys(for: field, pb: pb)
    // The first read after the write still shows the old value; the re-read after the settle shows it.
    let out = await inserter(pb, keys: k).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: false)
    #expect(out == .ax)
    #expect(k.calls.isEmpty && pb.writes == 0)
}

@Test func abortsWhenFieldChangedSinceRead() async {
    let pb = FakePasteboard(items: [])
    let k = FakeKeys()
    let field = FakeField(value: "abcd")
    for preferPaste in [false, true] {
        let out = await inserter(pb, keys: k).insert("x", target: .whole, expectedValue: "abc", into: field, preferPaste: preferPaste)
        #expect(out == .fieldChanged)
    }
    #expect(field.calls.isEmpty && pb.writes == 0 && k.calls.isEmpty)
    // App-side normalisation alone (line endings, curly quotes, trailing spaces) is not a change.
    let crlf = FakeField(value: "it’s  \r\nok")
    #expect(await inserter(pb, keys: k).insert("x", target: .whole, expectedValue: "it's\nok", into: crlf, preferPaste: false) == .ax)
}

@Test func abortsWhenFieldChangesDuringPastePreparation() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "abc")
    let k = keys(for: field, pb: pb)
    // The user types while the Edit bar is being hidden.
    let out = await inserter(pb, keys: k).insert("x", target: .whole, expectedValue: "abc", into: field, preferPaste: true,
                                                  beforePaste: { field.setCurrentValue("abcd") })
    #expect(out == .fieldChanged)
    #expect(pb.writes == 0 && k.calls.isEmpty)
}

@Test func abortsWhenTargetNoLongerFocused() async {
    let pb = FakePasteboard(items: [[e("public.utf8-plain-text", "clip")]])
    let k = FakeKeys()
    let field = FakeField(value: "abc", focused: false)
    let before = Mutex(0), after = Mutex(0)
    let out = await inserter(pb, keys: k).insert("x", target: .whole, expectedValue: "abc", into: field, preferPaste: true,
                                                  beforePaste: { before.withLock { $0 += 1 } }, afterPaste: { after.withLock { $0 += 1 } })
    #expect(out == .notFocused)
    #expect(field.calls.isEmpty && pb.writes == 0 && k.calls.isEmpty)
    #expect(before.withLock { $0 } == 1 && after.withLock { $0 } == 1)
    // No AX write into a background field either.
    let bg = FakeField(value: "abc", focused: false)
    #expect(await inserter(pb, keys: k).insert("x", target: .whole, expectedValue: "abc", into: bg, preferPaste: false) == .notFocused)
    #expect(bg.calls.isEmpty && pb.writes == 0 && k.calls.isEmpty)
}

@Test func focusLostWhileSelectingAbortsBeforePasteboard() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "abc", selectRangeWorks: false)
    // ⌘A lands, then the user clicks elsewhere before ⌘V.
    let k = FakeKeys(onCommandA: { field.selectAll(); field.setFocused(false) })
    let out = await inserter(pb, keys: k).insert("x", target: .whole, expectedValue: "abc", into: field, preferPaste: true)
    #expect(out == .notFocused)
    #expect(pb.writes == 0 && k.calls == ["⌘A"])
}

@Test func editBarHiddenBeforeFocusCheck() async {
    let pb = FakePasteboard(items: [])
    // The Edit bar holds key focus until beforePaste hides it.
    let field = FakeField(value: "abc", focused: false)
    let k = keys(for: field, pb: pb)
    let out = await inserter(pb, keys: k).insert("xyz", target: .whole, expectedValue: "abc", into: field, preferPaste: false,
                                                  beforePaste: { field.setFocused(true) })
    #expect(out == .paste(verified: true) && field.currentValue == "xyz")
    #expect(!field.calls.contains("setValue"))  // AX write skipped while not focused
}

@Test func neverActivatesOverAnotherApp() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "a")
    let apps = FakeApps(front: 7)
    let out = await inserter(pb, keys: keys(for: field, pb: pb), apps: apps).insert("b", target: .whole, expectedValue: "a", into: field, preferPaste: true)
    #expect(out == .notFocused && apps.activations.withLock { $0 } == 0 && pb.writes == 0)
}

@Test func pasteReactivatesTargetFromRemora() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "a")
    let apps = FakeApps(front: ownPID)
    let out = await inserter(pb, keys: keys(for: field, pb: pb), apps: apps).insert("b", target: .whole, expectedValue: "a", into: field, preferPaste: true)
    #expect(out == .paste(verified: true) && apps.activations.withLock { $0 } == 1)
}

@Test func axLieFallsBackToPaste() async {
    let pb = FakePasteboard(items: [[e("public.utf8-plain-text", "clip")]])
    let field = FakeField(value: "Hello world", selection: NSRange(location: 0, length: 0), lies: true)
    let k = keys(for: field, pb: pb)
    let out = await inserter(pb, keys: k).insert("there", target: .range(NSRange(location: 6, length: 5)), expectedValue: "Hello world",
                                                  into: field, preferPaste: false)
    #expect(k.calls == ["⌘V"])
    #expect(out == .paste(verified: true) && field.currentValue == "Hello there")
    #expect(pb.current == pb.original)
}

@Test func mangledAXWriteIsUndoneThenPasted() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old", mangle: "garbage")
    let k = keys(for: field, pb: pb)
    let out = await inserter(pb, keys: k).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: false)
    #expect(out == .paste(verified: true) && field.currentValue == "new")
}

@Test func unrecoverableAXWriteFails() async {
    let pb = FakePasteboard(items: [])
    let k = FakeKeys()
    // Mangles the selected-text write, and the undo's setValue mangles too.
    let field = FakeField(value: "Hello world", selection: NSRange(location: 0, length: 0), mangle: "garbage", mangleWrites: 2)
    let out = await inserter(pb, keys: k).insert("x", target: .range(NSRange(location: 0, length: 5)), expectedValue: "Hello world",
                                                  into: field, preferPaste: false)
    #expect(out == .failed)
    #expect(pb.writes == 0 && k.calls.isEmpty)
}

@Test func neverRevertsAFieldThatKeepsChanging() async {
    let pb = FakePasteboard(items: [])
    let k = FakeKeys()
    let field = FakeField(value: "Hello world", selection: NSRange(location: 0, length: 0), drifts: true)
    let out = await inserter(pb, keys: k).insert("Howdy", target: .range(NSRange(location: 0, length: 5)), expectedValue: "Hello world",
                                                  into: field, preferPaste: false)
    #expect(out == .fieldChanged)
    #expect(!field.calls.contains("setValue") && pb.writes == 0 && k.calls.isEmpty)
}

@Test func webBackedGoesStraightToPaste() async {
    let pb = FakePasteboard(items: [[e("public.utf8-plain-text", "clip")]])
    let field = FakeField(value: "Hello world", selection: NSRange(location: 0, length: 0))
    let k = keys(for: field, pb: pb)
    let order = Mutex<[String]>([])
    let out = await inserter(pb, keys: k).insert("there", target: .range(NSRange(location: 6, length: 5)), expectedValue: "Hello world",
                                                  into: field, preferPaste: true,
                                                  beforePaste: { order.withLock { $0.append("before") } },
                                                  afterPaste: { order.withLock { $0.append("after") } })
    #expect(out == .paste(verified: true))
    #expect(field.calls == ["setSelectedRange", "paste"])
    #expect(order.withLock { $0 } == ["before", "after"])
}

@Test func unverifiedPasteWhenValueUnreadable() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: nil, selection: NSRange(location: 0, length: 3))
    let k = FakeKeys()
    let out = await inserter(pb, keys: k).insert("b", target: .range(NSRange(location: 0, length: 3)), expectedValue: nil, into: field, preferPaste: false)
    #expect(out == .paste(verified: false))
    #expect(!field.calls.contains("setSelectedText") && k.calls == ["⌘V"])
    #expect(pb.restores == 1)
}

@Test func outOfBoundsRangeFails() async {
    let pb = FakePasteboard(items: [])
    let k = FakeKeys()
    let field = FakeField(value: "abc")
    #expect(await inserter(pb, keys: k).insert("x", target: .range(NSRange(location: 2, length: 5)), expectedValue: "abc", into: field, preferPaste: false) == .failed)
    #expect(field.calls.isEmpty && k.calls.isEmpty)
}

// MARK: - Selection

@Test func rangeSelectionThatDoesNotMoveAborts() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "Hello world", selection: NSRange(location: 0, length: 0), selectRangeLies: true)
    let k = keys(for: field, pb: pb)
    let out = await inserter(pb, keys: k).insert("there", target: .range(NSRange(location: 6, length: 5)), expectedValue: "Hello world",
                                                  into: field, preferPaste: true)
    #expect(out == .failed && pb.writes == 0 && k.calls.isEmpty)
}

@Test func wholeSelectionThatDoesNotMoveFallsBackToSelectAll() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old", selection: NSRange(location: 1, length: 0), selectRangeLies: true)
    let k = keys(for: field, pb: pb)
    let out = await inserter(pb, keys: k).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: true)
    #expect(k.calls == ["⌘A", "⌘V"])
    #expect(out == .paste(verified: true) && field.currentValue == "new")
}

@Test func wholeTargetSelectsAllBeforePaste() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old", settable: false, selectRangeWorks: false)
    let k = keys(for: field, pb: pb)
    let out = await inserter(pb, keys: k).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: false)
    #expect(k.calls == ["⌘A", "⌘V"])
    #expect(out == .paste(verified: true) && field.currentValue == "new")
}

@Test func selectAllThatNeverLandsAborts() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "old", selection: NSRange(location: 1, length: 0), selectRangeWorks: false)
    let k = FakeKeys()  // ⌘A posted, but the app ignores it
    let out = await inserter(pb, keys: k).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: true)
    #expect(out == .failed && pb.writes == 0 && k.calls == ["⌘A"])
}

// MARK: - Keyboard layout

@Test func unresolvableSelectAllFailsWithoutTouchingPasteboard() async {
    let pb = FakePasteboard(items: [[png]])
    let field = FakeField(value: "old", selectRangeWorks: false)
    let out = await inserter(pb, keys: FakeKeys(resolves: false)).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: true)
    #expect(out == .failed && pb.writes == 0)
}

@Test func unresolvablePasteFailsAndRestores() async {
    let pb = FakePasteboard(items: [[png, tiff]])
    let field = FakeField(value: "old")
    let out = await inserter(pb, keys: FakeKeys(resolves: false)).insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: true)
    #expect(out == .failed)
    #expect(pb.current == pb.original && field.currentValue == "old")
}

// MARK: - Pasteboard

@Test func restoresMultiItemMultiTypePasteboard() async {
    let pb = FakePasteboard(items: [[png, tiff], [e("public.utf8-plain-text", "a"), rtf]])
    _ = await inserter(pb).insert("new", target: .whole, expectedValue: "old", into: FakeField(value: "old", settable: false), preferPaste: false)
    #expect(pb.writes == 1 && pb.restores == 1)
    #expect(pb.current == pb.original)
}

@Test func pasteboardContentsCompareTypeOrder() {
    #expect(PasteboardContents(items: [[png, tiff]]) != PasteboardContents(items: [[tiff, png]]))
    #expect(PasteboardContents(items: [[png], [tiff]]) != PasteboardContents(items: [[tiff], [png]]))
}

@Test func doesNotRestoreOverNewerCopy() async {
    let pb = FakePasteboard(items: [[png]])
    let k = FakeKeys(onCommandV: { pb.userCopy("user's copy") })
    _ = await inserter(pb, keys: k).insert("new", target: .whole, expectedValue: "old", into: FakeField(value: "old", settable: false), preferPaste: false)
    #expect(pb.restores == 0)
    #expect(pb.current == PasteboardContents(items: [[e("public.utf8-plain-text", "user's copy")]]))
}

@Test func restoreWaitsForThePasteEvenWhenCancelled() async throws {
    let pb = FakePasteboard(items: [[png]])
    let field = FakeField(value: "old", pasteLatency: .milliseconds(80))
    let k = keys(for: field, pb: pb)
    let ins = TextInserter(pasteboard: pb, keys: k, apps: FakeApps(), pasteWait: .seconds(2), pollInterval: .milliseconds(5),
                           axSettle: .zero, ownPID: ownPID)  // real, cancellable Task.sleep
    let task = Task { await ins.insert("new", target: .whole, expectedValue: "old", into: field, preferPaste: true) }
    task.cancel()
    let out = await task.value
    #expect(out == .paste(verified: true))
    let pasted = try #require(k.pastedAt.withLock { $0 })
    let restored = try #require(pb.restoredAt)
    #expect(restored >= pasted + .milliseconds(80))
    #expect(pb.current == pb.original)
}

// MARK: - Completion signals

@Test func identicalRewriteIsANoOp() async {
    let pb = FakePasteboard(items: [[png]])
    let k = FakeKeys()
    let before = Mutex(0)
    for (target, text) in [(InsertionTarget.whole, "Hello world"), (.range(NSRange(location: 6, length: 5)), "world")] {
        for preferPaste in [false, true] {
            let field = FakeField(value: "Hello world\r\n")
            let expected = "Hello world\r\n"
            let t = target == .whole ? text + "\n" : text
            let out = await inserter(pb, keys: k).insert(t, target: target, expectedValue: expected, into: field, preferPaste: preferPaste,
                                                          beforePaste: { before.withLock { $0 += 1 } })
            #expect(out == .noChange)
            #expect(field.calls.isEmpty)
        }
    }
    #expect(pb.writes == 0 && pb.restores == 0 && k.calls.isEmpty && before.withLock { $0 } == 0)
}

@Test func smartQuoteOnlyChangeRestoresOnlyAfterThePasteLands() async throws {
    let pb = FakePasteboard(items: [[e("public.utf8-plain-text", "secret")]])
    let field = FakeField(value: "it's ok", pasteLatency: .milliseconds(80))
    let k = keys(for: field, pb: pb)
    let ins = TextInserter(pasteboard: pb, keys: k, apps: FakeApps(), pasteWait: .seconds(2), pollInterval: .milliseconds(5),
                           axSettle: .zero, ownPID: ownPID)
    let out = await ins.insert("it’s ok", target: .whole, expectedValue: "it's ok", into: field, preferPaste: true)
    #expect(out == .paste(verified: true) && field.currentValue == "it’s ok")
    let pasted = try #require(k.pastedAt.withLock { $0 })
    let restored = try #require(pb.restoredAt)
    #expect(restored >= pasted + .milliseconds(80))
    #expect(pb.current == pb.original)
}

@Test func smartQuoteOnlyAXWriteThatDidNothingIsNotReportedAsDone() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "it's ok  ", lies: true)
    let k = keys(for: field, pb: pb)
    let out = await inserter(pb, keys: k).insert("it’s ok", target: .whole, expectedValue: "it's ok  ", into: field, preferPaste: false)
    #expect(out != .ax)
    #expect(k.calls.contains("⌘V") && out == .paste(verified: true) && field.currentValue == "it’s ok")
}

@Test func unreadableValueWaitsTheFullPasteWait() async {
    let pb = FakePasteboard(items: [[png]])
    let field = FakeField(value: nil, selection: NSRange(location: 0, length: 3))
    let slept = Mutex(Duration.zero)
    let ins = TextInserter(pasteboard: pb, keys: FakeKeys(), apps: FakeApps(), pasteWait: .milliseconds(1500),
                           pollInterval: .milliseconds(25), axSettle: .zero, ownPID: ownPID,
                           sleep: { d in slept.withLock { $0 += d } })
    _ = await ins.insert("b", target: .range(NSRange(location: 0, length: 3)), expectedValue: nil, into: field, preferPaste: true)
    #expect(slept.withLock { $0 } >= .milliseconds(1500))
    #expect(pb.current == pb.original)
}

@Test func laggingRangeSelectionIsAwaited() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "Hello world", selection: NSRange(location: 0, length: 0), selectionLag: 3)
    let k = keys(for: field, pb: pb)
    let out = await inserter(pb, keys: k).insert("there", target: .range(NSRange(location: 6, length: 5)), expectedValue: "Hello world",
                                                  into: field, preferPaste: true)
    #expect(out == .paste(verified: true) && field.currentValue == "Hello there")
}

// MARK: - Caret and frontmost paste

@Test func caretInsertUsesSelectedTextAndVerifies() async {
    let pb = FakePasteboard(items: [[e("public.utf8-plain-text", "clip")]])
    let k = FakeKeys()
    let field = FakeField(value: "Hello world", selection: NSRange(location: 5, length: 0))
    let out = await inserter(pb, keys: k).insert(" there", target: .caret, expectedValue: "Hello world", into: field, preferPaste: false)
    #expect(out == .ax)
    #expect(field.currentValue == "Hello there world")
    #expect(field.calls == ["setSelectedText"] && pb.writes == 0 && k.calls.isEmpty)
}

@Test func caretReplacesTheSelection() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "Hello world", selection: NSRange(location: 6, length: 5))
    let out = await inserter(pb).insert("there", target: .caret, expectedValue: "Hello world", into: field, preferPaste: false)
    #expect(out == .ax && field.currentValue == "Hello there" && !field.calls.contains("setSelectedRange"))
}

@Test func caretWithUnreadableSelectionPastesWithoutSelecting() async {
    let pb = FakePasteboard(items: [[e("public.utf8-plain-text", "clip")]])
    let k = FakeKeys()
    let field = FakeField(value: "Hello world", selection: nil)
    let out = await inserter(pb, keys: k).insert(" there", target: .caret, expectedValue: "Hello world", into: field, preferPaste: false)
    #expect(out == .paste(verified: false))
    #expect(k.calls == ["⌘V"])
    #expect(!field.calls.contains("setSelectedRange") && !field.calls.contains("selectAll") && !field.calls.contains("setSelectedText"))
    #expect(pb.current == pb.original)
}

@Test func caretPasteLandsAtTheCaretWhenAXIsPreferredOff() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "Hello world", selection: NSRange(location: 5, length: 0))
    let out = await inserter(pb, keys: keys(for: field, pb: pb)).insert(" there", target: .caret, expectedValue: "Hello world",
                                                                          into: field, preferPaste: true)
    #expect(out == .paste(verified: true) && field.currentValue == "Hello there world")
    #expect(!field.calls.contains("setSelectedRange") && !field.calls.contains("selectAll"))
}

@Test func caretStillRefusesAChangedField() async {
    let pb = FakePasteboard(items: [])
    let field = FakeField(value: "Hello there", selection: NSRange(location: 5, length: 0))
    let out = await inserter(pb).insert("x", target: .caret, expectedValue: "Hello world", into: field, preferPaste: false)
    #expect(out == .fieldChanged && pb.writes == 0)
}

@Test func pasteIntoFrontmostRestoresPasteboard() async {
    let pb = FakePasteboard(items: [[png, tiff], [e("public.utf8-plain-text", "a"), rtf]])
    let k = FakeKeys()
    let out = await inserter(pb, keys: k, apps: FakeApps(front: 7)).pasteIntoFrontmost("dictated", expectedPID: 7)
    #expect(out == .paste(verified: false))
    #expect(pb.written == "dictated" && k.calls == ["⌘V"] && pb.restores == 1)
    #expect(pb.current == pb.original)
}

@Test func pasteIntoFrontmostKeepsTheDictationOnTheClipboardForTheFullPasteWait() async {
    let pb = FakePasteboard(items: [[png]])
    let k = FakeKeys()
    let waits = Mutex<[Duration]>([])
    let ins = TextInserter(pasteboard: pb, keys: k, apps: FakeApps(front: 7),
                           pasteWait: .milliseconds(1500), ownPID: ownPID, sleep: { duration in
        #expect(k.calls == ["⌘V"])
        #expect(pb.restores == 0)
        #expect(pb.written == "dictated")
        waits.withLock { $0.append(duration) }
    })
    #expect(await ins.pasteIntoFrontmost("dictated", expectedPID: 7) == .paste(verified: false))
    #expect(waits.withLock { $0 } == [.milliseconds(1500)])
    #expect(pb.restores == 1 && pb.current == pb.original)
}

@Test func pasteIntoFrontmostDoesNotClobberANewCopy() async {
    let pb = FakePasteboard(items: [[png]])
    let k = FakeKeys(onCommandV: { pb.userCopy("user's copy") })
    _ = await inserter(pb, keys: k, apps: FakeApps(front: 7)).pasteIntoFrontmost("dictated", expectedPID: 7)
    #expect(pb.restores == 0)
}

@Test func pasteIntoFrontmostRefusesOwnApp() async {
    let pb = FakePasteboard(items: [[png]])
    let k = FakeKeys()
    #expect(await inserter(pb, keys: k, apps: FakeApps(front: ownPID)).pasteIntoFrontmost("x", expectedPID: ownPID) == .notFocused)
    #expect(await inserter(pb, keys: k, apps: FakeApps(front: nil)).pasteIntoFrontmost("x", expectedPID: 7) == .notFocused)
    #expect(pb.writes == 0 && k.calls.isEmpty)
}

@Test func pasteIntoFrontmostRestoresWhenKeyCannotBeResolved() async {
    let pb = FakePasteboard(items: [[png]])
    let out = await inserter(pb, keys: FakeKeys(resolves: false), apps: FakeApps(front: 7)).pasteIntoFrontmost("x", expectedPID: 7)
    #expect(out == .failed && pb.current == pb.original)
}

@Test func pasteIntoFrontmostRefusesAnotherApp() async {
    let pb = FakePasteboard(items: [[png]])
    let k = FakeKeys()
    #expect(await inserter(pb, keys: k, apps: FakeApps(front: 9)).pasteIntoFrontmost("x", expectedPID: 7) == .notFocused)
    #expect(pb.writes == 0 && k.calls.isEmpty)
}

@Test func reviewedCaretInsertionRefusesASelectionThatMovedBeforePaste() async {
    let original = NSRange(location: 5, length: 0)
    let field = FakeField(value: "Hello world", selection: original)
    let pb = FakePasteboard(items: [])
    let k = keys(for: field, pb: pb)
    let outcome = await inserter(pb, keys: k).insert(
        " there", target: .caret, expectedValue: "Hello world", expectedSelection: original,
        into: field, preferPaste: true,
        beforePaste: { _ = field.setSelectedRange(NSRange(location: 6, length: 5)) })
    #expect(outcome == .fieldChanged)
    #expect(field.value() == "Hello world")
}
