import Foundation

// TextSpan.find (TextSwap.swift): `<replace from="…" to="…">` selects exactly that span of the document.
var failed = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print(ok ? "ok   \(name)" : "FAIL \(name) \(detail)")
    if !ok { failed += 1 }
}
func span(_ from: String, _ to: String?, _ text: String) -> String? {
    TextSpan.find(from: from, to: to, in: text).map { (text as NSString).substring(with: $0) }
}

let doc = "My summer job\n\nThis summer I worked at a small bakery in my town, and it was honestly a really great experience\nthat taught me a lot.   I never thought I would be able to do.\n\nThe hardest part was waking up at five."
check("a paragraph by its first and last words",
      span("This summer I worked", "able to do.", doc) == "This summer I worked at a small bakery in my town, and it was honestly a really great experience\nthat taught me a lot.   I never thought I would be able to do.")
check("line breaks and double spaces match one space",
      span("great experience that taught", "a lot. I never", doc) == "great experience\nthat taught me a lot.   I never")
check("case and curly quotes don't matter", span("it’s FINE", nil, "So it's fine, really.") == "it's fine")
check("just the words when there's no end", span("small bakery", nil, doc) == "small bakery")
check("the end is searched after the start", span("The hardest", "five.", doc) == "The hardest part was waking up at five.")
check("an end before the start isn't used", span("hardest part", "My summer", doc) == nil)
check("words that aren't there", span("winter job", nil, doc) == nil)
check("emoji and Hebrew keep their offsets", span("שלום", "עולם", "Hi 👋🏽 שלום לכל ה עולם!") == "שלום לכל ה עולם")
check("a one-sentence span (end inside the start)", span("Hello there friend", "friend", "Oh. Hello there friend. Bye.") == "Hello there friend")
exit(failed == 0 ? 0 : 1)
