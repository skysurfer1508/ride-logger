import Foundation

/// The natural voice's clips on the phone. The server (Piper, app/voice.py) renders the pieces of speech a route needs; they are fetched once, before the ride, and kept in the
/// app's support folder, so guidance sounds the same with no signal. A piece with no clip is simply spoken by the phone's own voice (see SpeechOutput).
@MainActor
final class VoiceClips: ObservableObject {
    static let shared = VoiceClips()

    /// How many pieces are on the phone.
    @Published private(set) var count = 0
    @Published private(set) var fetching = false
    /// What the server said last time: nil before it was asked, false when its natural voice is not set up.
    @Published private(set) var serverReady: Bool?

    private var index: [String: String]
    private let directory: URL
    private let indexURL: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = support.appendingPathComponent("voice", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var keep = URLResourceValues()
        keep.isExcludedFromBackup = true                                    // clips can be fetched again: no need to put them in a backup
        try? folder.setResourceValues(keep)
        directory = folder
        indexURL = folder.appendingPathComponent("index.json")
        let stored = (try? Data(contentsOf: indexURL)).map(VoiceClipLogic.decode) ?? [:]
        index = stored.filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0.value + ".mp3").path) }
        count = index.count
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".mp3") }

    /// The files that say the whole phrase, in order; nil when any piece is missing.
    func files(for phrase: Phrase) -> [URL]? {
        guard let ids = VoiceClipLogic.clipIDs(for: phrase, index: index) else { return nil }
        let urls = ids.map(file)
        return urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? urls : nil
    }

    /// Whether every piece of `parts` is on the phone.
    func hasAll(_ parts: [SpokenPart]) -> Bool { VoiceClipLogic.missing(parts, have: Set(index.keys)).isEmpty }

    /// Fetches the pieces that are not on the phone yet. Quietly does nothing when the server has no natural voice, the network is down or the session ended.
    func prefetch(_ parts: [SpokenPart], api: APIClient) async {
        let wanted = VoiceClipLogic.missing(parts, have: Set(index.keys))
        guard !wanted.isEmpty else { return }
        fetching = true
        defer { fetching = false }
        for batch in VoiceClipLogic.batches(wanted) {
            do {
                let answer: VoiceClipsResponse = try await api.post("voice/clips", form: ["items": VoiceClipLogic.requestJSON(batch)])
                if answer.status != "ok" {
                    serverReady = false
                    return
                }
                serverReady = true
                for clip in answer.clips ?? [] where VoiceClipLogic.isValid(id: clip.id) {
                    if !FileManager.default.fileExists(atPath: file(clip.id).path) {
                        let data = try await api.getRaw("voice/clips/\(clip.id).mp3")
                        try data.write(to: file(clip.id), options: .atomic)
                    }
                    index[clip.key] = clip.id
                }
                try? VoiceClipLogic.encode(index).write(to: indexURL, options: .atomic)
                count = index.count
            } catch {
                return                                                              // offline or signed out: the phone's voice covers what is missing
            }
        }
    }
}
