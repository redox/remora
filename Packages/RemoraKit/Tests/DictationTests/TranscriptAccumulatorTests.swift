import Testing
@testable import Dictation

struct TranscriptAccumulatorTests {
    @Test func accumulatorJoinsAndReplacesVolatile() {
        var a = TranscriptAccumulator()
        _ = a.apply(.init(text: "bon", isFinal: false)); _ = a.apply(.init(text: "Bonjour.", isFinal: true))
        #expect(a.apply(.init(text: "ça va", isFinal: false)) == .init(finalized: "Bonjour.", volatile: "ça va"))
        _ = a.apply(.init(text: "Ça va ?", isFinal: true)); #expect(a.current.text == "Bonjour. Ça va ?")
    }

    @Test func accumulatorStartsEmpty() {
        let a = TranscriptAccumulator()
        #expect(a.current == .init(finalized: "", volatile: ""))
        #expect(a.current.text == "")
    }

    @Test func accumulatorKeepsLeadingWhitespaceAsIs() {
        var a = TranscriptAccumulator()
        _ = a.apply(.final("Hello"))
        _ = a.apply(.final(" world"))
        #expect(a.current.finalized == "Hello world")
    }

    @Test func accumulatorTrimsTrailingWhitespaceOnly() {
        var a = TranscriptAccumulator()
        #expect(a.apply(.volatile("  hi  ")).volatile == "  hi")
        _ = a.apply(.final("One.  \n"))
        #expect(a.current.finalized == "One.")
        #expect(a.current.volatile == "")
    }

    @Test func accumulatorTextJoinsVolatileTailAndTrims() {
        var a = TranscriptAccumulator()
        _ = a.apply(.final(" Bonjour."))
        _ = a.apply(.volatile("ça va"))
        #expect(a.current.text == "Bonjour. ça va")
    }

    @Test func accumulatorIgnoresEmptyFinalSegment() {
        var a = TranscriptAccumulator()
        _ = a.apply(.final("Hi."))
        _ = a.apply(.final("   "))
        _ = a.apply(.final("Bye."))
        #expect(a.current.finalized == "Hi. Bye.")
    }

    @Test func volatileReplacesVolatile() {
        var a = TranscriptAccumulator()
        _ = a.apply(.volatile("he"))
        #expect(a.apply(.volatile("hello")) == .init(finalized: "", volatile: "hello"))
    }
}
