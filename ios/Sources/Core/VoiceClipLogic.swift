import Foundation

/// The bookkeeping of the natural voice's clips, free of the network and of AVFoundation so it can be unit-tested (Tests/VoiceClipLogicTests.swift): which pieces still
/// need fetching, how they are asked for, and which clips make up a phrase.
enum VoiceClipLogic {
    /// The server renders at most this many phrases in one request, each at most this many characters.
    static let batchSize = 150
    static let maxCharacters = 200

    /// The pieces to fetch: not yet on the phone (`have` holds their keys), short enough for the server, each once, in the order they first appear.
    static func missing(_ parts: [SpokenPart], have: Set<String>) -> [SpokenPart] {
        var seen = Set<String>()
        var out: [SpokenPart] = []
        for part in parts where part.text.count <= maxCharacters && !part.text.isEmpty && !have.contains(part.key) && seen.insert(part.key).inserted { out.append(part) }
        return out
    }

    static func batches(_ parts: [SpokenPart]) -> [[SpokenPart]] {
        stride(from: 0, to: parts.count, by: batchSize).map { Array(parts[$0..<min($0 + batchSize, parts.count)]) }
    }

    /// The `items` form field: [{"text": ..., "lang": ...}, ...].
    static func requestJSON(_ parts: [SpokenPart]) -> String {
        let items = parts.map { ["text": $0.text, "lang": $0.language] }
        guard let data = try? JSONSerialization.data(withJSONObject: items, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// The clip ids that say the whole phrase, in order; nil when any piece has no clip yet (the phone's own voice then says the phrase, all of it).
    /// `index` maps a piece's key to its clip id.
    static func clipIDs(for phrase: Phrase, index: [String: String]) -> [String]? {
        guard !phrase.parts.isEmpty else { return nil }
        var ids: [String] = []
        for part in phrase.parts {
            guard let id = index[part.key] else { return nil }
            ids.append(id)
        }
        return ids
    }

    /// The index as it is kept on disk.
    static func encode(_ index: [String: String]) -> Data { (try? JSONEncoder().encode(index)) ?? Data() }

    static func decode(_ data: Data) -> [String: String] { (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:] }

    /// Clip ids are 16 hex digits: anything else never becomes a file name.
    static func isValid(id: String) -> Bool {
        id.count == 16 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// Every piece of speech the guidance can say on a route, found by riding the route in a simulator at a few speeds with the same engine that speaks on the road: so
/// the pieces to fetch are exactly the ones that will be wanted, and nothing has to be kept in step by hand.
enum GuidancePreview {
    static let speedsKmh = [30.0, 50.0, 90.0]

    static func parts(for route: GuidanceRoute, options: GuidanceOptions = GuidanceOptions(), limits: [LimitChange] = [], alerts: [RouteAlert] = [], summary: String? = nil) -> [SpokenPart] {
        var found: [SpokenPart] = []
        var seen = Set<SpokenPart>()
        func add(_ part: SpokenPart) { if seen.insert(part).inserted { found.append(part) } }

        for kmh in speedsKmh {
            var engine = GuidanceEngine(route: route, options: options)
            engine.attach(limits: limits, alerts: alerts, summary: summary)
            var sim = DriveSimulator(line: route.line)
            let mps = kmh / 3.6
            var t = 0.0
            while !sim.isFinished && !engine.arrived && t < 100_000 {
                let position = sim.step(seconds: 1, speedMps: mps)
                for output in engine.update(lat: position.lat, lon: position.lon, speedMps: mps, now: t) {
                    if case .say(let phrase) = output { phrase.parts.forEach(add) }
                }
                t += 1
            }
        }
        GuidanceLines.sentences.forEach { add(SpokenPart(kind: .instruction, text: $0)) }
        GuidanceLines.alerts.forEach { add(SpokenPart(kind: .alert, text: $0)) }
        PhraseBook.distanceParts.forEach(add)
        PhraseBook.advisoryParts.forEach(add)
        PhraseBook.limitParts.forEach(add)
        return found
    }
}
