import XCTest

/// How instructions become spoken pieces (Sources/Core/PhraseBook.swift).
final class PhraseBookTests: XCTestCase {
    func testASentenceEndingInTheStreetIsSplitSoTheStreetCanBeSaidByAnotherVoice() {
        let s = PhraseBook.split("turn right onto Schaffhauserplatz.", street: "Schaffhauserplatz")
        XCTAssertEqual(s.lead, "turn right onto")
        XCTAssertEqual(s.street, "Schaffhauserplatz")
        XCTAssertEqual(s.closing, ".")
    }

    func testASentenceWithoutAStreetAtItsEndStaysWhole() {
        XCTAssertEqual(PhraseBook.split("enter the roundabout and take the 2nd exit.", street: nil).lead, "enter the roundabout and take the 2nd exit")
        XCTAssertNil(PhraseBook.split("turn right onto Foo then left.", street: "Foo").street)
        XCTAssertNil(PhraseBook.split("Schaffhauserplatz.", street: "Schaffhauserplatz").street)          // nothing in front of it: not an instruction to split
        XCTAssertEqual(PhraseBook.split("keep left", street: nil).closing, "")
    }

    func testAHeadsUpIsADistanceAnInstructionAndAStreet() {
        let phrase = PhraseBook.spoken("turn right onto Schaffhauserplatz.", street: "Schaffhauserplatz", speedMps: 14, streetNames: true, distance: "600 meters")
        XCTAssertEqual(phrase.parts.map(\.kind), [.distance, .instruction, .street])
        XCTAssertEqual(phrase.parts.map(\.text), ["In 600 meters", "turn right onto", "Schaffhauserplatz"])
        XCTAssertEqual(phrase.text, "In 600 meters, turn right onto Schaffhauserplatz.")
    }

    func testTheStreetIsLeftOutAboveEightyOrWhenSwitchedOff() {
        let fast = PhraseBook.spoken("turn right onto Schaffhauserplatz.", street: "Schaffhauserplatz", speedMps: 25, streetNames: true, distance: "1 kilometer")
        XCTAssertEqual(fast.text, "In 1 kilometer, turn right.")
        let off = PhraseBook.spoken("Turn left onto Hardstrasse.", street: "Hardstrasse", speedMps: 8, streetNames: false)
        XCTAssertEqual(off.text, "Turn left.")
        XCTAssertEqual(off.parts.count, 1)
    }

    func testThePunctuationOfTheSourceIsKeptSoTheWordsDoNotChange() {
        XCTAssertEqual(PhraseBook.spoken("Turn left", street: nil, speedMps: 5, streetNames: true).text, "Turn left")
        XCTAssertEqual(Phrase("Starting navigation. Drive east.").text, "Starting navigation. Drive east.")
        XCTAssertEqual(Phrase.alert("Hairpin left").text, "Hairpin left.")
    }

    func testWarningsReadWithCommas() {
        let phrase = Phrase(parts: [SpokenPart(kind: .alert, text: "Sharp right"), SpokenPart(kind: .alert, text: "slow to 40")])
        XCTAssertEqual(phrase.text, "Sharp right, slow to 40.")
    }

    func testAStreetNameIsGermanEverythingElseEnglish() {
        XCTAssertEqual(SpokenPart(kind: .street, text: "Hardstrasse").language, "de")
        XCTAssertEqual(SpokenPart(kind: .instruction, text: "turn left").language, "en")
        XCTAssertEqual(SpokenPart(kind: .street, text: "Hardstrasse").key, "de|Hardstrasse")
        XCTAssertNotEqual(SpokenPart(kind: .street, text: "x").key, SpokenPart(kind: .instruction, text: "x").key)
    }

    func testThereIsABreathAfterADistanceAndHardlyAnyBeforeAStreet() {
        let distance = SpokenPart(kind: .distance, text: "In 300 meters"), instruction = SpokenPart(kind: .instruction, text: "turn left onto"), street = SpokenPart(kind: .street, text: "Hardstrasse")
        XCTAssertGreaterThan(PhraseBook.pause(after: distance, before: instruction), 0.1)
        XCTAssertLessThan(PhraseBook.pause(after: instruction, before: street), 0.1)
    }

    func testEveryDistanceTheEngineCanSayIsOneOfTheFixedPieces() {
        let fixed = Set(PhraseBook.distanceParts.map(\.text))
        for metres in stride(from: 50.0, through: 12_000.0, by: 37.0) {
            let text = "In " + GuidanceText.distancePhrase(metres)
            if metres <= 10_000 { XCTAssertTrue(fixed.contains(text), "\(metres): \(text)") }
        }
    }

    func testAdvisorySpeedsAndLimitsHavePieces() {
        XCTAssertTrue(PhraseBook.advisoryParts.contains(SpokenPart(kind: .alert, text: "slow to 40")))
        XCTAssertTrue(PhraseBook.limitParts.contains(SpokenPart(kind: .alert, text: "Limit 80")))
    }
}
