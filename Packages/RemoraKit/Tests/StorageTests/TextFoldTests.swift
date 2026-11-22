import Testing
import Storage

@Test(arguments: [
    ("Je t’envoie le DECK  vendredi", "je t'envoie le deck vendredi"),
    ("  Réunion\n\td'équipe ", "reunion d'equipe"),
    ("« Bonjour » “quoted” ‘single’ `tick´", "\" bonjour \" \"quoted\" 'single' 'tick'"),
    ("zero\u{200B}width\u{00AD} soft", "zerowidth soft"),
    ("ÉLODIE", "elodie"),
])
func foldNormalisesCaseDiacriticsQuotesAndSpace(input: String, expected: String) {
    #expect(TextFold.fold(input) == expected)
}

@Test func foldIsLocaleIndependent() {
    // Turkish dotted/dotless i must not depend on the current locale.
    #expect(TextFold.fold("ISTANBUL") == "istanbul")
}

@Test func wordsAndJaccard() {
    #expect(TextFold.words("C'est l'Équipe, l'équipe!") == ["c", "est", "l", "equipe"])
    #expect(TextFold.jaccard("Oslo offsite budget", "budget OSLO offsite") == 1)
    #expect(TextFold.jaccard("Oslo offsite", "Oslo budget") == 1.0 / 3.0)
    #expect(TextFold.jaccard("", "  ") == 0)
    #expect(TextFold.jaccard("a", "") == 0)
}
