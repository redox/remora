import Testing
@testable import Memory

@Test(arguments: [("je t'envoie le deck vendredi", true), ("Je t’envoie le DECK  vendredi", true), ("deck", false),
                  ("je t'envoie le budget", false), ("JE T´ENVOIE LE DECK\nVENDREDI", true),
                  ("je t\u{200B}'envoie le deck", true), ("   ", false)])
func quoteCheck(quote: String, ok: Bool) {
    #expect(QuoteCheck.verify(quote, in: slackText) == ok)
}

@Test func quoteCheckFoldsDiacriticsAndGuillemets() {
    let text = "Élodie a écrit : « Je m'occupe de la réservation » hier soir."
    #expect(QuoteCheck.verify("\"je m'occupe de la reservation\"", in: text))
    #expect(QuoteCheck.verify("elodie a ecrit", in: text))
    #expect(!QuoteCheck.verify("Élodie a écrit : « Je m'occupe de l'hôtel »", in: text))
}

@Test func quoteCheckNeedsTwelveFoldedCharacters() {
    let text = "abcdefghijklmnop"
    #expect(!QuoteCheck.verify("ABCDEFGHIJK", in: text))  // 11
    #expect(QuoteCheck.verify("ABCDEFGHIJKL", in: text))  // 12
    #expect(!QuoteCheck.verify("abc   def   gh", in: "abc def gh xyz"))  // 10 after collapsing
}
