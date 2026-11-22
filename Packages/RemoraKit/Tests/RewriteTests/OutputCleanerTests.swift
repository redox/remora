import Foundation
import Testing
@testable import Rewrite

@Test(arguments: [("\"Salut !\"", "salut", "Salut !"), ("```\nfoo\n```", "x", "foo"), ("  hi  ", " x ", " hi "),
                  ("“Bonjour”", "x", "Bonjour"), ("«Bonjour»", "x", "Bonjour"), ("\"Salut\"", "\"hi\"", "\"Salut\""),
                  ("```swift\nlet a = 1\n```", "x", "let a = 1"), ("```\nfoo\n```", "```bar```", "```\nfoo\n```"),
                  ("\"a\" and \"b\"", "x", "\"a\" and \"b\""), ("a\r\nb", "x", "a\nb"), ("a\r\nb", "x\r\ny", "a\r\nb")])
func cleansOutput(raw: String, original: String, expected: String) {
    #expect(OutputCleaner.clean(raw, original: original) == expected)
}

@Test func fenceKeptWhenBodyHoldsAnotherFence() {
    let raw = "```\nfoo\n```\nbar\n```"
    #expect(OutputCleaner.clean(raw, original: "x") == raw)
    let two = "```a``` and ```b```"
    #expect(OutputCleaner.clean(two, original: "x") == two)
}

@Test func fenceKeepsFirstLineIndentation() {
    #expect(OutputCleaner.clean("```\n    indented\n  more\n```", original: "x") == "    indented\n  more")
    #expect(OutputCleaner.clean("```python\n\tdef f(): pass\n```", original: "x") == "\tdef f(): pass")
}
