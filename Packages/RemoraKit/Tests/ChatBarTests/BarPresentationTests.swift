import CoreGraphics
import Foundation
import Testing
@testable import ChatBar

@Test func collapsedAlphaFollowsAutoHideAndDim() {
    var s = BarSettings()
    #expect(BarAppearance.collapsedAlpha(s, hovered: false) == 1)
    s.dimWhenUnfocused = true
    #expect(BarAppearance.collapsedAlpha(s, hovered: false) == 0.45)
    #expect(BarAppearance.collapsedAlpha(s, hovered: true) == 1)
    s.autoHide = true
    // Not 0: a fully transparent window lets clicks through, so the hidden bar couldn't be clicked.
    #expect(BarAppearance.collapsedAlpha(s, hovered: false) == 0.01)
    #expect(BarAppearance.collapsedAlpha(s, hovered: true) == 1)
}

@Test func peekFrameBridgesTheBarAndTheCard() {
    // Left edge: the bar sits at the screen edge, the card 8 pt in; the pointer must never leave
    // the panel on its way from one to the other.
    let bar = CGRect(x: 0, y: 460, width: 6, height: 160)
    let card = CGRect(x: 8, y: 280, width: 420, height: 520)
    let p = BarLayout.panel(card: card, bar: bar)
    #expect(p.frame == CGRect(x: 0, y: 280, width: 428, height: 520))
    #expect(p.frame.contains(bar) && p.frame.contains(card))
    // Panel-local, top-left origin.
    #expect(p.card == CGRect(x: 8, y: 0, width: 420, height: 520))
}

@Test func peekFrameUnderTheNotchPutsTheCardBelowIt() {
    let bar = CGRect(x: 800, y: 1080 - 38 - 6, width: 200, height: 38 + 6)  // notch + bar strip
    let card = CGRect(x: 690, y: 1042 - 520, width: 420, height: 520)
    let p = BarLayout.panel(card: card, bar: bar)
    #expect(p.frame.maxY == 1080)
    #expect(p.card.minY == 38)  // the card starts below the notch
    #expect(p.card.size == card.size)
}

@Test func openFrameIsTheCardItself() {
    let card = CGRect(x: 8, y: 280, width: 420, height: 520)
    let p = BarLayout.panel(card: card, bar: nil)
    #expect(p.frame == card)
    #expect(p.card == CGRect(origin: .zero, size: card.size))
}

@Test func linkHostsListWhereEachLinkGoesInOrder() {
    let s = MarkdownBlocks.inline("See [apple.com](https://evil.example/login), [mail](mailto:a@b.com) and [x](https://evil.example/2) and [y](javascript:alert(1))")
    #expect(MarkdownBlocks.linkHosts(s) == ["evil.example", "a@b.com"])
}

@Test func linkHostsEmptyWithoutLinks() {
    #expect(MarkdownBlocks.linkHosts(MarkdownBlocks.inline("plain **bold** text")) == [])
}

@Test func capsuleShowsAPendingCardAboveStreaming() {
    #expect(BarAppearance.capsule(streaming: false, awaitingAnswer: false) == .plain)
    #expect(BarAppearance.capsule(streaming: true, awaitingAnswer: false) == .streaming)
    #expect(BarAppearance.capsule(streaming: true, awaitingAnswer: true) == .awaitingAnswer)
}

@Test func resignKeyKeepsTheBarOpenForACardOrItsOwnPopover() {
    #expect(BarAppearance.collapsesOnResignKey(cardPending: false, detailsOpen: false))
    #expect(!BarAppearance.collapsesOnResignKey(cardPending: true, detailsOpen: false))
    #expect(!BarAppearance.collapsesOnResignKey(cardPending: false, detailsOpen: true))
}
