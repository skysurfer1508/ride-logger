import Foundation

// POST /api/v1/voice/clips and GET /api/v1/voice/status (app/routers/api_voice.py). Foundation only: also compiled into the test target.

struct VoiceClip: Decodable, Equatable {
    let text: String
    /// "en" or "de".
    let lang: String
    /// The clip's id: GET voice/clips/<id>.mp3.
    let id: String
    let url: String

    /// The cache key of the piece this clip says (see SpokenPart.key).
    var key: String { lang + "|" + text }
}

struct VoiceClipsResponse: Decodable {
    /// "ok", or "unavailable" when the server's natural voice is not set up (the phone then speaks with its own voice).
    let status: String
    let message: String?
    let clips: [VoiceClip]?
}

struct VoiceStatusResponse: Decodable {
    let status: String
    /// The server can make English clips (and street names, with `streetAvailable`).
    let available: Bool
    let streetAvailable: Bool
    let voice: String
    let streetVoice: String
}
