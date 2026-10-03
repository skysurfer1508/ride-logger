import Foundation

/// One piece of a spoken phrase. A phrase is said as a few pieces with a short pause between them ("In 300 meters" ... "turn left onto" ... "Hardstrasse"): the pieces
/// are what the server renders and the phone caches, so the same few hundred pieces serve every route.
struct SpokenPart: Equatable, Hashable {
    enum Kind: String { case distance, instruction, street, alert }

    let kind: Kind
    let text: String

    /// The voice's language for this piece: a street name is said by a German voice (an English voice makes a mess of "Hardstrasse"), everything else English.
    var language: String { kind == .street ? "de" : "en" }
    /// Identifies the piece for the clip cache and the server: language and words.
    var key: String { language + "|" + text }
}

/// What the guidance says: pieces, plus the punctuation the written form ends with. `text` is the whole phrase as one sentence (the phone's own voice reads the
/// pieces separately, but tests and the log read this).
struct Phrase: Equatable {
    var parts: [SpokenPart]
    var closing: String = "."

    /// A sentence that is said in one go (its own punctuation stays as it is).
    init(_ sentence: String) {
        parts = [SpokenPart(kind: .instruction, text: sentence)]
        closing = ""
    }

    init(parts: [SpokenPart], closing: String = ".") {
        self.parts = parts
        self.closing = closing
    }

    /// A short warning: "Hairpin left."
    static func alert(_ text: String) -> Phrase { Phrase(parts: [SpokenPart(kind: .alert, text: text)]) }

    var text: String {
        var out = ""
        for (i, part) in parts.enumerated() {
            if i > 0 { out += parts[i - 1].kind == .distance || parts[i - 1].kind == .alert ? ", " : " " }
            out += part.text
        }
        return out + closing
    }
}

/// How instructions become pieces, free of AVFoundation so it can be unit-tested (Tests/PhraseBookTests.swift).
enum PhraseBook {
    /// At this speed (80 km/h) and above a street name is left out: it is too late to read a sign, and the sentence is shorter.
    static let streetlessMps = 22.0
    private static let prepositions = [" onto", " on", " toward", " towards", " to"]

    /// "turn right onto Schaffhauserplatz." with the street "Schaffhauserplatz" -> ("turn right onto", "Schaffhauserplatz", "."). Without a street at the end of the
    /// sentence (or none known) the sentence stays whole.
    static func split(_ sentence: String, street: String?) -> (lead: String, street: String?, closing: String) {
        var body = sentence.trimmingCharacters(in: .whitespaces)
        var closing = ""
        if body.hasSuffix(".") {
            body.removeLast()
            closing = "."
        }
        guard let name = street?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
              let range = body.range(of: name, options: .backwards), range.upperBound == body.endIndex, range.lowerBound > body.startIndex else {
            return (body, nil, closing)
        }
        let lead = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        return lead.isEmpty ? (body, nil, closing) : (lead, String(body[range]), closing)
    }

    /// "turn right onto" -> "turn right".
    static func withoutPreposition(_ lead: String) -> String {
        for word in prepositions where lead.hasSuffix(word) { return String(lead.dropLast(word.count)) }
        return lead
    }

    /// An instruction as pieces: `distance` ("600 meters") first when it is a heads-up, then the instruction, then the street name as its own piece when it is to be said.
    static func spoken(_ sentence: String, street: String?, speedMps: Double, streetNames: Bool, distance: String? = nil) -> Phrase {
        let s = split(sentence, street: street)
        var parts: [SpokenPart] = []
        if let distance { parts.append(SpokenPart(kind: .distance, text: "In " + distance)) }
        if let name = s.street {
            if streetNames && speedMps < streetlessMps {
                parts.append(SpokenPart(kind: .instruction, text: s.lead))
                parts.append(SpokenPart(kind: .street, text: name))
            } else {
                parts.append(SpokenPart(kind: .instruction, text: withoutPreposition(s.lead)))
            }
        } else {
            parts.append(SpokenPart(kind: .instruction, text: s.lead))
        }
        return Phrase(parts: parts, closing: s.closing)
    }

    /// The pause, in seconds, before `next` when it follows `previous`: a breath after a distance, hardly any before a street name, a little after a warning.
    static func pause(after previous: SpokenPart, before next: SpokenPart) -> Double {
        switch (previous.kind, next.kind) {
        case (.distance, _): return 0.18
        case (.instruction, .street): return 0.03
        default: return 0.22
        }
    }

    /// The distances that can open a heads-up ("In 300 meters"), so they can all be fetched once: what `GuidanceText.distancePhrase` can say up to 10 km.
    static let distanceParts: [SpokenPart] = {
        var phrases = (1...9).map { "\($0 * 100) meters" } + ["1 kilometer"]
        var km = 1.5
        while km <= 10 {
            phrases.append(km == km.rounded() ? "\(Int(km)) kilometers" : "\(km) kilometers")
            km += 0.5
        }
        return phrases.map { SpokenPart(kind: .distance, text: "In " + $0) }
    }()

    /// The advisory speeds a corner warning can add ("slow to 40"), and the limits a callout can say.
    static let advisoryParts: [SpokenPart] = stride(from: 15, through: 75, by: 5).map { SpokenPart(kind: .alert, text: "slow to \($0)") }
    static let limitSpeeds = [20, 30, 40, 50, 60, 70, 80, 100, 120]
    static let limitParts: [SpokenPart] = limitSpeeds.map { SpokenPart(kind: .alert, text: "Limit \($0)") }
}

/// The fixed lines of guidance, in one place so that the engine, the model and the clip prefetch agree on the words.
enum GuidanceLines {
    static let offRoute = "Off route. Recalculating."
    static let offRouteBack = "Off route. Heading back to your route."
    static let offRouteAsk = "Off route."
    static let routeUpdated = "Route updated."
    static let noConnection = "No connection. Follow the blue line."
    static let curvesAhead = "Curves ahead"
    /// Whole sentences said in one go.
    static let sentences = [offRoute, offRouteBack, offRouteAsk, routeUpdated, noConnection, "You have arrived at your destination.", "You have reached your stop.",
                            "You will arrive at your destination.", "Your stop is ahead."]
    /// Warnings said as a piece of their own (see Phrase.alert).
    static let alerts = [curvesAhead, "Hairpin left", "Hairpin right", "Sharp left", "Sharp right"]
}
